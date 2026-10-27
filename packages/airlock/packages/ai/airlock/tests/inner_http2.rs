// cspell:words alpn Nagle
mod common;

use std::{future::poll_fn, io, net::SocketAddr, sync::Arc, time::Duration};

use common::{
    h2_client, headers, private_root,
    tls::{BoxIo, Guards, LIMIT, client_config, fixture_certificate, outer, proxy},
};
use hyper::{Request, Response, Version, body::Bytes};
use rustls::{ServerConfig, pki_types::ServerName};
use tempfile::TempDir;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::oneshot,
    time::timeout,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

async fn tls(
    directory: &TempDir,
    socket: BoxIo,
    protocols: &[&[u8]],
) -> tokio_rustls::client::TlsStream<BoxIo> {
    let mut config = (*client_config(directory)).clone();
    config.alpn_protocols = protocols.iter().map(|protocol| protocol.to_vec()).collect();
    timeout(
        LIMIT,
        TlsConnector::from(Arc::new(config))
            .connect(ServerName::try_from("localhost").unwrap(), socket),
    )
    .await
    .unwrap()
    .unwrap()
}

fn server_config(protocols: &[&[u8]]) -> (Arc<ServerConfig>, String) {
    let (config, root) = fixture_certificate("localhost", false);
    let mut config = Arc::try_unwrap(config).unwrap();
    config.alpn_protocols = protocols.iter().map(|protocol| protocol.to_vec()).collect();
    (Arc::new(config), root)
}

#[tokio::test]
async fn independently_negotiated_pairs_translate_streaming_requests_and_responses() {
    // One outer protocol covers the four inner pairs; additional cases verify
    // no-ALPN fallback independently on both TLS legs.
    for (down, up, accepts_trailers) in [(1, 1), (1, 2), (2, 1), (2, 2), (0, 2), (2, 0), (0, 0)]
        .into_iter()
        .flat_map(|(down, up)| [false, true].map(|accepts| (down, up, accepts)))
    {
        let directory = private_root();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = listener.local_addr().unwrap();
        let protocols: &[&[u8]] = match up {
            2 => &[b"h2", b"http/1.1"],
            1 => &[b"http/1.1"],
            _ => &[],
        };
        let (config, root) = server_config(protocols);
        let (first, seen) = oneshot::channel();
        let payload = vec![b'x'; 140_000];
        let upstream = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let socket = TlsAcceptor::from(config).accept(socket).await.unwrap();
            assert_eq!(
                socket.get_ref().1.alpn_protocol(),
                match up {
                    2 => Some(b"h2".as_slice()),
                    1 => Some(b"http/1.1".as_slice()),
                    _ => None,
                }
            );
            if up == 2 {
                let mut connection = h2::server::handshake(socket).await.unwrap();
                let (request, mut respond) = connection.accept().await.unwrap().unwrap();
                assert_eq!(request.version(), Version::HTTP_2);
                assert_eq!(request.uri().scheme_str(), Some("https"));
                assert_eq!(
                    request.uri().authority().unwrap().as_str(),
                    format!("LOCALHOST:{}", target.port())
                );
                assert_eq!(
                    request.headers()["host"],
                    format!("LOCALHOST:{}", target.port())
                );
                assert_eq!(request.headers()["authorization"], "Bearer native-fixture");
                assert_eq!(
                    request.headers().get("te").map(|value| value.as_bytes()),
                    accepts_trailers.then_some(b"trailers".as_slice())
                );
                for absent in ["connection", "transfer-encoding", "proxy-authorization"] {
                    assert!(!request.headers().contains_key(absent));
                }
                let job = async move {
                    let mut recv = request.into_body();
                    let first_bytes = recv.data().await.unwrap().unwrap();
                    recv.flow_control()
                        .release_capacity(first_bytes.len())
                        .unwrap();
                    assert_eq!(&first_bytes[..], b"first");
                    first.send(()).unwrap();
                    let body = h2_client::read_all(&mut recv).await;
                    assert_eq!(body, vec![b'x'; 140_000]);
                    assert_eq!(
                        recv.trailers().await.unwrap().unwrap()["x-request-signature"],
                        "request-signed"
                    );
                    let mut send_stream = respond
                        .send_response(
                            Response::builder()
                                .header("content-type", "text/event-stream")
                                .header("trailer", "x-response-signature")
                                .body(())
                                .unwrap(),
                            false,
                        )
                        .unwrap();
                    h2_client::write(&mut send_stream, Bytes::copy_from_slice(&body))
                        .await
                        .unwrap();
                    let mut trailers = hyper::HeaderMap::new();
                    trailers.insert("x-response-signature", "response-signed".parse().unwrap());
                    send_stream.send_trailers(trailers).unwrap();
                };
                tokio::pin!(job);
                tokio::select! { () = &mut job => {}, result = connection.accept() => panic!("unexpected upstream stream: {result:?}") }
                // Keep driving queued DATA/END_STREAM until the proxy ends IO.
                while connection.accept().await.is_some() {}
            } else {
                use tokio::io::AsyncBufReadExt;
                let mut socket = tokio::io::BufReader::new(socket);
                let head = headers(&mut socket).await;
                assert!(head.starts_with("GET /messages HTTP/1.1"), "{head}");
                assert!(
                    head.contains("authorization: Bearer native-fixture"),
                    "{head}"
                );
                assert!(head.contains("transfer-encoding: chunked"), "{head}");
                let host = format!("LOCALHOST:{}", target.port());
                assert!(head.contains(&format!("host: {host}\r\n")), "{head}");
                assert!(!head.contains("proxy-authorization"), "{head}");
                let upstream_accepts_trailers = head.contains("\r\nte: trailers\r\n");
                assert_eq!(upstream_accepts_trailers, accepts_trailers, "{head}");
                assert_eq!(
                    head.contains("\r\nconnection: TE\r\n"),
                    accepts_trailers,
                    "{head}"
                );
                if down == 2 {
                    assert!(
                        head.contains("cookie: session=one; theme=dark\r\n"),
                        "{head}"
                    );
                    assert_eq!(head.matches("\r\ncookie:").count(), 1, "{head}");
                } else {
                    assert!(head.contains("cookie: session=one\r\n"), "{head}");
                    assert!(head.contains("cookie: theme=dark\r\n"), "{head}");
                    assert_eq!(head.matches("\r\ncookie:").count(), 2, "{head}");
                }
                let mut body = Vec::new();
                let mut first = Some(first);
                loop {
                    let mut line = String::new();
                    socket.read_line(&mut line).await.unwrap();
                    let count = usize::from_str_radix(line.trim(), 16).unwrap();
                    if count == 0 {
                        assert_eq!(
                            headers(&mut socket).await,
                            "x-request-signature: request-signed\r\n\r\n"
                        );
                        break;
                    }
                    let mut bytes = vec![0; count + 2];
                    socket.read_exact(&mut bytes).await.unwrap();
                    assert_eq!(&bytes[count..], b"\r\n");
                    body.extend_from_slice(&bytes[..count]);
                    if body.len() >= 5
                        && let Some(first) = first.take()
                    {
                        first.send(()).unwrap();
                    }
                }
                assert_eq!(&body[..5], b"first");
                assert_eq!(&body[5..], &vec![b'x'; 140_000]);
                socket.get_mut().write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nTrailer: x-response-signature\r\n\r\n222e0\r\n").await.unwrap();
                socket.get_mut().write_all(&body[5..]).await.unwrap();
                // Like hyper's HTTP/1 server, send trailers only for TE: trailers.
                let ending: &[u8] = if upstream_accepts_trailers {
                    b"\r\n0\r\nx-response-signature: response-signed\r\n\r\n"
                } else {
                    b"\r\n0\r\n\r\n"
                };
                socket.get_mut().write_all(ending).await.unwrap();
                socket.get_mut().shutdown().await.unwrap();
            }
        });
        let proxy = proxy(&directory, target, Some(&root)).await;
        let (socket, guards) = outer(
            proxy.address,
            &format!("localhost:{}", target.port()),
            false,
        )
        .await;
        let protocols: &[&[u8]] = match down {
            2 => &[b"h2", b"http/1.1"],
            1 => &[b"http/1.1"],
            _ => &[],
        };
        let mut client = tls(&directory, socket, protocols).await;
        assert_eq!(
            client.get_ref().1.alpn_protocol(),
            match down {
                2 => Some(b"h2".as_slice()),
                1 => Some(b"http/1.1".as_slice()),
                _ => None,
            }
        );
        if down == 2 {
            let (mut sender, driver) = h2::client::handshake(client).await.unwrap();
            let driver = tokio::spawn(async {
                let _ = driver.await;
            });
            let mut request = Request::builder()
                .method("GET")
                .uri(format!("https://LOCALHOST:{}/messages", target.port()))
                .header("host", format!("localHOST:{}", target.port()))
                .header("authorization", "Bearer native-fixture")
                .header("proxy-authorization", "Basic fixture")
                .header("trailer", "x-request-signature")
                .header("cookie", "session=one")
                .header("cookie", "theme=dark")
                .body(())
                .unwrap();
            if accepts_trailers {
                request
                    .headers_mut()
                    .insert("te", "trailers".parse().unwrap());
            }
            let (response, mut upload) = sender.send_request(request, false).unwrap();
            h2_client::write(&mut upload, Bytes::from_static(b"first"))
                .await
                .unwrap();
            timeout(LIMIT, seen).await.unwrap().unwrap();
            h2_client::write(&mut upload, Bytes::copy_from_slice(&payload))
                .await
                .unwrap();
            let mut trailers = hyper::HeaderMap::new();
            trailers.insert("x-request-signature", "request-signed".parse().unwrap());
            upload.send_trailers(trailers).unwrap();
            let response = timeout(LIMIT, response).await.unwrap().unwrap();
            assert_eq!(response.status(), 200);
            assert_eq!(response.headers()["content-type"], "text/event-stream");
            let mut body = response.into_body();
            assert_eq!(
                timeout(LIMIT, h2_client::read_all(&mut body))
                    .await
                    .unwrap(),
                payload
            );
            assert_eq!(
                body.trailers()
                    .await
                    .unwrap()
                    .as_ref()
                    .map(|trailers| trailers["x-response-signature"].as_bytes()),
                (up == 2 || accepts_trailers).then_some(b"response-signed".as_slice())
            );
            driver.abort();
        } else {
            let te = if accepts_trailers {
                "TE: trailers\r\nConnection: TE\r\n"
            } else {
                ""
            };
            client.write_all(format!("GET /messages HTTP/1.1\r\nHost: LOCALHOST:{}\r\nAuthorization: Bearer native-fixture\r\nProxy-Authorization: Basic fixture\r\n{te}Cookie: session=one\r\nCookie: theme=dark\r\nTrailer: x-request-signature\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nfirst\r\n", target.port()).as_bytes()).await.unwrap();
            client.flush().await.unwrap();
            timeout(LIMIT, seen).await.unwrap().unwrap();
            client
                .write_all(format!("{:x}\r\n", payload.len()).as_bytes())
                .await
                .unwrap();
            client.write_all(&payload).await.unwrap();
            client
                .write_all(b"\r\n0\r\nx-request-signature: request-signed\r\n\r\n")
                .await
                .unwrap();
            client.flush().await.unwrap();
            let head = headers(&mut client).await;
            assert!(head.starts_with("HTTP/1.1 200"), "{head}");
            assert!(head.contains("trailer: x-response-signature\r\n"), "{head}");
            let mut response = vec![0; payload.len()];
            if head.contains("transfer-encoding: chunked") {
                // Hyper selects fresh H1 framing for an unknown-length H2 body.
                use tokio::io::AsyncBufReadExt;
                let mut reader = tokio::io::BufReader::new(&mut client);
                let mut decoded = Vec::new();
                loop {
                    let mut line = String::new();
                    reader.read_line(&mut line).await.unwrap();
                    let count = usize::from_str_radix(line.trim(), 16).unwrap();
                    if count == 0 {
                        if accepts_trailers {
                            assert_eq!(
                                headers(&mut reader).await,
                                "x-response-signature: response-signed\r\n\r\n"
                            );
                        } else {
                            let mut ending = String::new();
                            reader.read_line(&mut ending).await.unwrap();
                            assert_eq!(ending, "\r\n");
                        }
                        break;
                    }
                    let mut bytes = vec![0; count + 2];
                    reader.read_exact(&mut bytes).await.unwrap();
                    decoded.extend_from_slice(&bytes[..count]);
                }
                response = decoded;
            } else {
                timeout(LIMIT, client.read_exact(&mut response))
                    .await
                    .unwrap()
                    .unwrap();
            }
            assert_eq!(response, payload);
            drop(client);
        }
        drop(guards);
        timeout(LIMIT, upstream).await.unwrap().unwrap();
        proxy.stop().await;
    }
}

async fn origin_h2(
    listener: TcpListener,
    config: Arc<ServerConfig>,
    events: tokio::sync::mpsc::Sender<String>,
) {
    let (socket, _) = listener.accept().await.unwrap();
    let socket = TlsAcceptor::from(config).accept(socket).await.unwrap();
    let mut connection = h2::server::handshake(socket).await.unwrap();
    let mut jobs = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            request = connection.accept() => match request {
                Some(Ok((request, mut respond))) => {
                    let events = events.clone();
                    jobs.spawn(async move {
                        let path = request.uri().path().to_owned();
                        let mut body = request.into_body();
                        if path == "/ok" {
                            let mut send_stream = respond.send_response(Response::new(()), false).unwrap();
                            h2_client::send_all(&mut send_stream, Bytes::from_static(b"ok")).await;
                            return;
                        }
                        if path == "/upload" {
                            let first = body.data().await.unwrap().unwrap();
                            body.flow_control().release_capacity(first.len()).unwrap();
                            assert_eq!(&first[..], b"first");
                        }
                        let reason = if path == "/sse" {
                            let mut send_stream = respond.send_response(Response::builder().header("content-type", "text/event-stream").body(()).unwrap(), false).unwrap();
                            h2_client::write(&mut send_stream, Bytes::from_static(b"data: first\n\n")).await.unwrap();
                            events.send(format!("started:{path}")).await.unwrap();
                            poll_fn(|cx| send_stream.poll_reset(cx)).await
                        } else {
                            assert!(path == "/pending" || path == "/upload");
                            events.send(format!("started:{path}")).await.unwrap();
                            poll_fn(|cx| respond.poll_reset(cx)).await
                        };
                        events.send(format!("closed:{path}:{reason:?}")).await.unwrap();
                    });
                }
                Some(Err(_)) | None => break,
            },
            result = jobs.join_next(), if !jobs.is_empty() => { result.unwrap().unwrap(); },
        }
    }
    events.send("transport-closed".to_owned()).await.unwrap();
    while let Some(result) = jobs.join_next().await {
        result.unwrap();
    }
}

fn inner_request(target: SocketAddr, path: &str) -> Request<()> {
    Request::builder()
        .method("GET")
        .version(Version::HTTP_2)
        .uri(format!("https://localhost:{}{path}", target.port()))
        .body(())
        .unwrap()
}

async fn event(events: &mut tokio::sync::mpsc::Receiver<String>) -> String {
    timeout(LIMIT, events.recv()).await.unwrap().unwrap()
}

#[tokio::test]
async fn inner_h2_reset_cancels_only_its_request_and_rejects_unbound_authorities() {
    let directory = private_root();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let (config, root) = server_config(&[b"h2"]);
    let (events, mut observed) = tokio::sync::mpsc::channel(16);
    let upstream = tokio::spawn(origin_h2(listener, config, events));
    let proxy = proxy(&directory, target, Some(&root)).await;
    let (socket, guards) =
        outer(proxy.address, &format!("localhost:{}", target.port()), true).await;
    let client = tls(&directory, socket, &[b"h2", b"http/1.1"]).await;
    let (mut sender, driver) = h2::client::handshake(client).await.unwrap();
    let driver = tokio::spawn(async {
        let _ = driver.await;
    });
    let (pending, mut cancel) = sender
        .send_request(inner_request(target, "/pending"), true)
        .unwrap();
    assert_eq!(event(&mut observed).await, "started:/pending");
    assert_eq!(sender.current_max_send_streams(), 32);
    // A slow first response header must outlive all setup timers.
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(11)).await;
    tokio::time::resume();
    let (healthy, _) = sender
        .send_request(inner_request(target, "/ok"), true)
        .unwrap();
    assert_eq!(
        h2_client::read_all(&mut timeout(LIMIT, healthy).await.unwrap().unwrap().into_body()).await,
        b"ok"
    );
    cancel.send_reset(h2::Reason::CANCEL);
    assert!(timeout(LIMIT, pending).await.unwrap().is_err());
    let closed = event(&mut observed).await;
    assert!(closed.starts_with("closed:/pending:"), "{closed}");
    assert!(closed.contains("CANCEL"), "{closed}");
    for (uri, host) in [
        (format!("https://wrong.test:{}/ok", target.port()), None),
        (format!("http://localhost:{}/ok", target.port()), None),
        (
            format!("https://localhost:{}/ok", target.port()),
            Some("wrong.test"),
        ),
    ] {
        let mut request = Request::builder().uri(uri);
        if let Some(host) = host {
            request = request.header("host", host);
        }
        let (response, _) = sender
            .send_request(request.body(()).unwrap(), true)
            .unwrap();
        assert_eq!(
            timeout(LIMIT, response).await.unwrap().unwrap().status(),
            400
        );
    }
    let (response, _) = sender
        .send_request(inner_request(target, "/ok"), true)
        .unwrap();
    assert_eq!(
        h2_client::read_all(&mut timeout(LIMIT, response).await.unwrap().unwrap().into_body())
            .await,
        b"ok"
    );
    driver.abort();
    drop(sender);
    drop(cancel);
    drop(guards);
    timeout(LIMIT, upstream).await.unwrap().unwrap();
    proxy.stop().await;
}

#[tokio::test]
async fn outer_reset_drops_inner_h2_pending_headers_upload_and_sse_on_both_transports() {
    for h2_outer in [false, true] {
        let directory = private_root();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = listener.local_addr().unwrap();
        let (config, root) = server_config(&[b"h2"]);
        let (events, mut observed) = tokio::sync::mpsc::channel(16);
        let upstream = tokio::spawn(origin_h2(listener, config, events));
        let proxy = proxy(&directory, target, Some(&root)).await;
        let (socket, guards) = if h2_outer {
            outer(proxy.address, &format!("localhost:{}", target.port()), true).await
        } else {
            let mut socket = proxy.client().await;
            assert!(
                common::request(
                    &mut socket,
                    "CONNECT",
                    &format!("localhost:{}", target.port())
                )
                .await
                .starts_with("HTTP/1.1 200")
            );
            socket.set_zero_linger().unwrap();
            (Box::new(socket) as BoxIo, Guards::default())
        };
        let client = tls(&directory, socket, &[b"h2"]).await;
        let (mut sender, driver) = h2::client::handshake(client).await.unwrap();
        let driver = tokio::spawn(async {
            let _ = driver.await;
        });
        let (pending, pending_send) = sender
            .send_request(inner_request(target, "/pending"), true)
            .unwrap();
        let (upload_response, mut upload) = sender
            .send_request(inner_request(target, "/upload"), false)
            .unwrap();
        h2_client::write(&mut upload, Bytes::from_static(b"first"))
            .await
            .unwrap();
        let (sse, sse_send) = sender
            .send_request(inner_request(target, "/sse"), true)
            .unwrap();
        let mut sse = timeout(LIMIT, sse).await.unwrap().unwrap().into_body();
        let first = timeout(LIMIT, sse.data()).await.unwrap().unwrap().unwrap();
        assert_eq!(&first[..], b"data: first\n\n");
        sse.flow_control().release_capacity(first.len()).unwrap();
        let mut starts = std::collections::BTreeSet::new();
        for _ in 0..3 {
            starts.insert(event(&mut observed).await);
        }
        assert_eq!(starts.len(), 3);
        // SSE remains live after the setup deadline while other streams wait.
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(11)).await;
        tokio::time::resume();
        if h2_outer {
            guards
                .reset
                .as_ref()
                .unwrap()
                .lock()
                .await
                .send_reset(h2::Reason::CANCEL);
        } else {
            driver.abort();
        }
        let mut closes = std::collections::BTreeSet::new();
        for _ in 0..4 {
            closes.insert(event(&mut observed).await);
        }
        assert!(closes.contains("transport-closed"), "{closes:?}");
        assert_eq!(
            closes
                .iter()
                .filter(|event| event.starts_with("closed:"))
                .count(),
            3
        );
        // This socket EOF is observed while the native inner-H2 sender and
        // stalled request/response handles are still retained by this client.
        timeout(LIMIT, upstream).await.unwrap().unwrap();
        driver.abort();
        drop((
            sender,
            pending,
            pending_send,
            upload_response,
            upload,
            sse,
            sse_send,
        ));
        drop(guards);
        proxy.stop().await;
    }
}

#[tokio::test]
async fn rustls_rejects_unsupported_client_alpn_and_initial_inner_h2_request_has_a_deadline() {
    let directory = private_root();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let (config, root) = server_config(&[b"http/1.1"]);
    let upstream = tokio::spawn(async move {
        for _ in 0..2 {
            let (socket, _) = listener.accept().await.unwrap();
            let mut socket = TlsAcceptor::from(Arc::clone(&config))
                .accept(socket)
                .await
                .unwrap();
            let mut bytes = Vec::new();
            let _ = socket.read_to_end(&mut bytes).await;
            assert!(bytes.is_empty());
        }
    });
    let proxy = proxy(&directory, target, Some(&root)).await;
    let (socket, guards) = outer(
        proxy.address,
        &format!("localhost:{}", target.port()),
        false,
    )
    .await;
    let mut config = (*client_config(&directory)).clone();
    config.alpn_protocols = vec![b"unsupported".to_vec()];
    assert!(
        timeout(
            LIMIT,
            TlsConnector::from(Arc::new(config))
                .connect(ServerName::try_from("localhost").unwrap(), socket)
        )
        .await
        .unwrap()
        .is_err()
    );
    drop(guards);
    let (socket, guards) = outer(
        proxy.address,
        &format!("localhost:{}", target.port()),
        false,
    )
    .await;
    let mut client = tls(&directory, socket, &[b"h2"]).await;
    // Observe the server's SETTINGS before advancing time: setup is active,
    // but the client has not delivered its preface or first request headers.
    let mut frame = [0; 9];
    timeout(LIMIT, client.read_exact(&mut frame))
        .await
        .unwrap()
        .unwrap();
    let length =
        (usize::from(frame[0]) << 16) | (usize::from(frame[1]) << 8) | usize::from(frame[2]);
    let mut payload = vec![0; length];
    client.read_exact(&mut payload).await.unwrap();
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(11)).await;
    tokio::time::resume();
    let mut remaining = Vec::new();
    let closed = timeout(LIMIT, client.read_to_end(&mut remaining))
        .await
        .expect("initial inner HTTP/2 request is bounded");
    assert!(closed.is_ok() || closed.unwrap_err().kind() == io::ErrorKind::UnexpectedEof);
    drop(client);
    drop(guards);
    timeout(LIMIT, upstream).await.unwrap().unwrap();
    proxy.stop().await;
}

#[tokio::test]
async fn inner_h2_requests_queue_for_the_single_h1_upstream_connection() {
    let directory = private_root();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let (config, root) = server_config(&[b"http/1.1"]);
    let (complete, may_complete) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut socket = TlsAcceptor::from(config).accept(socket).await.unwrap();
        assert!(
            headers(&mut socket)
                .await
                .starts_with("GET /first HTTP/1.1")
        );
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfi")
            .await
            .unwrap();
        socket.flush().await.unwrap();
        // Hold the first response open while Airlock queues the next request.
        may_complete.await.unwrap();
        socket.write_all(b"rst").await.unwrap();
        socket.flush().await.unwrap();
        assert!(
            headers(&mut socket)
                .await
                .starts_with("GET /second HTTP/1.1")
        );
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nsecond")
            .await
            .unwrap();
        socket.shutdown().await.unwrap();
    });
    let proxy = proxy(&directory, target, Some(&root)).await;
    let (socket, guards) = outer(
        proxy.address,
        &format!("localhost:{}", target.port()),
        false,
    )
    .await;
    let client = tls(&directory, socket, &[b"h2"]).await;
    let (mut sender, driver) = h2::client::handshake(client).await.unwrap();
    let driver = tokio::spawn(async {
        let _ = driver.await;
    });
    let (first, _) = sender
        .send_request(inner_request(target, "/first"), true)
        .unwrap();
    let mut first = timeout(LIMIT, first).await.unwrap().unwrap().into_body();
    let first_bytes = first.data().await.unwrap().unwrap();
    first
        .flow_control()
        .release_capacity(first_bytes.len())
        .unwrap();
    assert_eq!(&first_bytes[..], b"fi");
    assert_eq!(sender.current_max_send_streams(), 32);
    let (mut second, _) = sender
        .send_request(inner_request(target, "/second"), true)
        .unwrap();
    assert!(
        timeout(Duration::from_millis(50), &mut second)
            .await
            .is_err(),
        "Airlock must wait for the active upstream response to finish"
    );
    complete.send(()).unwrap();
    assert_eq!(h2_client::read_all(&mut first).await, b"rst");
    let second = timeout(LIMIT, second).await.unwrap().unwrap();
    assert_eq!(second.status(), 200);
    assert_eq!(
        h2_client::read_all(&mut second.into_body()).await,
        b"second"
    );
    upstream.await.unwrap();
    driver.abort();
    drop(sender);
    drop(guards);
    proxy.stop().await;
}

#[tokio::test]
async fn inner_h2_requests_opened_before_settings_queue_without_refusal() {
    let directory = private_root();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let (config, root) = server_config(&[b"http/1.1"]);
    let upstream = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut socket = TlsAcceptor::from(config).accept(socket).await.unwrap();
        for path in ["/first", "/second"] {
            let head = headers(&mut socket).await;
            assert!(head.starts_with(&format!("GET {path} HTTP/1.1")), "{head}");
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                .await
                .unwrap();
            socket.flush().await.unwrap();
        }
        socket.shutdown().await.unwrap();
    });
    let proxy = proxy(&directory, target, Some(&root)).await;
    let (socket, guards) = outer(
        proxy.address,
        &format!("localhost:{}", target.port()),
        false,
    )
    .await;
    let client = tls(&directory, socket, &[b"h2"]).await;
    let (mut sender, driver) = h2::client::handshake(client).await.unwrap();
    // Do not poll the driver until both requests are open: the client has not
    // received the server's SETTINGS and may already send multiple streams.
    assert_eq!(sender.current_max_send_streams(), usize::MAX);
    let (first, _) = sender
        .send_request(inner_request(target, "/first"), true)
        .unwrap();
    let (second, _) = sender
        .send_request(inner_request(target, "/second"), true)
        .unwrap();
    let driver = tokio::spawn(async {
        let _ = driver.await;
    });
    for response in [first, second] {
        let response = timeout(LIMIT, response).await.unwrap().unwrap();
        assert_eq!(response.status(), 200);
        assert_eq!(h2_client::read_all(&mut response.into_body()).await, b"ok");
    }
    timeout(LIMIT, upstream).await.unwrap().unwrap();
    driver.abort();
    drop(sender);
    drop(guards);
    proxy.stop().await;
}

#[tokio::test]
async fn inner_h2_upload_with_nagle_completes_promptly_on_an_h1_upstream() {
    h1_uploads(false, 16 * 1024 * 1024).await;
}

#[tokio::test]
async fn queued_inner_h2_uploads_do_not_stall_the_active_h1_request() {
    h1_uploads(true, 262_144).await;
}

async fn h1_uploads(fill_queue: bool, active_bytes: usize) {
    let directory = private_root();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let (config, root) = server_config(&[b"http/1.1"]);
    let (first, seen) = oneshot::channel();
    let (queue_count, queued) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut socket = TlsAcceptor::from(config).accept(socket).await.unwrap();
        let head = headers(&mut socket).await;
        assert!(head.starts_with("POST /first HTTP/1.1"), "{head}");
        let mut prefix = [0; 5];
        socket.read_exact(&mut prefix).await.unwrap();
        assert_eq!(&prefix, b"first");
        first.send(()).unwrap();
        let mut body = vec![0; active_bytes];
        socket.read_exact(&mut body).await.unwrap();
        assert_eq!(body, vec![b'a'; active_bytes]);
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            .await
            .unwrap();
        socket.flush().await.unwrap();
        for _ in 0..queued.await.unwrap() {
            let head = headers(&mut socket).await;
            assert!(head.starts_with("POST /queued HTTP/1.1"), "{head}");
            let mut body = vec![0; 2_097_152];
            socket.read_exact(&mut body).await.unwrap();
            assert_eq!(body, vec![b'b'; 2_097_152]);
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                .await
                .unwrap();
            socket.flush().await.unwrap();
        }
        socket.shutdown().await.unwrap();
    });
    let proxy = proxy(&directory, target, Some(&root)).await;
    // The outer HTTP/1 TCP socket keeps its default Nagle setting enabled.
    let (socket, guards) = outer(
        proxy.address,
        &format!("localhost:{}", target.port()),
        false,
    )
    .await;
    let client = tls(&directory, socket, &[b"h2"]).await;
    let (mut sender, driver) = h2::client::handshake(client).await.unwrap();
    let driver = tokio::spawn(async {
        let _ = driver.await;
    });
    let mut request = inner_request(target, "/first");
    *request.method_mut() = hyper::Method::POST;
    request
        .headers_mut()
        .insert("content-length", (active_bytes + 5).into());
    let (first, mut upload) = sender.send_request(request, false).unwrap();
    h2_client::write(&mut upload, Bytes::from_static(b"first"))
        .await
        .unwrap();
    timeout(LIMIT, seen).await.unwrap().unwrap();
    assert_eq!(sender.current_max_send_streams(), 32);
    // Fill every other advertised stream slot, including the active stream in
    // the count. Two stream windows of connection capacity cannot pass this.
    let queued = if fill_queue {
        sender.current_max_send_streams() - 1
    } else {
        0
    };
    queue_count.send(queued).unwrap();
    let mut pending = Vec::new();
    let mut uploads = Vec::new();
    for _ in 0..queued {
        let mut request = inner_request(target, "/queued");
        *request.method_mut() = hyper::Method::POST;
        request
            .headers_mut()
            .insert("content-length", "2097152".parse().unwrap());
        let (response, mut upload) = sender.send_request(request, false).unwrap();
        pending.push(response);
        uploads.push(async move {
            h2_client::send_all(&mut upload, Bytes::from(vec![b'b'; 2_097_152])).await;
        });
    }
    let uploads = futures_util::future::join_all(uploads);
    tokio::pin!(uploads);
    if fill_queue {
        // Drive every queued body until unread DATA exhausts its available
        // capacity, then leave those futures parked while the active one sends.
        assert!(
            timeout(Duration::from_millis(500), &mut uploads)
                .await
                .is_err()
        );
    }
    let started = tokio::time::Instant::now();
    timeout(Duration::from_secs(5), async {
        h2_client::send_all(&mut upload, Bytes::from(vec![b'a'; active_bytes])).await;
        let first = first.await.unwrap();
        assert_eq!(first.status(), 200);
        assert_eq!(h2_client::read_all(&mut first.into_body()).await, b"ok");
    })
    .await
    .expect("queued uploads and Nagle must not stall the active upload");
    eprintln!(
        "active upload ({active_bytes} bytes, {queued} queued): {:?}",
        started.elapsed()
    );
    timeout(Duration::from_secs(10), async {
        let responses = async {
            for response in pending {
                let response = response.await.unwrap();
                assert_eq!(response.status(), 200);
                assert_eq!(h2_client::read_all(&mut response.into_body()).await, b"ok");
            }
        };
        tokio::join!(uploads, responses);
    })
    .await
    .expect("queued uploads complete after the active request finishes");
    timeout(LIMIT, upstream).await.unwrap().unwrap();
    driver.abort();
    drop(sender);
    drop(guards);
    proxy.stop().await;
}

#[tokio::test]
async fn unread_inner_h2_uploads_leave_capacity_for_another_h2_upstream_request() {
    let directory = private_root();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let (config, root) = server_config(&[b"h2"]);
    let (unread, seen) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let socket = TlsAcceptor::from(config).accept(socket).await.unwrap();
        // Keep upstream connection credit available: only its two unread
        // stream windows should stop consumption, not the third request.
        let mut connection = h2::server::Builder::new()
            .initial_connection_window_size(8 * 1024 * 1024)
            .handshake(socket)
            .await
            .unwrap();
        let mut held = Vec::new();
        // Keep both request bodies and response handles alive without reading.
        for _ in 0..2 {
            let (request, respond) = connection.accept().await.unwrap().unwrap();
            assert_eq!(request.uri().path(), "/unread");
            held.push((request, respond));
        }
        unread.send(()).unwrap();
        let (request, mut respond) = connection.accept().await.unwrap().unwrap();
        assert_eq!(request.uri().path(), "/active");
        let job = async move {
            assert_eq!(
                h2_client::read_all(&mut request.into_body()).await,
                vec![b'a'; 262_144]
            );
            let mut send = respond.send_response(Response::new(()), false).unwrap();
            h2_client::send_all(&mut send, Bytes::from_static(b"ok")).await;
        };
        tokio::pin!(job);
        tokio::select! {
            () = &mut job => {},
            result = connection.accept() => panic!("unexpected upstream stream: {result:?}"),
        }
        while connection.accept().await.is_some() {}
        drop(held);
    });
    let proxy = proxy(&directory, target, Some(&root)).await;
    let (socket, guards) = outer(
        proxy.address,
        &format!("localhost:{}", target.port()),
        false,
    )
    .await;
    let client = tls(&directory, socket, &[b"h2"]).await;
    let (mut sender, driver) = h2::client::handshake(client).await.unwrap();
    let driver = tokio::spawn(async {
        let _ = driver.await;
    });
    let mut pending = Vec::new();
    let mut uploads = Vec::new();
    for _ in 0..2 {
        let mut request = inner_request(target, "/unread");
        *request.method_mut() = hyper::Method::POST;
        let (response, mut upload) = sender.send_request(request, false).unwrap();
        pending.push(response);
        uploads.push(async move {
            h2_client::send_all(&mut upload, Bytes::from(vec![b'b'; 4 * 1024 * 1024])).await;
        });
    }
    timeout(LIMIT, seen).await.unwrap().unwrap();
    let uploads = futures_util::future::join_all(uploads);
    tokio::pin!(uploads);
    assert!(
        timeout(Duration::from_millis(500), &mut uploads)
            .await
            .is_err()
    );
    let mut request = inner_request(target, "/active");
    *request.method_mut() = hyper::Method::POST;
    let (response, mut upload) = sender.send_request(request, false).unwrap();
    timeout(LIMIT, async {
        h2_client::send_all(&mut upload, Bytes::from(vec![b'a'; 262_144])).await;
        let response = response.await.unwrap();
        assert_eq!(response.status(), 200);
        assert_eq!(h2_client::read_all(&mut response.into_body()).await, b"ok");
    })
    .await
    .expect("two unread bodies must leave connection capacity for a third stream");
    driver.abort();
    drop(sender);
    drop(guards);
    timeout(LIMIT, upstream).await.unwrap().unwrap();
    proxy.stop().await;
}

#[tokio::test]
async fn rustls_rejects_unsupported_upstream_alpn_before_client_handshake_completes() {
    let directory = private_root();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let (config, root) = server_config(&[b"unsupported"]);
    let upstream = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        assert!(TlsAcceptor::from(config).accept(socket).await.is_err());
    });
    let proxy = proxy(&directory, target, Some(&root)).await;
    let (socket, guards) = outer(
        proxy.address,
        &format!("localhost:{}", target.port()),
        false,
    )
    .await;
    let mut config = (*client_config(&directory)).clone();
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    assert!(
        timeout(
            LIMIT,
            TlsConnector::from(Arc::new(config))
                .connect(ServerName::try_from("localhost").unwrap(), socket)
        )
        .await
        .unwrap()
        .is_err()
    );
    timeout(LIMIT, upstream).await.unwrap().unwrap();
    drop(guards);
    proxy.stop().await;
}

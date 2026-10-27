// cspell:words alpn
use super::*;
use hyper::{Response, Version};

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

async fn send(send: &mut SendStream<Bytes>, bytes: &[u8], end: bool) {
    let mut bytes = Bytes::copy_from_slice(bytes);
    while !bytes.is_empty() {
        send.reserve_capacity(bytes.len());
        let capacity = poll_fn(|cx| send.poll_capacity(cx)).await.unwrap().unwrap();
        let count = capacity.min(bytes.len());
        send.send_data(bytes.split_to(count), false).unwrap();
    }
    if end {
        send.send_data(Bytes::new(), true).unwrap();
    }
}

async fn read(mut recv: h2::RecvStream) -> Vec<u8> {
    let mut bytes = Vec::new();
    while let Some(data) = recv.data().await {
        let data = data.unwrap();
        recv.flow_control().release_capacity(data.len()).unwrap();
        bytes.extend_from_slice(&data);
    }
    bytes
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
    for (down, up) in [(1, 1), (1, 2), (2, 1), (2, 2), (0, 2), (2, 0), (0, 0)] {
        let directory = TempDir::new().unwrap();
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
                assert!(request.uri().authority().is_some());
                assert_eq!(request.headers()["authorization"], "Bearer native-fixture");
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
                    let body = read(recv).await;
                    assert_eq!(body, vec![b'x'; 140_000]);
                    let mut send_stream = respond
                        .send_response(
                            Response::builder()
                                .header("content-type", "text/event-stream")
                                .body(())
                                .unwrap(),
                            false,
                        )
                        .unwrap();
                    send(&mut send_stream, &body, true).await;
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
                assert!(!head.contains("proxy-authorization"), "{head}");
                let mut body = Vec::new();
                let mut first = Some(first);
                loop {
                    let mut line = String::new();
                    socket.read_line(&mut line).await.unwrap();
                    let count = usize::from_str_radix(line.trim(), 16).unwrap();
                    let mut bytes = vec![0; count + 2];
                    socket.read_exact(&mut bytes).await.unwrap();
                    assert_eq!(&bytes[count..], b"\r\n");
                    if count == 0 {
                        break;
                    }
                    body.extend_from_slice(&bytes[..count]);
                    if body.len() >= 5
                        && let Some(first) = first.take()
                    {
                        first.send(()).unwrap();
                    }
                }
                assert_eq!(&body[..5], b"first");
                assert_eq!(&body[5..], &vec![b'x'; 140_000]);
                socket.get_mut().write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 140000\r\n\r\n").await.unwrap();
                socket.get_mut().write_all(&body[5..]).await.unwrap();
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
            let request = Request::builder()
                .method("GET")
                .uri(format!("https://localhost:{}/messages", target.port()))
                .header("authorization", "Bearer native-fixture")
                .header("proxy-authorization", "Basic fixture")
                .body(())
                .unwrap();
            let (response, mut upload) = sender.send_request(request, false).unwrap();
            send(&mut upload, b"first", false).await;
            timeout(LIMIT, seen).await.unwrap().unwrap();
            send(&mut upload, &payload, true).await;
            let response = timeout(LIMIT, response).await.unwrap().unwrap();
            assert_eq!(response.status(), 200);
            assert_eq!(response.headers()["content-type"], "text/event-stream");
            assert_eq!(
                timeout(LIMIT, read(response.into_body())).await.unwrap(),
                payload
            );
            driver.abort();
        } else {
            client.write_all(format!("GET /messages HTTP/1.1\r\nHost: localhost:{}\r\nAuthorization: Bearer native-fixture\r\nProxy-Authorization: Basic fixture\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nfirst\r\n", target.port()).as_bytes()).await.unwrap();
            client.flush().await.unwrap();
            timeout(LIMIT, seen).await.unwrap().unwrap();
            client
                .write_all(format!("{:x}\r\n", payload.len()).as_bytes())
                .await
                .unwrap();
            client.write_all(&payload).await.unwrap();
            client.write_all(b"\r\n0\r\n\r\n").await.unwrap();
            client.flush().await.unwrap();
            let head = headers(&mut client).await;
            assert!(head.starts_with("HTTP/1.1 200"), "{head}");
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
                    let mut bytes = vec![0; count + 2];
                    reader.read_exact(&mut bytes).await.unwrap();
                    if count == 0 {
                        break;
                    }
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
                            send(&mut send_stream, b"ok", true).await;
                            return;
                        }
                        if path == "/upload" {
                            let first = body.data().await.unwrap().unwrap();
                            body.flow_control().release_capacity(first.len()).unwrap();
                            assert_eq!(&first[..], b"first");
                        }
                        let reason = if path == "/sse" {
                            let mut send_stream = respond.send_response(Response::builder().header("content-type", "text/event-stream").body(()).unwrap(), false).unwrap();
                            send(&mut send_stream, b"data: first\n\n", false).await;
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
    let directory = TempDir::new().unwrap();
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
        read(timeout(LIMIT, healthy).await.unwrap().unwrap().into_body()).await,
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
        read(timeout(LIMIT, response).await.unwrap().unwrap().into_body()).await,
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
        let directory = TempDir::new().unwrap();
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
            (
                Box::new(socket) as BoxIo,
                Guards {
                    tasks: vec![],
                    reset: None,
                },
            )
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
        send(&mut upload, b"first", false).await;
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
                .unwrap()
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
async fn unsupported_only_alpn_fails_and_initial_inner_h2_request_has_a_deadline() {
    let directory = TempDir::new().unwrap();
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
async fn concurrent_inner_h2_requests_serialize_on_the_single_h1_upstream_without_502() {
    let directory = TempDir::new().unwrap();
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
        // Hold the first response open while a second inner stream is queued.
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
    let (mut second, _) = sender
        .send_request(inner_request(target, "/second"), true)
        .unwrap();
    assert!(
        timeout(Duration::from_millis(50), &mut second)
            .await
            .is_err(),
        "the second stream must wait, not fail readiness with 502"
    );
    complete.send(()).unwrap();
    assert_eq!(read(first).await, b"rst");
    let second = timeout(LIMIT, second).await.unwrap().unwrap();
    assert_eq!(second.status(), 200);
    assert_eq!(read(second.into_body()).await, b"second");
    upstream.await.unwrap();
    driver.abort();
    drop(sender);
    drop(guards);
    proxy.stop().await;
}

#[tokio::test]
async fn unsupported_upstream_alpn_fails_before_client_handshake_completes() {
    let directory = TempDir::new().unwrap();
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

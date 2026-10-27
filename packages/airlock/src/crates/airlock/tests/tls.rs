// cspell:words alpn keepalive
#[allow(dead_code)]
mod common;

use std::{
    fs,
    future::poll_fn,
    io,
    net::SocketAddr,
    sync::{Arc, Mutex},
    time::Duration,
};

use airlock::{ca, config::Interception, server};
use h2::SendStream;
use hyper::{Request, body::Bytes};
use rcgen::{CertificateParams, KeyPair};
use rustls::{
    ClientConfig, RootCertStore, ServerConfig,
    pki_types::{PrivatePkcs8KeyDer, ServerName},
};
use tempfile::TempDir;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    task::JoinHandle,
    time::timeout,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

const LIMIT: Duration = Duration::from_secs(3);
trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}
type BoxIo = Box<dyn Io>;

struct Guards {
    tasks: Vec<JoinHandle<()>>,
    reset: Option<Arc<Mutex<SendStream<Bytes>>>>,
}
impl Drop for Guards {
    fn drop(&mut self) {
        if let Some(send) = &self.reset {
            send.lock().unwrap().send_reset(h2::Reason::CANCEL);
        }
        for task in &self.tasks {
            task.abort();
        }
    }
}

async fn outer(address: SocketAddr, target: &str, h2: bool) -> (BoxIo, Guards) {
    let mut socket = TcpStream::connect(address).await.unwrap();
    if !h2 {
        let response = common::request(&mut socket, "CONNECT", target).await;
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        return (
            Box::new(socket),
            Guards {
                tasks: vec![],
                reset: None,
            },
        );
    }
    let (mut sender, driver) = h2::client::handshake(socket).await.unwrap();
    let driver = tokio::spawn(async {
        let _ = driver.await;
    });
    let (response, send) = sender
        .send_request(
            Request::builder()
                .method("CONNECT")
                .uri(target)
                .body(())
                .unwrap(),
            false,
        )
        .unwrap();
    let response = timeout(LIMIT, response).await.unwrap().unwrap();
    assert_eq!(response.status(), 200);
    let mut recv = response.into_body();
    let send = Arc::new(Mutex::new(send));
    let writer = Arc::clone(&send);
    let (client, bridge) = tokio::io::duplex(8192);
    let (mut read, mut write) = tokio::io::split(bridge);
    let relay = tokio::spawn(async move {
        let upload = async {
            let mut buffer = [0; 8192];
            loop {
                let count = read.read(&mut buffer).await?;
                if count == 0 {
                    writer
                        .lock()
                        .unwrap()
                        .send_data(Bytes::new(), true)
                        .map_err(io::Error::other)?;
                    return Ok::<_, io::Error>(());
                }
                let mut bytes = Bytes::copy_from_slice(&buffer[..count]);
                while !bytes.is_empty() {
                    writer.lock().unwrap().reserve_capacity(bytes.len());
                    let capacity = poll_fn(|cx| writer.lock().unwrap().poll_capacity(cx))
                        .await
                        .unwrap()
                        .map_err(io::Error::other)?;
                    let count = capacity.min(bytes.len());
                    writer
                        .lock()
                        .unwrap()
                        .send_data(bytes.split_to(count), false)
                        .map_err(io::Error::other)?;
                }
            }
        };
        let download = async {
            while let Some(bytes) = recv.data().await {
                let bytes = bytes.map_err(io::Error::other)?;
                write.write_all(&bytes).await?;
                recv.flow_control()
                    .release_capacity(bytes.len())
                    .map_err(io::Error::other)?;
            }
            write.shutdown().await
        };
        let _ = tokio::try_join!(upload, download);
    });
    (
        Box::new(client),
        Guards {
            tasks: vec![driver, relay],
            reset: Some(send),
        },
    )
}

fn fixture_certificate(host: &str, expired: bool) -> (Arc<ServerConfig>, String) {
    let mut parameters = CertificateParams::new(vec![host.to_owned()]).unwrap();
    if expired {
        parameters.not_before = time::OffsetDateTime::now_utc() - time::Duration::days(2);
        parameters.not_after = time::OffsetDateTime::now_utc() - time::Duration::days(1);
    }
    let key = KeyPair::generate().unwrap();
    let certificate = parameters.self_signed(&key).unwrap();
    let mut config =
        ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![certificate.der().clone()],
                PrivatePkcs8KeyDer::from(key.serialize_der()).into(),
            )
            .unwrap();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    (Arc::new(config), certificate.pem())
}

async fn proxy(directory: &TempDir, target: SocketAddr, root: Option<&str>) -> common::Server {
    let ca_directory = directory.path().join("ca");
    ca::init(&ca_directory).unwrap();
    // Keep fixtures hermetic when a Nix build has no host certificate store.
    // None trusts an unrelated fixture, so untrusted origins still fail closed.
    let fallback = fixture_certificate("unused.test", false).1;
    let path = directory.path().join("upstream.pem");
    fs::write(&path, root.unwrap_or(&fallback)).unwrap();
    let upstream_roots = Some(path);
    let listener = server::bind("127.0.0.1:0".parse().unwrap()).await.unwrap();
    let address = listener.local_addr().unwrap();
    let (shutdown, stopped) = oneshot::channel();
    let config = Interception {
        ca_directory,
        destinations: vec![format!("localhost:{}", target.port())],
        upstream_roots,
    };
    let task = tokio::spawn(server::serve(listener, Some(config), async {
        let _ = stopped.await;
    }));
    common::Server {
        address,
        shutdown,
        task,
    }
}

fn client_config(directory: &TempDir) -> Arc<ClientConfig> {
    let pem = pem::parse(fs::read(directory.path().join("ca/ca.pem")).unwrap()).unwrap();
    let mut roots = RootCertStore::empty();
    roots.add(pem.into_contents().into()).unwrap();
    let mut config =
        ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_root_certificates(roots)
            .with_no_client_auth();
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Arc::new(config)
}

async fn headers(socket: &mut (impl AsyncRead + Unpin)) -> String {
    timeout(LIMIT, async {
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            bytes.push(socket.read_u8().await.unwrap());
        }
        String::from_utf8(bytes).unwrap()
    })
    .await
    .unwrap()
}

async fn tls_client(
    directory: &TempDir,
    socket: BoxIo,
    name: &str,
) -> io::Result<tokio_rustls::client::TlsStream<BoxIo>> {
    timeout(
        LIMIT,
        TlsConnector::from(client_config(directory))
            .connect(ServerName::try_from(name.to_owned()).unwrap(), socket),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn selected_h1_and_h2_connect_preserve_native_payload_and_stream_sse() {
    for h2 in [false, true] {
        let directory = TempDir::new().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = listener.local_addr().unwrap();
        let (config, root) = fixture_certificate("localhost", false);
        let (continue_send, continue_recv) = oneshot::channel();
        let upstream = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut socket = TlsAcceptor::from(config).accept(socket).await.unwrap();
            assert_eq!(
                socket.get_ref().1.alpn_protocol(),
                Some(b"http/1.1".as_slice())
            );
            let head = headers(&mut socket).await;
            assert!(head.starts_with("POST /messages?q=1 HTTP/1.1"), "{head}");
            assert!(
                head.contains("authorization: Bearer native-fixture\r\n"),
                "{head}"
            );
            assert!(head.contains("content-type: application/json"), "{head}");
            for absent in [
                "proxy-authorization",
                "proxy-connection",
                "x-hop",
                "upgrade",
                "connection:",
            ] {
                assert!(!head.contains(absent), "{head}");
            }
            let mut body = [0; 24];
            socket.read_exact(&mut body).await.unwrap();
            assert_eq!(&body, br#"{"model":"native-model"}"#);
            socket.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/event-stream\r\nConnection: x-up-hop\r\nX-Up-Hop: remove\r\n\r\n8\r\ndata: 1\n\r\n").await.unwrap();
            continue_recv.await.unwrap();
            socket
                .write_all(b"8\r\ndata: 2\n\r\n0\r\n\r\n")
                .await
                .unwrap();
            socket.shutdown().await.unwrap();
        });
        let proxy = proxy(&directory, target, Some(&root)).await;
        let (socket, guards) =
            outer(proxy.address, &format!("localhost:{}", target.port()), h2).await;
        let mut client = tls_client(&directory, socket, "localhost").await.unwrap();
        assert_eq!(
            client.get_ref().1.alpn_protocol(),
            Some(b"http/1.1".as_slice())
        );
        client.write_all(format!("POST https://localhost:{}/messages?q=1 HTTP/1.1\r\nHost: localhost:{}\r\nAuthorization: Bearer native-fixture\r\nContent-Type: application/json\r\nContent-Length: 24\r\nConnection: x-hop\r\nX-Hop: remove\r\nProxy-Authorization: Basic fixture\r\nProxy-Connection: keep-alive\r\n\r\n", target.port(), target.port()).as_bytes()).await.unwrap();
        client
            .write_all(br#"{"model":"native-model"}"#)
            .await
            .unwrap();
        let head = headers(&mut client).await;
        assert!(head.starts_with("HTTP/1.1 200"), "{head}");
        assert!(head.contains("content-type: text/event-stream"), "{head}");
        assert!(!head.contains("x-up-hop"), "{head}");
        let mut first = [0; 13];
        timeout(LIMIT, client.read_exact(&mut first))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&first, b"8\r\ndata: 1\n\r\n");
        // The first event arrives with the rest withheld; advancing beyond
        // every setup/header deadline must not kill a live response body.
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(11)).await;
        tokio::time::resume();
        continue_send.send(()).unwrap();
        let mut rest = [0; 18];
        timeout(LIMIT, client.read_exact(&mut rest))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&rest, b"8\r\ndata: 2\n\r\n0\r\n\r\n");
        upstream.await.unwrap();
        drop(client);
        drop(guards);
        proxy.stop().await;
    }
}

#[tokio::test]
async fn sni_mismatch_and_plaintext_never_dial_the_selected_upstream() {
    let directory = TempDir::new().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let (_, root) = fixture_certificate("localhost", false);
    let proxy = proxy(&directory, target, Some(&root)).await;
    for h2 in [false, true] {
        let (socket, guards) =
            outer(proxy.address, &format!("localhost:{}", target.port()), h2).await;
        assert!(tls_client(&directory, socket, "wrong.test").await.is_err());
        drop(guards);
        let (mut socket, guards) =
            outer(proxy.address, &format!("localhost:{}", target.port()), h2).await;
        socket
            .write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .await
            .unwrap();
        let mut alert = Vec::new();
        let _ = timeout(LIMIT, socket.read_to_end(&mut alert))
            .await
            .unwrap();
        assert!(
            alert.is_empty() || alert[0] == 21,
            "plaintext was not rejected with a TLS alert"
        );
        drop(guards);
    }
    let (socket, guards) = outer(
        proxy.address,
        &format!("localhost:{}", target.port()),
        false,
    )
    .await;
    let mut config = (*client_config(&directory)).clone();
    config.enable_sni = false;
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
    assert!(
        timeout(Duration::from_millis(100), listener.accept())
            .await
            .is_err()
    );
    proxy.stop().await;
}

#[tokio::test]
async fn upstream_untrusted_wrong_name_and_expired_certificates_fail_before_downstream_handshake() {
    for (host, expired, trusted) in [
        ("localhost", false, false),
        ("wrong.test", false, true),
        ("localhost", true, true),
    ] {
        let directory = TempDir::new().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = listener.local_addr().unwrap();
        let (config, root) = fixture_certificate(host, expired);
        let upstream = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            assert!(TlsAcceptor::from(config).accept(socket).await.is_err());
        });
        let proxy = proxy(&directory, target, trusted.then_some(root.as_str())).await;
        let (socket, guards) = outer(
            proxy.address,
            &format!("localhost:{}", target.port()),
            false,
        )
        .await;
        assert!(tls_client(&directory, socket, "localhost").await.is_err());
        timeout(LIMIT, upstream).await.unwrap().unwrap();
        drop(guards);
        proxy.stop().await;
    }
}

#[tokio::test]
async fn inner_authority_scheme_nested_connect_and_upgrade_are_rejected_without_upstream_http() {
    let directory = TempDir::new().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let (config, root) = fixture_certificate("localhost", false);
    let upstream = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut socket = TlsAcceptor::from(config).accept(socket).await.unwrap();
        let mut bytes = Vec::new();
        let _ = socket.read_to_end(&mut bytes).await;
        assert!(bytes.is_empty(), "unexpected upstream plaintext: {bytes:?}");
    });
    let proxy = proxy(&directory, target, Some(&root)).await;
    let (socket, guards) = outer(
        proxy.address,
        &format!("localhost:{}", target.port()),
        false,
    )
    .await;
    let mut client = tls_client(&directory, socket, "localhost").await.unwrap();
    let host = format!("localhost:{}", target.port());
    for request in [
        "GET / HTTP/1.1\r\nHost: wrong.test\r\n\r\n".to_owned(),
        "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".to_owned(),
        format!("GET https://wrong.test/ HTTP/1.1\r\nHost: {host}\r\n\r\n"),
        format!("GET http://{host}/ HTTP/1.1\r\nHost: {host}\r\n\r\n"),
        format!("CONNECT {host} HTTP/1.1\r\nHost: {host}\r\n\r\n"),
        format!(
            "GET / HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: upgrade\r\n\r\n"
        ),
    ] {
        client.write_all(request.as_bytes()).await.unwrap();
        let head = headers(&mut client).await;
        assert!(head.starts_with("HTTP/1.1 400"), "{head}");
        let length: usize = head
            .lines()
            .find_map(|line| line.strip_prefix("content-length: "))
            .unwrap()
            .parse()
            .unwrap();
        client.read_exact(&mut vec![0; length]).await.unwrap();
    }
    drop(client);
    drop(guards);
    timeout(LIMIT, upstream).await.unwrap().unwrap();
    proxy.stop().await;
}

#[tokio::test]
async fn unselected_dns_port_and_ip_remain_opaque_on_both_outer_protocols() {
    let directory = TempDir::new().unwrap();
    let selected = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = proxy(&directory, selected.local_addr().unwrap(), None).await;
    for h2 in [false, true] {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = listener.local_addr().unwrap();
        let upstream = tokio::spawn(async move {
            for _ in 0..2 {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut bytes = [0; 12];
                socket.read_exact(&mut bytes).await.unwrap();
                assert_eq!(&bytes, b"opaque bytes");
                socket.write_all(b"echo").await.unwrap();
            }
        });
        for authority in [format!("localhost:{}", target.port()), target.to_string()] {
            let (mut socket, guards) = outer(proxy.address, &authority, h2).await;
            socket.write_all(b"opaque bytes").await.unwrap();
            let mut reply = [0; 4];
            timeout(LIMIT, socket.read_exact(&mut reply))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(&reply, b"echo");
            drop(socket);
            drop(guards);
        }
        upstream.await.unwrap();
    }
    assert!(
        timeout(Duration::from_millis(50), selected.accept())
            .await
            .is_err()
    );
    proxy.stop().await;
}

#[tokio::test]
async fn selected_tls_half_close_keeps_the_pending_response_alive() {
    for h2 in [false, true] {
        let directory = TempDir::new().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = listener.local_addr().unwrap();
        let (config, root) = fixture_certificate("localhost", false);
        let (received, request_seen) = oneshot::channel();
        let (reply, may_reply) = oneshot::channel();
        let upstream = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut socket = TlsAcceptor::from(config).accept(socket).await.unwrap();
            assert!(
                headers(&mut socket)
                    .await
                    .starts_with("GET /final HTTP/1.1")
            );
            received.send(()).unwrap();
            may_reply.await.unwrap();
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfinal")
                .await
                .unwrap();
            socket.shutdown().await.unwrap();
        });
        let proxy = proxy(&directory, target, Some(&root)).await;
        let (socket, guards) =
            outer(proxy.address, &format!("localhost:{}", target.port()), h2).await;
        let mut client = tls_client(&directory, socket, "localhost").await.unwrap();
        client
            .write_all(
                format!(
                    "GET /final HTTP/1.1\r\nHost: localhost:{}\r\n\r\n",
                    target.port()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        timeout(LIMIT, request_seen).await.unwrap().unwrap();
        client.shutdown().await.unwrap();
        // Slow inference may wait longer than setup/header-read deadlines
        // before its first response header. Cancellation still owns the wait.
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(11)).await;
        tokio::time::resume();
        reply.send(()).unwrap();
        assert!(headers(&mut client).await.starts_with("HTTP/1.1 200"));
        let mut bytes = [0; 5];
        timeout(LIMIT, client.read_exact(&mut bytes))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&bytes, b"final");
        upstream.await.unwrap();
        drop(client);
        drop(guards);
        proxy.stop().await;
    }
}

#[tokio::test]
async fn pipelined_h1_rst_and_h2_reset_after_end_stream_cancel_owned_tls_upstream() {
    for h2 in [false, true] {
        let directory = TempDir::new().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = listener.local_addr().unwrap();
        let (config, root) = fixture_certificate("localhost", false);
        let (received, request_seen) = oneshot::channel();
        let upstream = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut socket = TlsAcceptor::from(config).accept(socket).await.unwrap();
            assert!(
                headers(&mut socket)
                    .await
                    .starts_with("GET /pending HTTP/1.1")
            );
            received.send(()).unwrap();
            let result = socket.read(&mut [0]).await;
            assert!(result.is_err() || result.unwrap() == 0);
        });
        let proxy = proxy(&directory, target, Some(&root)).await;
        let (socket, guards) = if h2 {
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
        let mut client = tls_client(&directory, socket, "localhost").await.unwrap();
        let request = format!(
            "GET /pending HTTP/1.1\r\nHost: localhost:{}\r\n\r\n",
            target.port()
        );
        client
            .write_all(request.repeat(2).as_bytes())
            .await
            .unwrap();
        timeout(LIMIT, request_seen).await.unwrap().unwrap();
        if h2 {
            // END_STREAM is a half-close, not cancellation. The independent
            // observer must still see the later reset during header wait.
            client.shutdown().await.unwrap();
            let mut upstream = upstream;
            assert!(
                timeout(Duration::from_millis(50), &mut upstream)
                    .await
                    .is_err()
            );
            guards
                .reset
                .as_ref()
                .unwrap()
                .lock()
                .unwrap()
                .send_reset(h2::Reason::CANCEL);
            timeout(LIMIT, upstream).await.unwrap().unwrap();
            drop(client);
        } else {
            drop(client);
            timeout(LIMIT, upstream).await.unwrap().unwrap();
        }
        drop(guards);
        let mut health = proxy.client().await;
        assert!(
            common::request(&mut health, "GET", "/health")
                .await
                .starts_with("HTTP/1.1 200")
        );
        drop(health);
        proxy.stop().await;
    }
}

#[tokio::test]
async fn selected_h2_tls_streams_chunked_upload_before_eof_and_crosses_flow_control_windows() {
    use tokio::io::AsyncBufReadExt;
    let directory = TempDir::new().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let (config, root) = fixture_certificate("localhost", false);
    let (first, observed) = oneshot::channel();
    let payload = vec![b'x'; 150_000];
    let upstream = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let socket = TlsAcceptor::from(config).accept(socket).await.unwrap();
        let mut socket = tokio::io::BufReader::new(socket);
        let head = headers(&mut socket).await;
        assert!(head.contains("transfer-encoding: chunked"), "{head}");
        let mut first = Some(first);
        let mut body = Vec::new();
        loop {
            let mut line = String::new();
            socket.read_line(&mut line).await.unwrap();
            let size = usize::from_str_radix(line.trim(), 16).unwrap();
            let mut bytes = vec![0; size + 2];
            socket.read_exact(&mut bytes).await.unwrap();
            assert_eq!(&bytes[size..], b"\r\n");
            if size == 0 {
                break;
            }
            body.extend_from_slice(&bytes[..size]);
            if body.len() >= 5
                && let Some(first) = first.take()
            {
                first.send(()).unwrap();
            }
        }
        assert_eq!(&body[..5], b"first");
        assert_eq!(&body[5..], &vec![b'x'; 150_000]);
        socket
            .get_mut()
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 150000\r\n\r\n")
            .await
            .unwrap();
        socket.get_mut().write_all(&body[5..]).await.unwrap();
        socket.get_mut().shutdown().await.unwrap();
    });
    let proxy = proxy(&directory, target, Some(&root)).await;
    let (socket, guards) =
        outer(proxy.address, &format!("localhost:{}", target.port()), true).await;
    let mut client = tls_client(&directory, socket, "localhost").await.unwrap();
    client.write_all(format!("GET /stream HTTP/1.1\r\nHost: localhost:{}\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nfirst\r\n", target.port()).as_bytes()).await.unwrap();
    timeout(LIMIT, observed)
        .await
        .expect("upstream receives partial upload before EOF")
        .unwrap();
    client
        .write_all(format!("{:x}\r\n", payload.len()).as_bytes())
        .await
        .unwrap();
    client.write_all(&payload).await.unwrap();
    client.write_all(b"\r\n0\r\n\r\n").await.unwrap();
    client.flush().await.unwrap();
    assert!(headers(&mut client).await.starts_with("HTTP/1.1 200"));
    let mut response = vec![0; payload.len()];
    timeout(LIMIT, client.read_exact(&mut response))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(response, payload);
    upstream.await.unwrap();
    drop(client);
    drop(guards);
    proxy.stop().await;
}

#[tokio::test]
async fn healthy_tls_requests_reuse_one_upstream_then_connection_close_drains_and_closes_client() {
    for h2 in [false, true] {
        let directory = TempDir::new().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = listener.local_addr().unwrap();
        let (config, root) = fixture_certificate("localhost", false);
        let payload = vec![b'z'; 150_000];
        let upstream_payload = payload.clone();
        let upstream = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut socket = TlsAcceptor::from(config).accept(socket).await.unwrap();
            for body in ["one", "two", "three"] {
                assert!(
                    headers(&mut socket)
                        .await
                        .starts_with("GET /reuse HTTP/1.1")
                );
                socket
                    .write_all(
                        format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}",
                            body.len()
                        )
                        .as_bytes(),
                    )
                    .await
                    .unwrap();
                socket.flush().await.unwrap();
            }
            assert!(
                headers(&mut socket)
                    .await
                    .starts_with("GET /close HTTP/1.1")
            );
            socket
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
                        upstream_payload.len()
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
            socket.write_all(&upstream_payload).await.unwrap();
            socket.shutdown().await.unwrap();
        });
        let proxy = proxy(&directory, target, Some(&root)).await;
        let (socket, guards) =
            outer(proxy.address, &format!("localhost:{}", target.port()), h2).await;
        let mut client = tls_client(&directory, socket, "localhost").await.unwrap();
        let request = format!(
            "GET /reuse HTTP/1.1\r\nHost: localhost:{}\r\n\r\n",
            target.port()
        );
        client.write_all(request.as_bytes()).await.unwrap();
        let head = headers(&mut client).await;
        assert!(head.starts_with("HTTP/1.1 200"), "{head}");
        let mut first = [0; 3];
        client.read_exact(&mut first).await.unwrap();
        assert_eq!(&first, b"one");
        // Follow a complete response with two pipelined requests; all three
        // must use the original verified upstream connection without 502s.
        client
            .write_all(request.repeat(2).as_bytes())
            .await
            .unwrap();
        for expected in ["two", "three"] {
            let head = headers(&mut client).await;
            assert!(head.starts_with("HTTP/1.1 200"), "{head}");
            let mut body = vec![0; expected.len()];
            client.read_exact(&mut body).await.unwrap();
            assert_eq!(body, expected.as_bytes());
        }
        client
            .write_all(
                format!(
                    "GET /close HTTP/1.1\r\nHost: localhost:{}\r\n\r\n",
                    target.port()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let head = headers(&mut client).await;
        assert!(head.starts_with("HTTP/1.1 200"), "{head}");
        let mut body = vec![0; payload.len()];
        timeout(LIMIT, client.read_exact(&mut body))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            body, payload,
            "driver completion must drain the active response"
        );
        assert_eq!(
            timeout(LIMIT, client.read(&mut [0]))
                .await
                .expect("upstream closure must close downstream keepalive")
                .unwrap(),
            0
        );
        upstream.await.unwrap();
        drop(client);
        drop(guards);
        proxy.stop().await;
    }
}

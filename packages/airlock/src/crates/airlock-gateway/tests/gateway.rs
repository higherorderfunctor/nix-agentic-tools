use std::{
    io::{self, Write},
    net::SocketAddr,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use airlock_core::config::{Config, RawConfig};
use airlock_gateway::{Error, Gateway};
use base64::{Engine as _, prelude::BASE64_STANDARD};
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    task::JoinHandle,
    time::timeout,
};
use tracing::instrument::WithSubscriber;

const TOKEN: &str = "fake-SECRET-harness-token";

#[derive(Clone, Default)]
struct Capture(Arc<Mutex<Vec<u8>>>);

impl Write for Capture {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0
            .lock()
            .expect("capture lock")
            .extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Capture {
    fn events(&self) -> Vec<Value> {
        let bytes = self.0.lock().expect("capture lock");
        let text = std::str::from_utf8(&bytes).expect("JSON UTF-8");
        assert!(!text.contains(TOKEN), "audit exposed token: {text}");
        assert!(
            !text.contains(&BASE64_STANDARD.encode(format!("harness:{TOKEN}"))),
            "audit exposed Basic credentials"
        );
        assert!(!text.to_ascii_lowercase().contains("proxy-authorization"));
        text.lines()
            .map(|line| serde_json::from_str(line).expect("JSON event"))
            .collect()
    }
}

struct Running {
    address: SocketAddr,
    capture: Capture,
    directory: TempDir,
    shutdown: oneshot::Sender<()>,
    task: JoinHandle<Result<(), Error>>,
}

impl Running {
    async fn start(unknown_hosts: &str, intercepted: &[&str]) -> Self {
        let directory = tempfile::tempdir().expect("tempdir");
        std::fs::write(directory.path().join("token"), format!("{TOKEN}\n")).expect("write token");
        let gateway = Gateway::bind(config(&directory, unknown_hosts, intercepted))
            .await
            .expect("bind gateway");
        let address = gateway.local_addr();
        assert_eq!(address.ip(), std::net::Ipv4Addr::LOCALHOST);
        let capture = Capture::default();
        let writer = capture.clone();
        let subscriber = tracing_subscriber::fmt()
            .json()
            .with_writer(move || writer.clone())
            .finish();
        let (shutdown, receiver) = oneshot::channel();
        let task = tokio::spawn(
            gateway
                .serve(async {
                    let _ = receiver.await;
                })
                .with_subscriber(subscriber),
        );
        Self {
            address,
            capture,
            directory,
            shutdown,
            task,
        }
    }

    async fn stop(self) -> Vec<Value> {
        self.shutdown.send(()).expect("request shutdown");
        timeout(Duration::from_secs(7), self.task)
            .await
            .expect("bounded shutdown")
            .expect("server task")
            .expect("serve");
        self.capture.events()
    }

    async fn request(
        &self,
        method: &str,
        target: &str,
        authorization: Option<&str>,
    ) -> (TcpStream, String) {
        let mut socket = TcpStream::connect(self.address)
            .await
            .expect("connect gateway");
        let auth = authorization.map_or_else(String::new, |value| {
            format!("Proxy-Authorization: {value}\r\n")
        });
        socket
            .write_all(
                format!("{method} {target} HTTP/1.1\r\nHost: localhost\r\n{auth}\r\n").as_bytes(),
            )
            .await
            .expect("request");
        let mut header = Vec::new();
        timeout(Duration::from_secs(2), async {
            while !header.ends_with(b"\r\n\r\n") {
                header.push(socket.read_u8().await.expect("response header"));
                assert!(header.len() < 8192);
            }
        })
        .await
        .expect("timely response");
        (socket, String::from_utf8(header).expect("header UTF-8"))
    }
}

fn config(directory: &TempDir, unknown_hosts: &str, intercepted: &[&str]) -> Config {
    Config::try_from(serde_json::from_value::<RawConfig>(json!({
        "clients": {"harness": {
            "grants": [{"credentials": ["claude"], "upstream": "anthropic"}],
            "token_file": directory.path().join("token")
        }},
        "credentials": {"claude": {
            "auth": {"file": directory.path().join("unused-upstream-secret"), "type": "oauth_bearer"},
            "upstream": "anthropic"
        }},
        "listen": "127.0.0.1:0",
        "state_dir": directory.path(),
        "unknown_hosts": unknown_hosts,
        "upstreams": {"anthropic": {"intercept": intercepted, "provider": "anthropic"}}
    })).expect("raw config")).expect("validated config")
}

fn basic(client: &str, token: &str) -> String {
    format!(
        "Basic {}",
        BASE64_STANDARD.encode(format!("{client}:{token}"))
    )
}

async fn sink() -> TcpListener {
    TcpListener::bind("127.0.0.1:0").await.expect("bind sink")
}

async fn echo() -> (u16, JoinHandle<u64>) {
    let listener = sink().await;
    let port = listener.local_addr().expect("sink address").port();
    let task = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.expect("accept upstream");
        let (mut read, mut write) = socket.split();
        tokio::io::copy(&mut read, &mut write).await.expect("echo")
    });
    (port, task)
}

fn fields(event: &Value) -> &Value {
    assert_eq!(event["fields"]["message"], "CONNECT closed");
    &event["fields"]
}

#[tokio::test]
async fn tunnel_echo_and_exact_audit_counts_without_credentials() {
    let (port, upstream) = echo().await;
    let server = Running::start("tunnel", &[]).await;
    // Token files are loaded once; deleting the file cannot affect later requests.
    std::fs::remove_file(server.directory.path().join("token")).expect("remove token");
    let (mut socket, header) = server
        .request(
            "CONNECT",
            &format!("localhost:{port}"),
            Some(&basic("harness", TOKEN)),
        )
        .await;
    assert!(
        header.starts_with("HTTP/1.1 200 Connection Established\r\n"),
        "{header}"
    );
    let payload = b"opaque\x00\xff\r\nGET /still-tunnel HTTP/1.1\r\n\r\n";
    socket.write_all(payload).await.expect("tunnel payload");
    let mut echoed = vec![0; payload.len()];
    timeout(Duration::from_secs(1), socket.read_exact(&mut echoed))
        .await
        .expect("echo deadline")
        .expect("echo read");
    assert_eq!(echoed, payload);
    drop(socket);
    assert_eq!(
        timeout(Duration::from_secs(1), upstream)
            .await
            .expect("upstream EOF")
            .expect("upstream task"),
        payload.len() as u64
    );
    let events = server.stop().await;
    assert_eq!(events.len(), 1);
    let audit = fields(&events[0]);
    assert_eq!(audit["client"], "harness");
    assert_eq!(audit["host"], "localhost");
    assert_eq!(audit["port"], port);
    assert_eq!(audit["decision"], "tunnel");
    assert_eq!(audit["outcome"], "closed");
    assert_eq!(audit["client_to_upstream"], payload.len());
    assert_eq!(audit["upstream_to_client"], payload.len());
    assert!(audit["duration_ms"].as_f64().expect("duration") >= 0.0);
}

#[tokio::test]
async fn authentication_failures_challenge_without_connecting_upstream() {
    let listener = sink().await;
    let target = format!(
        "localhost:{}",
        listener.local_addr().expect("sink address").port()
    );
    let server = Running::start("tunnel", &[]).await;
    let failures = [
        None,
        Some(basic("harness", "wrong")),
        Some(basic("stranger", TOKEN)),
        Some("Basic invalid!".to_owned()),
        Some("Bearer fake-SECRET-harness-token".to_owned()),
    ];
    for auth in failures {
        let (socket, header) = server.request("CONNECT", &target, auth.as_deref()).await;
        assert!(header.starts_with("HTTP/1.1 407 "), "{header}");
        assert!(
            header
                .to_ascii_lowercase()
                .contains("proxy-authenticate: basic realm=\"airlock\""),
            "{header}"
        );
        drop(socket);
    }
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    let events = server.stop().await;
    assert_eq!(events.len(), 5);
    for event in &events {
        assert_eq!(fields(event)["outcome"], "authentication_required");
    }
}

#[tokio::test]
async fn denied_targets_and_non_connect_never_reach_upstream() {
    let listener = sink().await;
    let port = listener.local_addr().expect("sink address").port();
    let server = Running::start("deny", &["api.anthropic.com"]).await;
    let targets = [
        format!("localhost:{port}"),
        format!("127.0.0.1:{port}"),
        format!("2130706433:{port}"),
        format!("0x7f000001:{port}"),
        format!("[::1]:{port}"),
        "localhost:0".to_owned(),
        "localhost".to_owned(),
        "localhost:abc".to_owned(),
        "fake-SECRET-harness-token@localhost:443".to_owned(),
    ];
    for target in &targets {
        let (socket, header) = server
            .request("CONNECT", target, Some(&basic("harness", TOKEN)))
            .await;
        assert!(header.starts_with("HTTP/1.1 403 "), "{target}: {header}");
        drop(socket);
    }
    let (socket, header) = server
        .request(
            "CONNECT",
            "api.anthropic.com:443",
            Some(&basic("harness", TOKEN)),
        )
        .await;
    assert!(header.starts_with("HTTP/1.1 501 "), "{header}");
    drop(socket);
    let (socket, header) = server
        .request("GET", &format!("http://localhost:{port}/"), None)
        .await;
    assert!(header.starts_with("HTTP/1.1 405 "), "{header}");
    drop(socket);
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    let events = server.stop().await;
    assert_eq!(events.len(), targets.len() + 1);
    assert_eq!(
        fields(events.last().expect("intercept event"))["decision"],
        "intercept"
    );
}

#[tokio::test]
async fn client_half_close_cancels_upstream_even_when_it_keeps_writing() {
    let listener = sink().await;
    let port = listener.local_addr().expect("sink address").port();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.expect("upstream");
        let mut bytes = Vec::new();
        timeout(Duration::from_secs(1), socket.read_to_end(&mut bytes))
            .await
            .expect("upstream EOF deadline")
            .expect("upstream EOF");
        bytes
    });
    let server = Running::start("tunnel", &[]).await;
    let (mut socket, header) = server
        .request(
            "CONNECT",
            &format!("localhost:{port}"),
            Some(&basic("harness", TOKEN)),
        )
        .await;
    assert!(header.starts_with("HTTP/1.1 200 Connection Established\r\n"));
    socket.write_all(b"before-close").await.expect("payload");
    socket.shutdown().await.expect("half-close client");
    assert_eq!(upstream.await.expect("upstream task"), b"before-close");
    let mut byte = [0];
    assert_eq!(
        timeout(Duration::from_secs(1), socket.read(&mut byte))
            .await
            .expect("client EOF deadline")
            .expect("client EOF"),
        0
    );
    drop(socket);
    let events = server.stop().await;
    assert_eq!(fields(&events[0])["client_to_upstream"], 12);
}

#[tokio::test]
async fn upstream_half_close_cancels_client_even_when_client_stays_open() {
    let listener = sink().await;
    let port = listener.local_addr().expect("sink address").port();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.expect("upstream");
        socket.write_all(b"bye").await.expect("upstream payload");
        socket.shutdown().await.expect("half-close upstream");
        let mut bytes = Vec::new();
        timeout(Duration::from_secs(1), socket.read_to_end(&mut bytes))
            .await
            .expect("upstream cancelled")
            .expect("upstream EOF");
    });
    let server = Running::start("tunnel", &[]).await;
    let (mut socket, header) = server
        .request(
            "CONNECT",
            &format!("localhost:{port}"),
            Some(&basic("harness", TOKEN)),
        )
        .await;
    assert!(header.starts_with("HTTP/1.1 200 Connection Established\r\n"));
    let mut bytes = Vec::new();
    timeout(Duration::from_secs(1), socket.read_to_end(&mut bytes))
        .await
        .expect("client EOF deadline")
        .expect("client EOF");
    assert_eq!(bytes, b"bye");
    upstream.await.expect("upstream task");
    drop(socket);
    let events = server.stop().await;
    assert_eq!(fields(&events[0])["upstream_to_client"], 3);
}

#[tokio::test]
async fn shutdown_drains_tunnel_then_closes_listener() {
    let (port, upstream) = echo().await;
    let server = Running::start("tunnel", &[]).await;
    let (mut socket, header) = server
        .request(
            "CONNECT",
            &format!("localhost:{port}"),
            Some(&basic("harness", TOKEN)),
        )
        .await;
    assert!(header.starts_with("HTTP/1.1 200 Connection Established\r\n"));
    server.shutdown.send(()).expect("shutdown");
    socket
        .write_all(b"still-live")
        .await
        .expect("payload after shutdown");
    let mut bytes = [0; 10];
    timeout(Duration::from_secs(1), socket.read_exact(&mut bytes))
        .await
        .expect("draining echo deadline")
        .expect("draining echo");
    assert_eq!(&bytes, b"still-live");
    drop(socket);
    timeout(Duration::from_secs(1), server.task)
        .await
        .expect("graceful drain")
        .expect("server task")
        .expect("serve");
    upstream.await.expect("upstream task");
    assert!(TcpStream::connect(server.address).await.is_err());
    assert_eq!(server.capture.events().len(), 1);
}

#[tokio::test]
async fn forced_shutdown_retains_counts_and_closes_both_peers() {
    let (port, upstream) = echo().await;
    let server = Running::start("tunnel", &[]).await;
    let (mut socket, header) = server
        .request(
            "CONNECT",
            &format!("localhost:{port}"),
            Some(&basic("harness", TOKEN)),
        )
        .await;
    assert!(header.starts_with("HTTP/1.1 200 Connection Established\r\n"));
    socket.write_all(b"counted").await.expect("payload");
    let mut bytes = [0; 7];
    socket.read_exact(&mut bytes).await.expect("echo");
    let started = Instant::now();
    let events = server.stop().await;
    assert!(started.elapsed() >= Duration::from_secs(4));
    assert!(started.elapsed() < Duration::from_secs(7));
    let audit = fields(&events[0]);
    assert_eq!(audit["outcome"], "cancelled");
    assert_eq!(audit["client_to_upstream"], 7);
    assert_eq!(audit["upstream_to_client"], 7);
    assert_eq!(socket.read(&mut bytes).await.expect("client EOF"), 0);
    assert_eq!(
        timeout(Duration::from_secs(1), upstream)
            .await
            .expect("upstream EOF")
            .expect("upstream task"),
        7
    );
}

#[tokio::test]
async fn startup_reports_all_empty_and_missing_client_token_files() {
    let directory = tempfile::tempdir().expect("tempdir");
    std::fs::write(directory.path().join("token"), "\n").expect("empty token");
    let initial = config(&directory, "tunnel", &[]);
    assert!(matches!(
        Gateway::bind(initial).await,
        Err(Error::Secrets(_))
    ));
    let raw = json!({
        "clients": {
            "empty": {"grants": [{"credentials": ["claude"], "upstream": "anthropic"}], "token_file": directory.path().join("token")},
            "missing": {"grants": [{"credentials": ["claude"], "upstream": "anthropic"}], "token_file": directory.path().join("missing")}
        },
        "credentials": {"claude": {"auth": {"file": "/unused", "type": "oauth_bearer"}, "upstream": "anthropic"}},
        "listen": "127.0.0.1:0", "state_dir": directory.path(), "upstreams": {"anthropic": {"intercept": [], "provider": "anthropic"}}
    });
    let raw: RawConfig = serde_json::from_value(raw).expect("raw");
    let Err(Error::Secrets(errors)) = Gateway::bind(Config::try_from(raw).expect("config")).await
    else {
        panic!("startup accepted broken secrets");
    };
    assert_eq!(errors.0.len(), 2);
    let message = errors.to_string();
    assert!(
        message.contains(directory.path().join("token").to_str().expect("path")),
        "{message}"
    );
    assert!(
        message.contains(directory.path().join("missing").to_str().expect("path")),
        "{message}"
    );
}

#[tokio::test]
async fn upstream_reset_retains_successful_write_counts() {
    let listener = sink().await;
    let port = listener.local_addr().expect("sink address").port();
    let (reset, reset_requested) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.expect("upstream");
        let mut payload = [0; 7];
        socket.read_exact(&mut payload).await.expect("payload");
        socket.write_all(&payload).await.expect("echo");
        reset_requested.await.expect("reset requested");
        socket.set_zero_linger().expect("reset on drop");
    });
    let server = Running::start("tunnel", &[]).await;
    let (mut socket, header) = server
        .request(
            "CONNECT",
            &format!("localhost:{port}"),
            Some(&basic("harness", TOKEN)),
        )
        .await;
    assert!(header.starts_with("HTTP/1.1 200 Connection Established\r\n"));
    socket.write_all(b"counted").await.expect("payload");
    let mut echoed = [0; 7];
    socket.read_exact(&mut echoed).await.expect("echo");
    reset.send(()).expect("reset upstream");
    upstream.await.expect("upstream task");
    assert_eq!(
        timeout(Duration::from_secs(1), socket.read(&mut echoed))
            .await
            .expect("client closed")
            .expect("EOF"),
        0
    );
    drop(socket);
    let events = server.stop().await;
    assert_eq!(events.len(), 1);
    let audit = fields(&events[0]);
    assert_eq!(audit["outcome"], "io_error");
    assert_eq!(audit["client_to_upstream"], 7);
    assert_eq!(audit["upstream_to_client"], 7);
}

mod support;

use std::time::{Duration, Instant};

use airlock_core::config::{Config, RawConfig};
use airlock_gateway::{Error, Gateway};
use rustls::RootCertStore;
use serde_json::json;
use support::{Running, TOKEN, TestCa, basic, config, fields, sink};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::oneshot,
    task::JoinHandle,
    time::timeout,
};

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
    assert_eq!(events.len(), targets.len());
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
    for credential in ["claude", "backup"] {
        std::fs::write(directory.path().join(credential), "fake-REAL-oauth\n").expect("credential");
    }
    let initial = config(&directory, "tunnel", &[]);
    assert!(matches!(
        Gateway::bind(initial, &directory.path().join("ca"), TestCa::new().roots()).await,
        Err(Error::Secrets(_))
    ));
    let raw = json!({
        "clients": {
            "empty": {"grants": ["anthropic"], "token_file": directory.path().join("token")},
            "missing": {"grants": ["anthropic"], "token_file": directory.path().join("missing")}
        },
        "credentials": {"claude": {"auth": {"file": directory.path().join("claude"), "type": "oauth_bearer"}, "provider": "claude"}},
        "groups": {"anthropic": {"intercept": [], "members": {"claude": {"models": []}}, "primary": "claude", "protocol": "anthropic"}},
        "listen": "127.0.0.1:0", "providers": {"claude": {"preset": "claude"}}, "state_dir": directory.path()
    });
    let raw: RawConfig = serde_json::from_value(raw).expect("raw");
    let Err(Error::Secrets(errors)) = Gateway::bind(
        Config::try_from(raw).expect("config"),
        &directory.path().join("ca"),
        TestCa::new().roots(),
    )
    .await
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
async fn startup_reports_each_granted_credential_file_error() {
    let directory = tempfile::tempdir().expect("tempdir");
    std::fs::write(directory.path().join("token"), format!("{TOKEN}\n")).expect("token");
    std::fs::write(directory.path().join("empty"), "\n").expect("empty credential");
    let empty = directory.path().join("empty");
    let missing = directory.path().join("missing");
    let raw = json!({
        "clients": {
            "harness": {
                "grants": ["anthropic", "other"],
                "token_file": directory.path().join("token")
            }
        },
        "credentials": {
            "empty": {"auth": {"file": empty, "type": "oauth_bearer"}, "provider": "claude"},
            "missing": {"auth": {"file": missing, "type": "oauth_bearer"}, "provider": "claude"}
        },
        "groups": {
            "anthropic": {"intercept": [], "members": {"empty": {"models": []}}, "primary": "empty", "protocol": "anthropic"},
            "other": {"intercept": [], "members": {"missing": {"models": []}}, "primary": "missing", "protocol": "anthropic"}
        },
        "listen": "127.0.0.1:0",
        "providers": {"claude": {"preset": "claude"}},
        "state_dir": directory.path()
    });
    let raw: RawConfig = serde_json::from_value(raw).expect("raw");
    let Err(Error::Secrets(errors)) = Gateway::bind(
        Config::try_from(raw).expect("config"),
        &directory.path().join("ca"),
        TestCa::new().roots(),
    )
    .await
    else {
        panic!("startup accepted broken granted credentials");
    };
    assert_eq!(errors.0.len(), 2);
    let message = errors.to_string();
    assert!(
        message.contains(empty.to_str().expect("empty path")),
        "{message}"
    );
    assert!(
        message.contains(missing.to_str().expect("missing path")),
        "{message}"
    );
}

#[tokio::test]
async fn startup_does_not_load_credentials_without_grants() {
    let directory = tempfile::tempdir().expect("tempdir");
    std::fs::write(directory.path().join("token"), format!("{TOKEN}\n")).expect("token");
    std::fs::write(directory.path().join("granted"), "fake-REAL-oauth\n").expect("granted");
    let raw = json!({
        "clients": {
            "harness": {
                "grants": ["anthropic"],
                "token_file": directory.path().join("token")
            }
        },
        "credentials": {
            "granted": {"auth": {"file": directory.path().join("granted"), "type": "oauth_bearer"}, "provider": "claude"},
            "unused": {"auth": {"file": directory.path().join("unused"), "type": "oauth_bearer"}, "provider": "claude"}
        },
        "groups": {"anthropic": {"intercept": [], "members": {"granted": {"models": []}}, "primary": "granted", "protocol": "anthropic"}},
        "listen": "127.0.0.1:0",
        "providers": {"claude": {"preset": "claude"}},
        "state_dir": directory.path()
    });
    let raw: RawConfig = serde_json::from_value(raw).expect("raw");
    let gateway = Gateway::bind(
        Config::try_from(raw).expect("config"),
        &directory.path().join("ca"),
        TestCa::new().roots(),
    )
    .await
    .expect("unused credential is not loaded");
    assert!(!directory.path().join("unused").exists());
    drop(gateway);
}

#[tokio::test]
async fn unsupported_managed_oauth_fails_before_secret_loading() {
    let directory = tempfile::tempdir().expect("tempdir");
    let raw = serde_json::from_value::<RawConfig>(json!({
        "clients": {"harness": {"grants": ["anthropic"], "token_file": directory.path().join("missing-token")}},
        "credentials": {"claude": {"auth": {"type": "oauth_managed"}, "provider": "claude"}},
        "groups": {"anthropic": {"intercept": ["api.anthropic.com"], "members": {"claude": {"models": []}}, "primary": "claude", "protocol": "anthropic"}},
        "listen": "127.0.0.1:0",
        "providers": {"claude": {"preset": "claude"}},
        "state_dir": directory.path()
    })).expect("raw config");
    let config = Config::try_from(raw).expect("valid shape");
    assert!(matches!(
        Gateway::bind(config, &directory.path().join("ca"), TestCa::new().roots()).await,
        Err(Error::UnsupportedExecution(_))
    ));
    assert!(!directory.path().join("ca").exists());
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

#[tokio::test]
async fn startup_refuses_an_empty_upstream_root_store() {
    let directory = tempfile::tempdir().expect("tempdir");
    std::fs::write(directory.path().join("token"), format!("{TOKEN}\n")).expect("write token");
    for credential in ["claude", "backup"] {
        std::fs::write(directory.path().join(credential), "fake-REAL-oauth\n").expect("credential");
    }
    let result = Gateway::bind(
        config(&directory, "tunnel", &[]),
        &directory.path().join("ca"),
        RootCertStore::empty(),
    )
    .await;
    assert!(matches!(result, Err(Error::NoUpstreamRoots)));
}

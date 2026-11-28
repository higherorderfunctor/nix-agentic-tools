mod common;

use std::{io, time::Duration};

use airlock::server;
use common::{message, request, start, wait_for_listener_release};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    time::timeout,
};

#[tokio::test]
async fn listen_address_must_be_loopback() {
    // Test the IPv6 wildcard and an explicit non-loopback IPv4 address:
    // ruling out wildcards alone would not reject the latter.
    for address in ["192.0.2.1:8318", "[::]:8318"] {
        let error = server::bind(address.parse().unwrap()).await.unwrap_err();
        assert_eq!(
            error.kind(),
            io::ErrorKind::InvalidInput,
            "{address}: {error}"
        );
        assert!(
            error.to_string().contains("must be loopback"),
            "{address}: {error}"
        );
    }
    let listener = server::bind("[::1]:0".parse().unwrap()).await.unwrap();
    assert_eq!(
        listener.local_addr().unwrap().ip(),
        std::net::IpAddr::V6(std::net::Ipv6Addr::LOCALHOST)
    );
}

#[tokio::test]
async fn health_and_error_responses_keep_the_connection_usable() {
    let server = start().await;
    let mut socket = server.client().await;
    // One connection: a 404 or 405 must not prevent the next request.
    for (method, path, status, allow, body) in [
        ("GET", "/unknown", "404", None, None),
        ("POST", "/health", "405", Some("allow: GET"), None),
        ("GET", "/health", "200", None, Some("ok\n")),
    ] {
        let response = request(&mut socket, method, path).await;
        assert!(
            response.starts_with(&format!("HTTP/1.1 {status} ")),
            "{method} {path}: {response}"
        );
        let (headers, actual_body) = response.split_once("\r\n\r\n").unwrap();
        if let Some(allow) = allow {
            assert!(
                headers.lines().any(|line| line == allow),
                "{method} {path}: {response}"
            );
        }
        if let Some(body) = body {
            assert_eq!(actual_body, body, "{method} {path}");
        }
    }
    drop(socket);
    server.stop().await;
}

#[tokio::test]
async fn shutdown_releases_the_listener_before_draining_an_active_request() {
    let server = start().await;
    let address = server.address;
    let mut socket = server.client().await;
    request(&mut socket, "GET", "/health").await;
    socket.write_all(b"GET /health HTTP/1.1\r\n").await.unwrap();
    server.shutdown.send(()).unwrap();
    wait_for_listener_release(address).await;
    // The same accepted connection can finish its request during the grace.
    socket
        .write_all(b"Host: localhost\r\nConnection: close\r\n\r\n")
        .await
        .unwrap();
    assert!(message(&mut socket).await.starts_with("HTTP/1.1 200 "));
    timeout(Duration::from_secs(2), server.task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn shutdown_closes_idle_connection_after_grace() {
    let server = start().await;
    let mut socket = server.client().await;
    request(&mut socket, "GET", "/health").await;
    // A keep-alive connection must be closed even if it never submits another request.
    server.stop().await;
    assert_eq!(socket.read(&mut [0]).await.unwrap(), 0);
}

#[tokio::test]
async fn connection_limit_resumes_accepting_when_a_slot_is_freed() {
    let server = start().await;
    let mut sockets = Vec::new();
    for _ in 0..128 {
        let mut socket = server.client().await;
        request(&mut socket, "GET", "/health").await;
        sockets.push(socket);
    }
    let mut waiting = server.client().await;
    waiting
        .write_all(b"GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        .await
        .unwrap();
    assert!(
        timeout(Duration::from_millis(100), waiting.read_u8())
            .await
            .is_err()
    );
    drop(sockets.pop());
    assert!(message(&mut waiting).await.starts_with("HTTP/1.1 200 "));
    drop(waiting);
    drop(sockets);
    server.stop().await;
}

#[tokio::test]
async fn incomplete_headers_are_closed_on_the_header_deadline() {
    let server = start().await;
    let mut socket = server.client().await;
    socket.write_all(b"GET /health HTTP/1.1\r\n").await.unwrap();
    let mut bytes = Vec::new();
    timeout(Duration::from_secs(12), socket.read_to_end(&mut bytes))
        .await
        .expect("header deadline closes stalled client")
        .unwrap();
    assert!(
        bytes.is_empty(),
        "incomplete request must not reach health handler"
    );
    let mut healthy = server.client().await;
    assert!(
        request(&mut healthy, "GET", "/health")
            .await
            .starts_with("HTTP/1.1 200 ")
    );
    drop(healthy);
    server.stop().await;
}

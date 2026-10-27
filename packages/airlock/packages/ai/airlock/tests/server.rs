mod common;

use std::{io, time::Duration};

use airlock::server;
use common::{request, response, start};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    time::timeout,
};

#[tokio::test]
async fn listen_address_must_be_loopback() {
    for address in ["0.0.0.0:8318", "192.0.2.1:8318", "[::]:8318"] {
        let error = server::bind(address.parse().unwrap()).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        assert!(error.to_string().contains("must be loopback"));
    }
    let listener = server::bind("[::1]:0".parse().unwrap()).await.unwrap();
    assert!(listener.local_addr().unwrap().ip().is_loopback());
}

#[tokio::test]
async fn health_and_error_responses_keep_the_connection_usable() {
    let server = start().await;
    let mut socket = server.client().await;
    let health = request(&mut socket, "GET", "/health").await;
    assert!(health.starts_with("HTTP/1.1 200 "), "{health}");
    assert!(health.ends_with("\r\n\r\nok\n"), "{health}");
    let unknown = request(&mut socket, "GET", "/unknown").await;
    assert!(unknown.starts_with("HTTP/1.1 404 "), "{unknown}");
    let wrong_method = request(&mut socket, "POST", "/health").await;
    assert!(wrong_method.starts_with("HTTP/1.1 405 "), "{wrong_method}");
    assert!(wrong_method.contains("allow: GET\r\n"), "{wrong_method}");
    drop(socket);
    server.stop().await;
}

#[tokio::test]
async fn shutdown_drains_an_active_request_then_releases_the_listener() {
    let server = start().await;
    let address = server.address;
    let mut socket = server.client().await;
    request(&mut socket, "GET", "/health").await;
    socket.write_all(b"GET /health HTTP/1.1\r\n").await.unwrap();
    server.shutdown.send(()).unwrap();
    // The same accepted connection can finish its request during the grace.
    socket
        .write_all(b"Host: localhost\r\nConnection: close\r\n\r\n")
        .await
        .unwrap();
    assert!(response(&mut socket).await.starts_with("HTTP/1.1 200 "));
    timeout(Duration::from_secs(2), server.task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    server::bind(address)
        .await
        .expect("listener released after shutdown");
}

#[tokio::test]
async fn shutdown_closes_idle_connection_after_grace() {
    let server = start().await;
    let mut socket = server.client().await;
    request(&mut socket, "GET", "/health").await;
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
    assert!(response(&mut waiting).await.starts_with("HTTP/1.1 200 "));
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

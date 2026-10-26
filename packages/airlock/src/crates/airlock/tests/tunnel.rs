use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    time::Duration,
};

use airlock::tunnel;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
};

struct Proxy {
    address: SocketAddr,
    shutdown: oneshot::Sender<()>,
    task: tokio::task::JoinHandle<std::io::Result<()>>,
}

async fn start_proxy() -> Proxy {
    let listener = tunnel::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0))
        .await
        .expect("bind loopback proxy");
    let address = listener.local_addr().expect("proxy local address");
    let (shutdown, stopped) = oneshot::channel();
    let task = tokio::spawn(tunnel::serve(listener, async {
        let _ = stopped.await;
    }));

    Proxy {
        address,
        shutdown,
        task,
    }
}

async fn client(address: SocketAddr) -> TcpStream {
    TcpStream::connect(address).await.expect("connect proxy")
}

async fn send_request(socket: &mut TcpStream, request: &str) {
    socket
        .write_all(request.as_bytes())
        .await
        .expect("write proxy request");
}

async fn read_response(socket: &mut TcpStream) -> String {
    let mut response = Vec::new();
    let mut buffer = [0_u8; 1024];

    loop {
        let bytes = socket.read(&mut buffer).await.expect("read proxy response");
        if bytes == 0 {
            break;
        }

        response.extend_from_slice(&buffer[..bytes]);
        if response.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }

    String::from_utf8(response).expect("proxy response is UTF-8")
}

fn connect_request(address: SocketAddr) -> String {
    format!("CONNECT {address} HTTP/1.1\r\nHost: {address}\r\n\r\n")
}

#[tokio::test]
async fn listen_address_must_be_loopback() {
    let result = tunnel::bind(SocketAddr::new(
        IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1)),
        8318,
    ))
    .await
    .expect_err("non-loopback bind must fail");
    assert!(result.to_string().contains("must be loopback"));
}

#[tokio::test]
async fn connect_forwards_opaque_bytes_in_both_directions() {
    let upstream_listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind upstream");
    let upstream_address = upstream_listener.local_addr().expect("upstream address");
    let upstream = tokio::spawn(async move {
        let (mut upstream, _) = upstream_listener.accept().await.expect("accept upstream");
        let mut payload = vec![0_u8; 64_000];
        upstream
            .read_exact(&mut payload)
            .await
            .expect("read payload");
        for byte in &mut payload {
            *byte = byte.wrapping_add(1);
        }
        upstream.write_all(&payload).await.expect("write payload");
    });

    let proxy = start_proxy().await;
    let mut proxy_client = client(proxy.address).await;
    send_request(&mut proxy_client, &connect_request(upstream_address)).await;
    let response = read_response(&mut proxy_client).await;
    assert!(response.starts_with("HTTP/1.1 200 "), "{response}");

    let payload: Vec<_> = (0_u16..32_000).flat_map(u16::to_be_bytes).collect();
    let expected: Vec<_> = payload.iter().map(|byte| byte.wrapping_add(1)).collect();
    proxy_client
        .write_all(&payload)
        .await
        .expect("write opaque payload");

    let mut received = vec![0_u8; expected.len()];
    proxy_client
        .read_exact(&mut received)
        .await
        .expect("read transformed payload");
    assert_eq!(received, expected);

    upstream.await.expect("upstream task");
    drop(proxy_client);
    proxy.shutdown.send(()).expect("stop proxy");
    proxy.task.await.expect("proxy task").expect("proxy serve");
}

#[tokio::test]
async fn connect_accepts_ipv6_authority_form() {
    let upstream_listener = TcpListener::bind("[::1]:0")
        .await
        .expect("bind IPv6 upstream");
    let upstream_port = upstream_listener
        .local_addr()
        .expect("upstream address")
        .port();
    let upstream = tokio::spawn(async move {
        let (mut upstream, _) = upstream_listener.accept().await.expect("accept upstream");
        let mut payload = [0_u8; 4];
        upstream
            .read_exact(&mut payload)
            .await
            .expect("read IPv6 payload");
        upstream.write_all(b"ipv6").await.expect("write IPv6 reply");
    });

    let proxy = start_proxy().await;
    let mut socket = client(proxy.address).await;
    send_request(
        &mut socket,
        &format!("CONNECT [::1]:{upstream_port} HTTP/1.1\r\nHost: [::1]:{upstream_port}\r\n\r\n"),
    )
    .await;
    let response = read_response(&mut socket).await;
    assert!(response.starts_with("HTTP/1.1 200 "), "{response}");
    socket.write_all(b"ping").await.expect("write IPv6 ping");
    let mut reply = [0_u8; 4];
    socket
        .read_exact(&mut reply)
        .await
        .expect("read IPv6 reply");
    assert_eq!(&reply, b"ipv6");

    upstream.await.expect("upstream task");
    drop(socket);
    proxy.shutdown.send(()).expect("stop proxy");
    proxy.task.await.expect("proxy task").expect("proxy serve");
}

#[tokio::test]
async fn non_connect_and_malformed_targets_are_rejected_without_dialing() {
    let upstream_listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind observed upstream");
    let upstream_address = upstream_listener.local_addr().expect("upstream address");

    let proxy = start_proxy().await;
    let mut socket = client(proxy.address).await;
    send_request(
        &mut socket,
        &format!("GET http://{upstream_address}/ HTTP/1.1\r\nHost: {upstream_address}\r\n\r\n"),
    )
    .await;
    let response = read_response(&mut socket).await;
    assert!(response.starts_with("HTTP/1.1 405 "), "{response}");
    assert!(response.contains("allow: CONNECT"), "{response}");

    for target in [
        format!("http://{upstream_address}"),
        "example.test:0".to_owned(),
        "example.test:+443".to_owned(),
    ] {
        let mut socket = client(proxy.address).await;
        send_request(
            &mut socket,
            &format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n"),
        )
        .await;
        let response = read_response(&mut socket).await;
        assert!(
            response.starts_with("HTTP/1.1 400 "),
            "{target}: {response}"
        );
    }

    tokio::select! {
        () = tokio::time::sleep(std::time::Duration::from_millis(50)) => {}
        accepted = upstream_listener.accept() => panic!("rejected target dialed upstream: {accepted:?}"),
    }

    proxy.shutdown.send(()).expect("stop proxy");
    proxy.task.await.expect("proxy task").expect("proxy serve");
}
#[tokio::test]
async fn upstream_failure_returns_http_502_after_dial() {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind temporary upstream");
    let address = listener.local_addr().expect("upstream address");
    drop(listener);

    let proxy = start_proxy().await;
    let mut socket = client(proxy.address).await;
    send_request(&mut socket, &connect_request(address)).await;
    let response = read_response(&mut socket).await;
    assert!(response.starts_with("HTTP/1.1 502 "), "{response}");

    proxy.shutdown.send(()).expect("stop proxy");
    proxy.task.await.expect("proxy task").expect("proxy serve");
}

#[tokio::test]
async fn half_close_propagates_in_both_directions() {
    let upstream_listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind upstream");
    let upstream_address = upstream_listener.local_addr().expect("upstream address");
    let upstream = tokio::spawn(async move {
        let (mut upstream, _) = upstream_listener.accept().await.expect("accept upstream");
        let mut payload = [0_u8; 5];
        upstream.read_exact(&mut payload).await.expect("read final");
        assert_eq!(&payload, b"final");
        upstream.write_all(b"reply").await.expect("write reply");
        upstream.shutdown().await.expect("shutdown upstream");
    });

    let proxy = start_proxy().await;
    let mut socket = client(proxy.address).await;
    send_request(&mut socket, &connect_request(upstream_address)).await;
    let response = read_response(&mut socket).await;
    assert!(response.starts_with("HTTP/1.1 200 "), "{response}");

    socket
        .write_all(b"final")
        .await
        .expect("write final payload");
    socket.shutdown().await.expect("half-close client");
    let mut reply = [0_u8; 5];
    socket.read_exact(&mut reply).await.expect("read reply");
    assert_eq!(&reply, b"reply");
    let end = socket.read(&mut reply).await.expect("read proxy EOF");
    assert_eq!(end, 0);

    upstream.await.expect("upstream task");
    proxy.shutdown.send(()).expect("stop proxy");
    proxy.task.await.expect("proxy task").expect("proxy serve");
}

#[tokio::test]
async fn shutdown_drains_active_connection() {
    let upstream_listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind upstream");
    let upstream_address = upstream_listener.local_addr().expect("upstream address");
    let payload: Vec<_> = (0_u16..64_000).map(|byte| byte as u8 ^ 0x5a).collect();
    let expected = payload.clone();
    let payload_length = expected.len();
    let upstream = tokio::spawn(async move {
        let (mut upstream, _) = upstream_listener.accept().await.expect("accept upstream");
        let mut payload = vec![0_u8; payload_length];
        upstream
            .read_exact(&mut payload)
            .await
            .expect("read active payload");
        upstream
            .write_all(&payload)
            .await
            .expect("echo active payload");
    });

    let proxy = start_proxy().await;
    let mut socket = client(proxy.address).await;
    send_request(&mut socket, &connect_request(upstream_address)).await;
    let response = read_response(&mut socket).await;
    assert!(response.starts_with("HTTP/1.1 200 "), "{response}");

    proxy.shutdown.send(()).expect("start bounded drain");
    socket
        .write_all(&payload)
        .await
        .expect("write payload during drain");
    let mut received = vec![0_u8; expected.len()];
    socket
        .read_exact(&mut received)
        .await
        .expect("read echo during drain");
    assert_eq!(received, expected);

    upstream.await.expect("upstream task");
    proxy.task.await.expect("proxy task").expect("proxy serve");
}

#[tokio::test]
async fn shutdown_closes_idle_connection_after_grace() {
    let upstream_listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind upstream");
    let upstream_address = upstream_listener.local_addr().expect("upstream address");
    let _upstream = upstream_listener.accept();

    let proxy = start_proxy().await;
    let mut socket = client(proxy.address).await;
    send_request(&mut socket, &connect_request(upstream_address)).await;
    let response = read_response(&mut socket).await;
    assert!(response.starts_with("HTTP/1.1 200 "), "{response}");

    proxy.shutdown.send(()).expect("start idle shutdown");
    tokio::time::timeout(Duration::from_secs(4), proxy.task)
        .await
        .expect("idle shutdown is bounded")
        .expect("proxy task")
        .expect("proxy serve");

    let mut byte = [0_u8; 1];
    let end = socket.read(&mut byte).await.expect("read drained EOF");
    assert_eq!(end, 0);
    drop(_upstream);
}

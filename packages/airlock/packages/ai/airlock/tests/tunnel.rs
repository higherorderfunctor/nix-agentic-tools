mod common;

use std::time::Duration;

use common::{message, request, start, wait_for_listener_release};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    time::timeout,
};

#[tokio::test]
async fn connect_relays_streaming_bytes_and_data_after_headers_in_the_same_packet() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut early = [0; 5];
        socket.read_exact(&mut early).await.unwrap();
        assert_eq!(&early, b"early");
        socket.write_all(b"EARLY").await.unwrap();
        let mut remaining = 64_000;
        let mut buffer = [0; 4096];
        while remaining > 0 {
            let count = socket.read(&mut buffer).await.unwrap();
            assert!(count > 0, "complete streamed payload");
            remaining -= count;
            for byte in &mut buffer[..count] {
                *byte = byte.wrapping_add(1);
            }
            socket.write_all(&buffer[..count]).await.unwrap();
        }
    });
    let server = start().await;
    let mut socket = server.client().await;
    socket
        .write_all(format!("CONNECT {address} HTTP/1.1\r\nHost: {address}\r\n\r\nearly").as_bytes())
        .await
        .unwrap();
    assert!(message(&mut socket).await.starts_with("HTTP/1.1 200 "));
    let mut early = [0; 5];
    timeout(Duration::from_secs(2), socket.read_exact(&mut early))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&early, b"EARLY");
    let payload: Vec<_> = (0_u16..32_000).flat_map(u16::to_be_bytes).collect();
    let expected: Vec<_> = payload.iter().map(|byte| byte.wrapping_add(1)).collect();
    let mut reply = vec![0; payload.len()];
    let (mut reader, mut writer) = socket.split();
    timeout(Duration::from_secs(2), async {
        tokio::try_join!(writer.write_all(&payload), reader.read_exact(&mut reply))
    })
    .await
    .unwrap()
    .unwrap();
    assert_eq!(reply, expected);
    drop(socket);
    timeout(Duration::from_secs(2), upstream)
        .await
        .unwrap()
        .unwrap();
    server.stop().await;
}

#[tokio::test]
async fn connect_accepts_ipv6_and_dns_authorities() {
    let server = start().await;
    for listen in ["[::1]:0", "127.0.0.1:0"] {
        let listener = TcpListener::bind(listen).await.unwrap();
        let address = listener.local_addr().unwrap();
        let target = if address.is_ipv6() {
            address.to_string()
        } else {
            format!("localhost:{}", address.port())
        };
        let upstream = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            socket.write_all(b"connected").await.unwrap();
        });
        let mut socket = server.client().await;
        assert!(
            request(&mut socket, "CONNECT", &target)
                .await
                .starts_with("HTTP/1.1 200 ")
        );
        let mut reply = String::new();
        timeout(Duration::from_secs(2), socket.read_to_string(&mut reply))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(reply, "connected");
        upstream.await.unwrap();
    }
    server.stop().await;
}

#[tokio::test]
async fn malformed_targets_are_rejected_without_connecting() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = start().await;
    for (restriction, target) in [
        ("no scheme", format!("http://{address}")),
        ("no path", format!("{address}/path")),
        ("no user info", format!("user@{address}")),
        ("IPv6 must be bracketed", "::1:443".into()),
        ("brackets only for IPv6", "[127.0.0.1]:443".into()),
        ("explicit port required", "127.0.0.1".into()),
        ("port must be nonzero", "host:0".into()),
        ("no port sign", "host:+443".into()),
        ("port must fit in 16 bits", "host:65536".into()),
        (
            "label must start with a letter or digit",
            "-host:443".into(),
        ),
        ("no empty internal DNS label", "host..test:443".into()),
    ] {
        let mut socket = server.client().await;
        let reply = request(&mut socket, "CONNECT", &target).await;
        assert!(
            reply.starts_with("HTTP/1.1 400 "),
            "{restriction} ({target}): {reply}"
        );
    }
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err(),
        "malformed authority connected upstream"
    );
    // Prove the same endpoint accepts a valid authority and the listener can
    // observe the resulting connection rather than silently missing it.
    let mut client = server.client().await;
    request(&mut client, "CONNECT", &address.to_string()).await;
    let (upstream, _) = timeout(Duration::from_secs(1), listener.accept())
        .await
        .expect("valid authority connected upstream")
        .unwrap();
    drop((client, upstream));
    server.stop().await;
}

#[tokio::test]
async fn unavailable_target_returns_bad_gateway_and_keeps_http_usable() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let server = start().await;
    let mut socket = server.client().await;
    let reply = request(&mut socket, "CONNECT", &address.to_string()).await;
    assert!(reply.starts_with("HTTP/1.1 502 "), "{reply}");
    assert!(
        request(&mut socket, "GET", "/health")
            .await
            .starts_with("HTTP/1.1 200 ")
    );
    drop(socket);
    server.stop().await;
}

#[tokio::test]
async fn upstream_half_close_keeps_the_client_write_direction_open() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        socket.write_all(b"first").await.unwrap();
        socket.shutdown().await.unwrap();
        let mut final_payload = String::new();
        socket.read_to_string(&mut final_payload).await.unwrap();
        assert_eq!(final_payload, "late");
    });
    let server = start().await;
    let mut socket = server.client().await;
    assert!(
        request(&mut socket, "CONNECT", &address.to_string())
            .await
            .starts_with("HTTP/1.1 200 ")
    );
    let mut reply = String::new();
    timeout(Duration::from_secs(2), socket.read_to_string(&mut reply))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reply, "first");
    socket.write_all(b"late").await.unwrap();
    socket.shutdown().await.unwrap();
    timeout(Duration::from_secs(2), upstream)
        .await
        .unwrap()
        .unwrap();
    server.stop().await;
}

#[tokio::test]
async fn client_reset_ends_a_tunnel_blocked_on_a_slow_upstream() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    // The upstream never reads, so the relay blocks writing to it and stops
    // reading the client.
    let upstream = tokio::spawn(async move { listener.accept().await.unwrap().0 });
    let server = start().await;
    let mut socket = server.client().await;
    assert!(
        request(&mut socket, "CONNECT", &address.to_string())
            .await
            .starts_with("HTTP/1.1 200 ")
    );
    let chunk = vec![0; 64 * 1024];
    // Write until one write stalls; an I/O error means the tunnel closed early.
    loop {
        match timeout(Duration::from_millis(200), socket.write_all(&chunk)).await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => panic!("tunnel closed before a write stalled: {error}"),
            Err(_) => break,
        }
    }
    socket.set_zero_linger().unwrap();
    drop(socket);
    let _upstream = upstream.await.unwrap();
    // A tunnel still blocked on the upstream would hold shutdown for the full
    // three-second grace.
    server.shutdown.send(()).unwrap();
    timeout(Duration::from_secs(1), server.task)
        .await
        .expect("the reset tunnel has ended")
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn shutdown_drains_an_active_tunnel() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut final_payload = String::new();
        socket.read_to_string(&mut final_payload).await.unwrap();
        socket.write_all(final_payload.as_bytes()).await.unwrap();
    });
    let server = start().await;
    let mut socket = server.client().await;
    assert!(
        request(&mut socket, "CONNECT", &address.to_string())
            .await
            .starts_with("HTTP/1.1 200 ")
    );
    server.shutdown.send(()).unwrap();
    wait_for_listener_release(server.address).await;
    socket.write_all(b"during drain").await.unwrap();
    socket.shutdown().await.unwrap();
    let mut reply = String::new();
    timeout(Duration::from_secs(2), socket.read_to_string(&mut reply))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reply, "during drain");
    upstream.await.unwrap();
    timeout(Duration::from_secs(2), server.task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn shutdown_cancels_idle_tunnel_and_closes_both_sockets() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        assert_eq!(socket.read(&mut [0]).await.unwrap(), 0);
    });
    let server = start().await;
    let mut socket = server.client().await;
    assert!(
        request(&mut socket, "CONNECT", &address.to_string())
            .await
            .starts_with("HTTP/1.1 200 ")
    );
    server.stop().await;
    assert_eq!(
        timeout(Duration::from_secs(1), socket.read(&mut [0]))
            .await
            .unwrap()
            .unwrap(),
        0
    );
    timeout(Duration::from_secs(1), upstream)
        .await
        .unwrap()
        .unwrap();
}

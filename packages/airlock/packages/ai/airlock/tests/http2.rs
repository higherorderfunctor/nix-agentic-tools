mod common;

use std::{future::poll_fn, net::SocketAddr, time::Duration};

use common::{request, start, wait_for_listener_release};
use h2::{RecvStream, SendStream, client::SendRequest};
use hyper::{Request, StatusCode, Version, body::Bytes};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    task::JoinHandle,
    time::timeout,
};

struct Client {
    sender: SendRequest<Bytes>,
    driver: JoinHandle<Result<(), h2::Error>>,
}

impl Drop for Client {
    fn drop(&mut self) {
        self.driver.abort();
    }
}

impl Client {
    async fn connect(address: SocketAddr) -> Self {
        let socket = TcpStream::connect(address).await.unwrap();
        let (sender, connection) = h2::client::handshake(socket).await.unwrap();
        Self {
            sender,
            driver: tokio::spawn(connection),
        }
    }

    async fn open_tunnel(
        &self,
        target: SocketAddr,
    ) -> (h2::client::ResponseFuture, SendStream<Bytes>) {
        let mut sender = self.sender.clone().ready().await.unwrap();
        let request = Request::builder()
            .method("CONNECT")
            .uri(target.to_string())
            .version(Version::HTTP_2)
            .body(())
            .unwrap();
        sender.send_request(request, false).unwrap()
    }

    async fn tunnel(&self, target: SocketAddr) -> (SendStream<Bytes>, RecvStream) {
        let (response, send) = self.open_tunnel(target).await;
        let response = timeout(Duration::from_secs(2), response)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        (send, response.into_body())
    }
}

async fn send_all(send: &mut SendStream<Bytes>, mut bytes: Bytes) {
    while !bytes.is_empty() {
        send.reserve_capacity(bytes.len());
        let capacity = poll_fn(|cx| send.poll_capacity(cx)).await.unwrap().unwrap();
        let count = capacity.min(bytes.len());
        send.send_data(bytes.split_to(count), false).unwrap();
    }
    send.send_data(Bytes::new(), true).unwrap();
}

async fn read_all(recv: &mut RecvStream) -> Vec<u8> {
    let mut result = Vec::new();
    while let Some(data) = recv.data().await {
        let data = data.unwrap();
        recv.flow_control().release_capacity(data.len()).unwrap();
        result.extend_from_slice(&data);
    }
    result
}

#[tokio::test]
async fn http1_and_prior_knowledge_http2_share_one_listener() {
    let server = start().await;
    let mut http1 = server.client().await;
    assert!(
        request(&mut http1, "GET", "/health")
            .await
            .starts_with("HTTP/1.1 200 ")
    );
    drop(http1);
    let client = Client::connect(server.address).await;
    let mut sender = client.sender.clone().ready().await.unwrap();
    let request = Request::builder()
        .uri("http://localhost/health")
        .body(())
        .unwrap();
    let (response, _) = sender.send_request(request, true).unwrap();
    let response = timeout(Duration::from_secs(2), response)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(read_all(&mut response.into_body()).await, b"ok\n");
    drop(client);
    server.stop().await;
}

#[tokio::test]
async fn multiplexed_tunnels_stream_beyond_flow_control_windows() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let mut tasks = tokio::task::JoinSet::new();
        for _ in 0..2 {
            let (mut socket, _) = listener.accept().await.unwrap();
            tasks.spawn(async move {
                let mut bytes = [0; 4096];
                loop {
                    let count = socket.read(&mut bytes).await.unwrap();
                    if count == 0 {
                        break;
                    }
                    for byte in &mut bytes[..count] {
                        *byte = byte.wrapping_add(1);
                    }
                    socket.write_all(&bytes[..count]).await.unwrap();
                }
            });
        }
        while let Some(result) = tasks.join_next().await {
            result.unwrap();
        }
    });
    let server = start().await;
    let client = Client::connect(server.address).await;
    let (mut first_send, mut first_recv) = client.tunnel(target).await;
    let (mut second_send, mut second_recv) = client.tunnel(target).await;
    let first = Bytes::from((0..200_000).map(|n| n as u8).collect::<Vec<_>>());
    let second = Bytes::from((0..180_000).map(|n| (n as u8) ^ 0x5a).collect::<Vec<_>>());
    let first_expected: Vec<_> = first.iter().map(|byte| byte.wrapping_add(1)).collect();
    let second_expected: Vec<_> = second.iter().map(|byte| byte.wrapping_add(1)).collect();
    let ((), (), first_reply, second_reply) = timeout(Duration::from_secs(4), async {
        tokio::join!(
            send_all(&mut first_send, first),
            send_all(&mut second_send, second),
            read_all(&mut first_recv),
            read_all(&mut second_recv)
        )
    })
    .await
    .unwrap();
    assert_eq!(first_reply, first_expected);
    assert_eq!(second_reply, second_expected);
    upstream.await.unwrap();
    drop(client);
    server.stop().await;
}

#[tokio::test]
async fn upstream_half_close_preserves_writes_and_reset_isolates_other_streams() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut reset, _) = listener.accept().await.unwrap();
        let (mut survivor, _) = listener.accept().await.unwrap();
        survivor.write_all(b"first").await.unwrap();
        survivor.shutdown().await.unwrap();
        let mut final_bytes = Vec::new();
        survivor.read_to_end(&mut final_bytes).await.unwrap();
        assert_eq!(final_bytes, b"late");
        assert_eq!(reset.read(&mut [0]).await.unwrap(), 0);
    });
    let server = start().await;
    let client = Client::connect(server.address).await;
    let (mut reset_send, reset_recv) = client.tunnel(target).await;
    let (mut send, mut recv) = client.tunnel(target).await;
    reset_send.send_reset(h2::Reason::CANCEL);
    drop(reset_recv);
    assert_eq!(
        timeout(Duration::from_secs(2), read_all(&mut recv))
            .await
            .unwrap(),
        b"first"
    );
    send_all(&mut send, Bytes::from_static(b"late")).await;
    timeout(Duration::from_secs(2), upstream)
        .await
        .unwrap()
        .unwrap();
    drop(client);
    server.stop().await;
}

#[tokio::test]
async fn stream_capacity_recovers_after_reset_of_a_stalled_half_closed_upload() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let mut sockets = Vec::new();
        for _ in 0..33 {
            let (mut socket, _) = listener.accept().await.unwrap();
            socket.shutdown().await.unwrap();
            sockets.push(socket);
        }
        sockets
    });
    let server = start().await;
    let client = Client::connect(server.address).await;
    let mut streams = Vec::new();
    for _ in 0..32 {
        streams.push(client.tunnel(target).await);
    }
    let (mut queued, queued_send) = client.open_tunnel(target).await;
    assert!(
        timeout(Duration::from_millis(100), &mut queued)
            .await
            .is_err(),
        "33rd stream must wait for protocol capacity"
    );
    let (mut send, mut recv) = streams.pop().unwrap();
    let _ = timeout(Duration::from_secs(2), read_all(&mut recv))
        .await
        .expect("upstream half-close must reach the client before reset");
    // The upstream holds these sockets without reading. Fill the upload
    // until flow control stalls, so the relay cannot read the reset as EOF.
    let mut payload = Bytes::from(vec![0x5a; 8 * 1024 * 1024]);
    let mut stalled = false;
    while !payload.is_empty() {
        send.reserve_capacity(payload.len().min(65_536));
        let capacity = timeout(
            Duration::from_millis(100),
            poll_fn(|cx| send.poll_capacity(cx)),
        )
        .await;
        let capacity = match capacity {
            Ok(capacity) => capacity.unwrap().unwrap(),
            Err(_) => {
                stalled = true;
                break;
            }
        };
        let count = capacity.min(payload.len());
        send.send_data(payload.split_to(count), false).unwrap();
    }
    assert!(stalled, "upload must stall while upstream does not read");
    send.send_reset(h2::Reason::CANCEL);
    drop(recv);
    let response = timeout(Duration::from_secs(2), queued)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "capacity recovers after stream reset"
    );
    drop(response);
    drop(queued_send);
    drop(streams);
    drop(client);
    drop(upstream.await.unwrap());
    server.stop().await;
}

#[tokio::test]
async fn first_request_deadline_does_not_limit_an_established_tunnel() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut bytes = Vec::new();
        socket.read_to_end(&mut bytes).await.unwrap();
        socket.write_all(&bytes).await.unwrap();
    });
    let server = start().await;
    let client = Client::connect(server.address).await;
    let (mut send, mut recv) = client.tunnel(target).await;
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(11)).await;
    tokio::time::resume();
    send_all(&mut send, Bytes::from_static(b"after initial deadline")).await;
    assert_eq!(
        timeout(Duration::from_secs(2), read_all(&mut recv))
            .await
            .unwrap(),
        b"after initial deadline"
    );
    upstream.await.unwrap();
    drop(client);
    server.stop().await;
}

#[tokio::test]
async fn partial_preface_and_idle_http2_are_closed_before_the_first_request() {
    let server = start().await;
    let mut partial = server.client().await;
    partial.write_all(b"PRI * HTTP/2.0\r\n").await.unwrap();
    let mut idle = Client::connect(server.address).await;
    assert_eq!(
        timeout(Duration::from_secs(12), partial.read(&mut [0]))
            .await
            .unwrap()
            .unwrap(),
        0
    );
    timeout(Duration::from_secs(1), &mut idle.driver)
        .await
        .expect("idle h2 first request deadline")
        .unwrap()
        .ok();
    drop(idle);
    assert_other_clients_are_healthy(server).await;
}

enum TunnelEnd {
    ClientDisconnect,
    ServerShutdown,
}

async fn assert_tunnel_sockets_close(end: TunnelEnd) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        assert_eq!(socket.read(&mut [0]).await.unwrap(), 0, "upstream EOF");
    });
    let server = start().await;
    let client = Client::connect(server.address).await;
    let (_send, mut recv) = client.tunnel(target).await;
    let survivor = match end {
        TunnelEnd::ClientDisconnect => {
            drop(client);
            Some(server)
        }
        TunnelEnd::ServerShutdown => {
            server.stop().await;
            let ended = timeout(Duration::from_secs(1), recv.data())
                .await
                .expect("client stream closed");
            assert!(
                ended.is_none() || ended.unwrap().is_err(),
                "closed stream returned data"
            );
            None
        }
    };
    timeout(Duration::from_secs(1), upstream)
        .await
        .expect("upstream socket closed")
        .unwrap();
    if let Some(server) = survivor {
        assert_other_clients_are_healthy(server).await;
    }
}

async fn assert_other_clients_are_healthy(server: common::Server) {
    let mut healthy = server.client().await;
    assert!(
        request(&mut healthy, "GET", "/health")
            .await
            .starts_with("HTTP/1.1 200 ")
    );
    drop(healthy);
    server.stop().await;
}

#[tokio::test]
async fn shutdown_cancels_owned_http2_tunnels_and_both_sockets() {
    // Dropping the server's connection task must not orphan its live streams.
    assert_tunnel_sockets_close(TunnelEnd::ServerShutdown).await;
}

#[tokio::test]
async fn closing_http2_connection_cancels_its_live_tunnels() {
    // Dropping the client transport must close upstream without stopping the server.
    assert_tunnel_sockets_close(TunnelEnd::ClientDisconnect).await;
}

#[tokio::test]
async fn shutdown_keeps_http2_driver_polling_during_active_drain() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut bytes = Vec::new();
        socket.read_to_end(&mut bytes).await.unwrap();
        socket.write_all(&bytes).await.unwrap();
    });
    let server = start().await;
    let client = Client::connect(server.address).await;
    let (mut send, mut recv) = client.tunnel(target).await;
    server.shutdown.send(()).unwrap();
    wait_for_listener_release(server.address).await;
    send_all(&mut send, Bytes::from_static(b"during drain")).await;
    assert_eq!(
        timeout(Duration::from_secs(2), read_all(&mut recv))
            .await
            .unwrap(),
        b"during drain"
    );
    upstream.await.unwrap();
    drop(client);
    timeout(Duration::from_secs(2), server.task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
}

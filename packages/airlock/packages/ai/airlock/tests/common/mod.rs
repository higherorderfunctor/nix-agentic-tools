// Each test binary compiles this module but uses only the helpers it needs.
#![allow(dead_code)]

pub mod h2_client;
pub mod process;
pub mod tls;

use std::{io, net::SocketAddr, time::Duration};

use airlock::{
    config::{Config, Interception},
    proxy::Proxy,
    server,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::oneshot,
    task::JoinHandle,
    time::timeout,
};

pub struct Server {
    pub address: SocketAddr,
    pub shutdown: oneshot::Sender<()>,
    pub task: JoinHandle<io::Result<()>>,
}

pub async fn start() -> Server {
    start_with(None).await
}

/// Serve on a free loopback port with the given settings.
pub async fn start_with(interception: Option<Interception>) -> Server {
    let listener = server::bind("127.0.0.1:0".parse().unwrap()).await.unwrap();
    let address = listener.local_addr().unwrap();
    let config = Config {
        listen: address,
        interception,
    };
    let proxy = Proxy::load(&config).unwrap();
    let (shutdown, stopped) = oneshot::channel();
    let task = tokio::spawn(server::serve(listener, proxy, async {
        let _ = stopped.await;
    }));
    Server {
        address,
        shutdown,
        task,
    }
}

impl Server {
    pub async fn client(&self) -> TcpStream {
        TcpStream::connect(self.address).await.unwrap()
    }

    pub async fn stop(self) {
        self.shutdown.send(()).unwrap();
        timeout(Duration::from_secs(4), self.task)
            .await
            .expect("bounded shutdown")
            .unwrap()
            .unwrap();
    }
}

/// Read an HTTP/1 head through its blank line.
pub async fn headers(socket: &mut (impl AsyncRead + Unpin)) -> String {
    timeout(Duration::from_secs(2), async {
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            bytes.push(socket.read_u8().await.expect("response header"));
        }
        String::from_utf8(bytes).unwrap()
    })
    .await
    .expect("header deadline")
}

/// Read an HTTP/1 request or response head and its `content-length` body.
pub async fn message(socket: &mut TcpStream) -> String {
    let mut response = headers(socket).await;
    let length: usize = response
        .lines()
        .find_map(|line| line.strip_prefix("content-length: "))
        .map(|length| length.parse().unwrap())
        .unwrap_or(0);
    let mut body = vec![0; length];
    timeout(Duration::from_secs(2), socket.read_exact(&mut body))
        .await
        .expect("body deadline")
        .unwrap();
    response.push_str(&String::from_utf8(body).unwrap());
    response
}

pub async fn request(socket: &mut TcpStream, method: &str, target: &str) -> String {
    socket
        .write_all(format!("{method} {target} HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes())
        .await
        .unwrap();
    message(socket).await
}

pub mod process;

use std::{fs, io, net::SocketAddr, os::unix::fs::PermissionsExt, time::Duration};

use airlock::server;
use tempfile::TempDir;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::oneshot,
    task::JoinHandle,
    time::timeout,
};

#[allow(dead_code)]
pub struct Server {
    pub address: SocketAddr,
    pub shutdown: oneshot::Sender<()>,
    pub task: JoinHandle<io::Result<()>>,
}

#[allow(dead_code)]
pub async fn start() -> Server {
    let listener = server::bind("127.0.0.1:0".parse().unwrap()).await.unwrap();
    let address = listener.local_addr().unwrap();
    let (shutdown, stopped) = oneshot::channel();
    let task = tokio::spawn(server::serve(listener, async {
        let _ = stopped.await;
    }));
    Server {
        address,
        shutdown,
        task,
    }
}

impl Server {
    #[allow(dead_code)]
    pub async fn client(&self) -> TcpStream {
        TcpStream::connect(self.address).await.unwrap()
    }

    #[allow(dead_code)]
    pub async fn stop(self) {
        self.shutdown.send(()).unwrap();
        timeout(Duration::from_secs(4), self.task)
            .await
            .expect("bounded shutdown")
            .unwrap()
            .unwrap();
    }
}

#[allow(dead_code)]
pub async fn message(socket: &mut TcpStream) -> String {
    timeout(Duration::from_secs(2), async {
        let mut response = Vec::new();
        while !response.ends_with(b"\r\n\r\n") {
            response.push(socket.read_u8().await.expect("response header"));
        }
        let headers = String::from_utf8(response.clone()).unwrap();
        let length: usize = headers
            .lines()
            .find_map(|line| line.strip_prefix("content-length: "))
            .map(|length| length.parse().unwrap())
            .unwrap_or(0);
        let header_length = response.len();
        response.resize(header_length + length, 0);
        socket
            .read_exact(&mut response[header_length..])
            .await
            .unwrap();
        String::from_utf8(response).unwrap()
    })
    .await
    .expect("response deadline")
}

#[allow(dead_code)]
pub async fn request(socket: &mut TcpStream, method: &str, target: &str) -> String {
    socket
        .write_all(format!("{method} {target} HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes())
        .await
        .unwrap();
    message(socket).await
}

/// A temporary directory only its owner can use, like the service runtime
/// directory that holds a CA; the default honors the umask.
#[allow(dead_code)]
pub fn private_root() -> TempDir {
    tempfile::Builder::new()
        .permissions(fs::Permissions::from_mode(0o700))
        .tempdir()
        .expect("create private temporary root")
}

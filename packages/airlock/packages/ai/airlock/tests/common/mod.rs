use std::{io, net::SocketAddr, time::Duration};

use airlock::server;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::oneshot,
    task::JoinHandle,
    time::{sleep, timeout},
};

pub struct Server {
    pub address: SocketAddr,
    pub shutdown: oneshot::Sender<()>,
    pub task: JoinHandle<io::Result<()>>,
}

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

/// On shutdown, the server must release the listener before draining accepted
/// connections: new connections stop arriving while existing ones get the grace
/// period to finish. Rebinding proves shutdown was observed before the test
/// resumes traffic on an accepted connection.
pub async fn wait_for_listener_release(address: SocketAddr) {
    timeout(Duration::from_secs(1), async {
        loop {
            match server::bind(address).await {
                Ok(_) => break,
                Err(error) if error.kind() == io::ErrorKind::AddrInUse => {
                    sleep(Duration::from_millis(10)).await;
                }
                Err(error) => panic!("could not rebind {address}: {error}"),
            }
        }
    })
    .await
    .expect("listener must be released before active connections finish draining");
}

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

pub async fn request(socket: &mut TcpStream, method: &str, target: &str) -> String {
    socket
        .write_all(format!("{method} {target} HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes())
        .await
        .unwrap();
    message(socket).await
}

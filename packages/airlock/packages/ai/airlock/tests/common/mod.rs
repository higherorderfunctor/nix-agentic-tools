// cspell:ignore Zml4dHVyZTp0b2tlbg
// Each test binary compiles this module but uses only the helpers it needs.
#![allow(dead_code)]

pub mod h2_client;
pub mod process;
pub mod tls;

use std::{
    collections::BTreeMap, fs, io, net::SocketAddr, os::unix::fs::PermissionsExt, path::Path,
    time::Duration,
};

use airlock::{
    config::{Client, Config, Interception},
    server,
    startup::State,
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

// The `Proxy-Authorization` value for `fixture_clients`: base64 of
// `fixture:token`.
pub const FIXTURE_AUTHORIZATION: &str = "Basic Zml4dHVyZTp0b2tlbg==";

pub async fn start() -> Server {
    start_with(None, None).await
}

/// Serve on a free loopback port with the given settings.
pub async fn start_with(
    interception: Option<Interception>,
    clients: Option<BTreeMap<String, Client>>,
) -> Server {
    let listener = server::bind("127.0.0.1:0".parse().unwrap()).await.unwrap();
    let address = listener.local_addr().unwrap();
    let config = Config {
        listen: address,
        clients,
        interception,
    };
    let state = State::load(&config).unwrap();
    let (shutdown, stopped) = oneshot::channel();
    let task = tokio::spawn(server::serve(listener, state, async {
        let _ = stopped.await;
    }));
    Server {
        address,
        shutdown,
        task,
    }
}

/// One client, `fixture`, whose private token file in `directory` holds
/// `token`; it authenticates with `FIXTURE_AUTHORIZATION`.
pub fn fixture_clients(directory: &Path) -> BTreeMap<String, Client> {
    let token_file = directory.join("token");
    fs::write(&token_file, b"token\n").unwrap();
    fs::set_permissions(&token_file, fs::Permissions::from_mode(0o600)).unwrap();
    BTreeMap::from([("fixture".into(), Client { token_file })])
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

/// Send an authenticated CONNECT and read Airlock's reply.
pub async fn connect(socket: &mut TcpStream, target: &str, authorization: &str) -> String {
    socket
        .write_all(
            format!(
                "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nProxy-Authorization: {authorization}\r\n\r\n"
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    message(socket).await
}

pub async fn request(socket: &mut TcpStream, method: &str, target: &str) -> String {
    socket
        .write_all(format!("{method} {target} HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes())
        .await
        .unwrap();
    message(socket).await
}

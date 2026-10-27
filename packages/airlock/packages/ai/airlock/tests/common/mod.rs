// cspell:words geteuid rustix
pub mod h2_client;
pub mod process;
pub mod tls;

use std::{
    env, fs, io,
    net::SocketAddr,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

use airlock::{
    config::{Config, Interception},
    server,
    startup::State,
};
use tempfile::TempDir;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
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
    start_with(None).await
}

/// Serve on a free loopback port with the given settings.
#[allow(dead_code)]
pub async fn start_with(interception: Option<Interception>) -> Server {
    let listener = server::bind("127.0.0.1:0".parse().unwrap()).await.unwrap();
    let address = listener.local_addr().unwrap();
    let config = Config {
        listen: address,
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

/// Read an HTTP/1 head through its blank line.
#[allow(dead_code)]
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
#[allow(dead_code)]
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
    private_root_in(&env::temp_dir())
}

fn private_root_in(base: &Path) -> TempDir {
    tempfile::Builder::new()
        .permissions(fs::Permissions::from_mode(0o700))
        .tempdir_in(base)
        .expect("create private temporary root")
}

/// A private root for `AIRLOCK_HOME` fixtures under the test's own
/// `XDG_RUNTIME_DIR` when no other user can replace a directory above it, so
/// init can succeed there; a shared `/tmp` makes init refuse every path in it.
#[allow(dead_code)]
pub fn trusted_root() -> TempDir {
    let runtime = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|runtime| runtime.is_absolute() && replaceable_ancestor(runtime).is_none());
    private_root_in(&runtime.unwrap_or_else(env::temp_dir))
}

/// The nearest directory on `path`'s canonical form, or above it, that is
/// owned by neither this user nor root or is writable by group or others:
/// the directory `AIRLOCK_HOME` init must refuse a path through.
#[allow(dead_code)]
pub fn replaceable_ancestor(path: &Path) -> Option<PathBuf> {
    let user = rustix::process::geteuid().as_raw();
    let canonical = fs::canonicalize(path).expect("canonical path");
    canonical
        .ancestors()
        .find(|directory| {
            let metadata = fs::symlink_metadata(directory).expect("ancestor metadata");
            (metadata.uid() != user && metadata.uid() != 0) || metadata.mode() & 0o022 != 0
        })
        .map(Path::to_owned)
}

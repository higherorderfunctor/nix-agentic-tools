//! Run the airlock binary as a child process: start it, read the address it
//! reports, ask it for `/health`, and stop it with a signal.
use std::{
    env,
    ffi::OsStr,
    fs,
    io::{BufRead, BufReader, Read, Write},
    net::{SocketAddr, TcpStream},
    path::PathBuf,
    process::{self, Child, Command, ExitStatus, Stdio},
    sync::{
        atomic::{AtomicU32, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

pub const STARTUP_TIMEOUT: Duration = Duration::from_secs(5);
// Bounds connecting for the health request and each read of its reply.
const SOCKET_TIMEOUT: Duration = Duration::from_secs(2);
// The server drains for 3 seconds before it exits.
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(4);

pub fn command() -> Command {
    Command::new(env!("CARGO_BIN_EXE_airlock"))
}

/// A running airlock. Dropping it kills and reaps the child, so a failed
/// assertion never leaves a process behind.
pub struct Airlock {
    child: Child,
    startup: mpsc::Receiver<String>,
}

impl Airlock {
    pub fn spawn(arguments: &[&OsStr]) -> Self {
        let mut child = command()
            .args(arguments)
            .stdout(Stdio::piped())
            .spawn()
            .expect("spawn Airlock");
        let stdout = child.stdout.take().expect("capture Airlock stdout");
        let (sender, startup) = mpsc::channel();
        thread::spawn(move || {
            let mut line = String::new();
            let _ = BufReader::new(stdout).read_line(&mut line);
            let _ = sender.send(line);
        });
        Self { child, startup }
    }

    /// The loopback address from the readiness line.
    pub fn listen_address(&self) -> SocketAddr {
        let line = self
            .startup
            .recv_timeout(STARTUP_TIMEOUT)
            .expect("Airlock did not report its listen address");
        let address = line
            .trim()
            .strip_prefix("airlock listening on ")
            .and_then(|address| address.parse::<SocketAddr>().ok())
            .unwrap_or_else(|| panic!("unexpected Airlock startup output: {line:?}"));
        assert!(
            address.ip().is_loopback(),
            "non-loopback address: {address}"
        );
        address
    }

    /// Send `signal` and wait for the exit status, killing the child if it
    /// outlives the shutdown bound.
    pub fn stop(mut self, signal: libc::c_int) -> ExitStatus {
        // SAFETY: the child has not been reaped, and this sends a standard
        // signal to its process ID without dereferencing pointers.
        assert_eq!(
            unsafe { libc::kill(self.child.id() as libc::pid_t, signal) },
            0
        );
        let deadline = Instant::now() + SHUTDOWN_TIMEOUT;
        loop {
            if let Some(status) = self.child.try_wait().expect("check Airlock status") {
                return status;
            }
            if Instant::now() >= deadline {
                self.child.kill().expect("kill Airlock after timeout");
                return self.child.wait().expect("wait for killed Airlock");
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Airlock {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Request `/health` on a fresh connection and return the whole reply.
pub fn health(address: SocketAddr) -> String {
    let mut socket = TcpStream::connect_timeout(&address, SOCKET_TIMEOUT).unwrap();
    socket.set_read_timeout(Some(SOCKET_TIMEOUT)).unwrap();
    socket
        .write_all(b"GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        .unwrap();
    let mut response = String::new();
    socket.read_to_string(&mut response).unwrap();
    response
}

/// A config file removed when dropped.
pub struct TemporaryConfig {
    pub path: PathBuf,
}

impl TemporaryConfig {
    pub fn new(content: &str) -> Self {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let path = env::temp_dir().join(format!(
            "airlock-config-{}-{}.json",
            process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
        ));
        fs::write(&path, content).expect("write temporary Airlock config");
        Self { path }
    }
}

impl Drop for TemporaryConfig {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

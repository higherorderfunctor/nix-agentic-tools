use std::{
    io::{BufRead, BufReader, Read, Write},
    net::{SocketAddr, TcpStream},
    process::{Child, Command, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};

fn command() -> Command {
    Command::new(env!("CARGO_BIN_EXE_airlock"))
}

// Reap the child even if an assertion fails.
struct Process(Child);

impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn generated_help_and_version_describe_each_command() {
    for (arguments, expected) in [
        (vec!["--help"], vec!["Usage:", "--version", "serve"]),
        (vec!["--version"], vec![env!("CARGO_PKG_VERSION")]),
        (
            vec!["serve", "--help"],
            vec!["--listen", "127.0.0.1:8318", "--config"],
        ),
        (vec!["help", "serve"], vec!["--listen", "--config"]),
    ] {
        let output = command().args(&arguments).output().unwrap();
        assert!(output.status.success(), "{arguments:?}: {output:?}");
        assert!(output.stderr.is_empty(), "{arguments:?}: {output:?}");
        let stdout = String::from_utf8(output.stdout).unwrap();
        for text in expected {
            assert!(stdout.contains(text), "{arguments:?}: {stdout}");
        }
    }
}

#[test]
fn cli_rejects_invalid_commands_and_listen_addresses() {
    for arguments in [
        vec![],
        vec!["unknown"],
        vec!["serve", "--unknown"],
        vec!["serve", "--listen"],
        vec!["serve", "--listen", "localhost:8318"],
        vec!["serve", "--listen", "127.0.0.1:0", "extra"],
        vec!["serve", "--listen", "0.0.0.0:0"],
    ] {
        let output = command().args(&arguments).output().unwrap();
        assert!(!output.status.success(), "{arguments:?}");
        assert!(!output.stderr.is_empty(), "{arguments:?}");
    }
}

#[test]
fn serve_reports_readiness_and_both_signals_release_the_port() {
    for signal in [libc::SIGINT, libc::SIGTERM] {
        let child = command()
            .args(["serve", "--listen", "127.0.0.1:0"])
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut child = Process(child);
        let stdout = child.0.stdout.take().unwrap();
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let mut line = String::new();
            BufReader::new(stdout).read_line(&mut line).unwrap();
            let _ = sender.send(line);
        });
        let line = receiver
            .recv_timeout(Duration::from_secs(3))
            .expect("readiness output");
        let address: SocketAddr = line
            .trim()
            .strip_prefix("airlock listening on ")
            .expect("reported bound address")
            .parse()
            .unwrap();
        let mut socket = TcpStream::connect(address).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        socket
            .write_all(b"GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            .unwrap();
        let mut response = String::new();
        socket.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 200 "), "{response}");
        // SAFETY: the child is alive, and this sends a standard termination
        // signal to that child's process ID, without dereferencing pointers.
        assert_eq!(
            unsafe { libc::kill(child.0.id() as libc::pid_t, signal) },
            0
        );
        let deadline = Instant::now() + Duration::from_secs(4);
        loop {
            if let Some(status) = child.0.try_wait().unwrap() {
                assert!(status.success(), "{status}");
                break;
            }
            assert!(Instant::now() < deadline, "signal shutdown is bounded");
            std::thread::sleep(Duration::from_millis(10));
        }
        std::net::TcpListener::bind(address).expect("port released after signal");
    }
}

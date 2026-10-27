use std::{
    env, fs,
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

const IOTA_TIMEOUT: Duration = Duration::from_secs(2);
const STARTUP_TIMEOUT: Duration = Duration::from_secs(5);

struct TemporaryConfig {
    path: PathBuf,
}

impl TemporaryConfig {
    fn new(content: &str) -> Self {
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

struct AirlockProcess {
    child: Child,
    startup: mpsc::Receiver<String>,
}

impl AirlockProcess {
    fn spawn(arguments: &[&std::ffi::OsStr]) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_airlock"))
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

    fn listen_address(&self) -> SocketAddr {
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

    fn stop(mut self) -> ExitStatus {
        let signal = Command::new("kill")
            .arg(self.child.id().to_string())
            .status()
            .expect("send Airlock SIGTERM");
        assert!(signal.success(), "could not signal Airlock");

        let deadline = Instant::now() + STARTUP_TIMEOUT;
        loop {
            if let Some(status) = self.child.try_wait().expect("check Airlock status") {
                return status;
            }
            if Instant::now() >= deadline {
                self.child.kill().expect("kill Airlock after timeout");
                return self.child.wait().expect("wait for killed Airlock");
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for AirlockProcess {
    fn drop(&mut self) {
        if self
            .child
            .try_wait()
            .map(|status| status.is_none())
            .unwrap_or(false)
        {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
    }
}

fn assert_config_failure(content: &str, expected_error: &str) {
    let config = TemporaryConfig::new(content);
    assert_failure(
        &[
            "serve".as_ref(),
            "--config".as_ref(),
            config.path.as_os_str(),
        ],
        expected_error,
    );
}

fn assert_failure(arguments: &[&std::ffi::OsStr], expected_error: &str) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_airlock"))
        .args(arguments)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run Airlock");
    let deadline = Instant::now() + STARTUP_TIMEOUT;
    loop {
        if let Some(status) = child.try_wait().expect("check failing Airlock") {
            assert!(!status.success(), "Airlock unexpectedly succeeded");
            break;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("failing Airlock did not exit; pid {}", child.id());
        }
        thread::sleep(Duration::from_millis(20));
    }
    let output = child
        .wait_with_output()
        .expect("collect failing Airlock output");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains(expected_error),
        "expected {expected_error:?}; got: {stderr}"
    );
}

fn connect_with_retry(address: SocketAddr) -> TcpStream {
    let deadline = Instant::now() + STARTUP_TIMEOUT;
    loop {
        if let Ok(stream) = TcpStream::connect_timeout(&address, IOTA_TIMEOUT) {
            return stream;
        }
        assert!(
            Instant::now() < deadline,
            "Airlock did not accept a connection on {address}"
        );
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn serve_config_sets_the_real_binary_listen_address() {
    let config = TemporaryConfig::new(r#"{"listen":"127.0.0.1:0"}"#);
    let airlock = AirlockProcess::spawn(&[
        "serve".as_ref(),
        "--config".as_ref(),
        config.path.as_os_str(),
    ]);
    let address = airlock.listen_address();
    assert_ne!(address.port(), 0);
    let mut client = connect_with_retry(address);
    client.set_read_timeout(Some(IOTA_TIMEOUT)).unwrap();
    client
        .write_all(b"GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        .unwrap();
    let mut response = String::new();
    client.read_to_string(&mut response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200 "), "{response}");
    assert!(response.ends_with("ok\n"), "{response}");
    drop(client);
    assert!(airlock.stop().success());
}

#[test]
fn serve_config_requires_a_strict_valid_loopback_listen_object() {
    assert_failure(&["serve".as_ref(), "--config".as_ref()], "--config <FILE>");
    let missing = TemporaryConfig::new("{}");
    fs::remove_file(&missing.path).unwrap();
    assert_failure(
        &[
            "serve".as_ref(),
            "--config".as_ref(),
            missing.path.as_os_str(),
        ],
        "could not read config",
    );
    assert_config_failure(
        r#"{"listen":"127.0.0.1:0"} trailing"#,
        "trailing characters",
    );
    assert_config_failure("{}", "missing field `listen`");
    assert_config_failure(r#"["127.0.0.1:0"]"#, "the root must be a JSON object");
    assert_config_failure(
        r#"{"listen":"127.0.0.1:not-a-port"}"#,
        "invalid socket address",
    );
    assert_config_failure(
        r#"{"listen":"0.0.0.0:8400"}"#,
        "listen address must be loopback",
    );
    assert_config_failure(
        r#"{"hostname":"127.0.0.1","listen":"127.0.0.1:0"}"#,
        "unknown field `hostname`",
    );
    assert_config_failure(
        r#"{"listen":"127.0.0.1:0","listen":"127.0.0.1:0"}"#,
        "duplicate field `listen`",
    );
}

#[test]
fn serve_config_rejects_conflicting_and_trailing_arguments() {
    let config = TemporaryConfig::new(r#"{"listen":"127.0.0.1:0"}"#);
    assert_failure(
        &[
            "serve".as_ref(),
            "--config".as_ref(),
            config.path.as_os_str(),
            "--listen".as_ref(),
            "127.0.0.1:0".as_ref(),
        ],
        "cannot be used with",
    );
    assert_failure(
        &[
            "serve".as_ref(),
            "--config".as_ref(),
            config.path.as_os_str(),
            "unexpected".as_ref(),
        ],
        "unexpected argument",
    );
    assert_failure(
        &[
            "serve".as_ref(),
            "--listen".as_ref(),
            "127.0.0.1:0".as_ref(),
            "unexpected".as_ref(),
        ],
        "unexpected argument",
    );
}

#[test]
fn interception_config_rejects_invalid_destinations_and_initializes_ca_before_bind() {
    let root = tempfile::TempDir::new().unwrap();
    let ca_directory = root.path().join("ca");
    for destinations in [
        vec![],
        vec!["127.0.0.1:443"],
        vec!["*.example.test:443"],
        vec!["localhost"],
        vec!["localhost:0"],
        vec!["localhost:443", "LOCALHOST:443"],
    ] {
        let content = serde_json::json!({
            "listen": "127.0.0.1:0",
            "interception": { "ca_directory": ca_directory, "destinations": destinations }
        })
        .to_string();
        assert_config_failure(&content, "interception");
        assert!(
            !ca_directory.exists(),
            "invalid selection created CA material"
        );
    }
    let content = serde_json::json!({
        "listen": "127.0.0.1:0",
        "interception": { "ca_directory": ca_directory, "destinations": ["localhost:443"], "insecure": true }
    }).to_string();
    assert_config_failure(&content, "unknown field `insecure`");
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let certificate = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()]).unwrap();
    let upstream_roots = root.path().join("roots.pem");
    fs::write(&upstream_roots, certificate.cert.pem()).unwrap();
    let content = serde_json::json!({
        "listen": listener.local_addr().unwrap().to_string(),
        "interception": { "ca_directory": ca_directory, "destinations": ["localhost:443"], "upstream_roots": upstream_roots }
    })
    .to_string();
    assert_config_failure(&content, "Address already in use");
    assert!(
        ca_directory.join("ca.pem").exists(),
        "CA must be created before bind is attempted"
    );
    assert!(ca_directory.join("ca.key").exists());
}

#[test]
fn clients_config_is_strict_and_empty_enforcement_fails_startup() {
    for (clients, error) in [
        (r#"{}"#, "clients must not be empty"),
        (r#"[]"#, "invalid type"),
        (r#"{"fixture":{}}"#, "missing field `token_file`"),
        (
            r#"{"fixture":{"token_file":"/unused","token":"unused"}}"#,
            "unknown field `token`",
        ),
        (
            r#"{"fixture":{"token_file":"/unused","token_file":"/unused"}}"#,
            "duplicate field `token_file`",
        ),
    ] {
        assert_config_failure(
            &format!("{{\"listen\":\"127.0.0.1:0\",\"clients\":{clients}}}"),
            error,
        );
    }
}

#[test]
fn ca_directory_override_finalizes_config_before_startup() {
    let root = tempfile::TempDir::new().unwrap();
    let directory = root.path().join("runtime-ca");
    let configured_directory = root.path().join("unused-ca");
    let certificate = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()]).unwrap();
    let upstream_roots = root.path().join("roots.pem");
    fs::write(&upstream_roots, certificate.cert.pem()).unwrap();
    for ca_directory in [None, Some(&configured_directory)] {
        let mut content = serde_json::json!({
            "listen": "127.0.0.1:0",
            "interception": {"destinations": ["localhost:443"], "upstream_roots": upstream_roots}
        });
        if let Some(path) = ca_directory {
            content["interception"]["ca_directory"] = serde_json::json!(path);
        } else {
            assert_config_failure(&content.to_string(), "interception requires ca_directory");
        }
        let config = TemporaryConfig::new(&content.to_string());
        let airlock = AirlockProcess::spawn(&[
            "serve".as_ref(),
            "--ca-directory".as_ref(),
            directory.as_os_str(),
            "--config".as_ref(),
            config.path.as_os_str(),
        ]);
        airlock.listen_address();
        assert!(directory.join("ca.pem").exists());
        assert!(directory.join("ca.key").exists());
        assert!(!configured_directory.exists());
        assert!(airlock.stop().success());
    }
}

#[test]
fn ca_directory_override_refuses_missing_duplicate_and_unused_flags() {
    let config = TemporaryConfig::new(r#"{"listen":"127.0.0.1:0"}"#);
    for arguments in [
        vec![
            "serve".as_ref(),
            "--ca-directory".as_ref(),
            "/unused".as_ref(),
        ],
        vec![
            "serve".as_ref(),
            "--listen".as_ref(),
            "127.0.0.1:0".as_ref(),
            "--ca-directory".as_ref(),
            "/unused".as_ref(),
        ],
    ] {
        assert_failure(&arguments, "--ca-directory");
    }
    assert_failure(
        &[
            "serve".as_ref(),
            "--config".as_ref(),
            config.path.as_os_str(),
            "--ca-directory".as_ref(),
            "/unused".as_ref(),
        ],
        "--ca-directory requires interception configuration",
    );
    assert_failure(
        &["serve".as_ref(), "--ca-directory".as_ref()],
        "--ca-directory <DIRECTORY>",
    );
    assert_failure(
        &[
            "serve".as_ref(),
            "--config".as_ref(),
            config.path.as_os_str(),
            "--ca-directory".as_ref(),
            "/unused".as_ref(),
            "--ca-directory".as_ref(),
            "/other".as_ref(),
        ],
        "cannot be used multiple times",
    );
    for flag in ["--config", "--listen"] {
        assert_failure(
            &[
                "serve".as_ref(),
                flag.as_ref(),
                if flag == "--config" {
                    config.path.as_os_str()
                } else {
                    "127.0.0.1:0".as_ref()
                },
                flag.as_ref(),
                "/unused".as_ref(),
            ],
            "cannot be used multiple times",
        );
    }
}

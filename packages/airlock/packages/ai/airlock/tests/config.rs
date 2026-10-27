mod common;

use std::{
    ffi::OsStr,
    fs,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use common::process::{Airlock, STARTUP_TIMEOUT, TemporaryConfig, command, health, in_runtime};

fn assert_config_failure(content: &str, expected_error: &str) {
    assert_config_failure_in(command(), &[], content, expected_error);
}

/// `serve --config` with `content` and then `arguments`, run as `command`.
fn assert_config_failure_in(
    command: Command,
    arguments: &[&str],
    content: &str,
    expected_error: &str,
) {
    let config = TemporaryConfig::new(content);
    let mut serve: Vec<&OsStr> = vec![
        "serve".as_ref(),
        "--config".as_ref(),
        config.path.as_os_str(),
    ];
    serve.extend(arguments.iter().map(OsStr::new));
    assert_command_failure(command, &serve, expected_error);
}

fn assert_failure(arguments: &[&OsStr], expected_error: &str) {
    assert_command_failure(command(), arguments, expected_error);
}

fn assert_command_failure(mut command: Command, arguments: &[&OsStr], expected_error: &str) {
    let mut child = command
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

#[test]
fn serve_config_sets_the_real_binary_listen_address() {
    let config = TemporaryConfig::new(r#"{"listen":"127.0.0.1:0"}"#);
    let airlock = Airlock::spawn(&[
        "serve".as_ref(),
        "--config".as_ref(),
        config.path.as_os_str(),
    ]);
    let address = airlock.listen_address();
    assert_ne!(address.port(), 0);
    let response = health(address);
    assert!(response.starts_with("HTTP/1.1 200 "), "{response}");
    assert!(response.ends_with("ok\n"), "{response}");
    assert!(airlock.stop(libc::SIGTERM).success());
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
        "unknown field `hostname`, expected `listen`",
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

// Plain serving loads no CA, so a named instance would be silently ignored.
#[test]
fn serve_refuses_an_instance_without_interception() {
    assert_failure(
        &["serve".as_ref(), "--instance".as_ref(), "work".as_ref()],
        "--config <FILE>",
    );
    assert_config_failure_in(
        command(),
        &["--instance", "work"],
        r#"{"listen":"127.0.0.1:0"}"#,
        "--instance requires interception configuration",
    );
}

#[test]
fn interception_config_rejects_invalid_destinations_and_loads_the_initialized_ca_before_bind() {
    let root = common::private_root();
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
            "interception": { "destinations": destinations }
        })
        .to_string();
        assert_config_failure_in(in_runtime(root.path()), &[], &content, "interception");
    }
    for unknown in ["ca_directory", "insecure"] {
        let content = serde_json::json!({
            "listen": "127.0.0.1:0",
            "interception": { "destinations": ["localhost:443"], unknown: true }
        })
        .to_string();
        assert_config_failure(&content, &format!("unknown field `{unknown}`"));
    }
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let certificate = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()]).unwrap();
    let upstream_roots = root.path().join("roots.pem");
    fs::write(&upstream_roots, certificate.cert.pem()).unwrap();
    let content = serde_json::json!({
        "listen": listener.local_addr().unwrap().to_string(),
        "interception": { "destinations": ["localhost:443"], "upstream_roots": upstream_roots }
    })
    .to_string();
    let mut unset = command();
    unset
        .env_remove("XDG_RUNTIME_DIR")
        .env_remove("AIRLOCK_HOME");
    assert_config_failure_in(unset, &[], &content, "XDG_RUNTIME_DIR is unset or empty");
    // The occupied port fails only after the CA loads, so a missing CA wins.
    let directory = root.path().join("airlock/work");
    let serve = |expected_error: &str| {
        assert_config_failure_in(
            in_runtime(root.path()),
            &["--instance", "work"],
            &content,
            expected_error,
        );
    };
    serve(&format!(
        "{} must hold ca.pem and ca.key; create them with `airlock ca init --instance work`",
        directory.display()
    ));
    assert!(!directory.exists(), "serve created a CA");
    let init = in_runtime(root.path())
        .args(["ca", "init", "--instance", "work"])
        .output()
        .expect("run Airlock CA init");
    assert!(init.status.success(), "{init:?}");
    serve("Address already in use");
}

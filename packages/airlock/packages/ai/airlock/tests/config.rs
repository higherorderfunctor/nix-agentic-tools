mod common;

use std::{
    ffi::OsStr,
    fs,
    process::Stdio,
    thread,
    time::{Duration, Instant},
};

use common::process::{Airlock, STARTUP_TIMEOUT, TemporaryConfig, command, health};

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

fn assert_failure(arguments: &[&OsStr], expected_error: &str) {
    let mut child = command()
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

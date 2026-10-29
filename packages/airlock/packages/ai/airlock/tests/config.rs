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
fn ca_directory_override_replaces_the_configured_directory_before_readiness() {
    let root = tempfile::TempDir::new().unwrap();
    let directory = root.path().join("runtime-ca");
    let configured_directory = root.path().join("unused-ca");
    let certificate = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()]).unwrap();
    let upstream_roots = root.path().join("roots.pem");
    fs::write(&upstream_roots, certificate.cert.pem()).unwrap();
    // The first start creates the CA; the second validates and reuses it.
    let mut created = None;
    for ca_directory in [None, Some(&configured_directory)] {
        let mut content = serde_json::json!({
            "listen": "127.0.0.1:0",
            "interception": {"destinations": ["localhost:443"], "upstream_roots": upstream_roots}
        });
        if let Some(path) = ca_directory {
            content["interception"]["ca_directory"] = serde_json::json!(path);
        } else {
            assert_config_failure(&content.to_string(), "interception requires ca_directory");
            let mut empty = content.clone();
            empty["interception"]["ca_directory"] = serde_json::json!("");
            assert_config_failure(&empty.to_string(), "interception requires ca_directory");
        }
        let config = TemporaryConfig::new(&content.to_string());
        let airlock = Airlock::spawn(&[
            "serve".as_ref(),
            "--ca-directory".as_ref(),
            directory.as_os_str(),
            "--config".as_ref(),
            config.path.as_os_str(),
        ]);
        airlock.listen_address();
        let pem = fs::read(directory.join("ca.pem")).unwrap();
        assert!(directory.join("ca.key").exists());
        assert!(!configured_directory.exists());
        assert!(airlock.stop(libc::SIGTERM).success());
        let created = created.get_or_insert_with(|| pem.clone());
        assert_eq!(*created, pem, "restart replaced the CA");
    }
}

#[test]
fn ca_directory_override_requires_config_with_interception() {
    let config = TemporaryConfig::new(r#"{"listen":"127.0.0.1:0"}"#);
    for arguments in [
        vec!["serve", "--ca-directory", "/unused"],
        vec![
            "serve",
            "--listen",
            "127.0.0.1:0",
            "--ca-directory",
            "/unused",
        ],
    ] {
        let arguments: Vec<&OsStr> = arguments.into_iter().map(OsStr::new).collect();
        assert_failure(&arguments, "--ca-directory");
    }
    assert_failure(
        &["serve".as_ref(), "--ca-directory".as_ref()],
        "--ca-directory <DIRECTORY>",
    );
    let path = config.path.to_str().unwrap();
    for (extra, expected_error) in [
        (
            vec!["--ca-directory", "/unused"],
            "--ca-directory requires interception configuration",
        ),
        (
            vec!["--ca-directory", "/unused", "--ca-directory", "/other"],
            "cannot be used multiple times",
        ),
    ] {
        let arguments: Vec<&OsStr> = ["serve", "--config", path]
            .into_iter()
            .chain(extra)
            .map(OsStr::new)
            .collect();
        assert_failure(&arguments, expected_error);
    }
}

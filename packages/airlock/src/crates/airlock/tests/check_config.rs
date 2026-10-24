use std::{path::PathBuf, process::Command};

#[test]
fn valid_fixture_is_accepted() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let output = Command::new(env!("CARGO_BIN_EXE_airlock"))
        .arg("check-config")
        .arg("--config")
        .arg(manifest_dir.join("tests/fixtures/valid.json"))
        .output()
        .expect("run airlock");

    let stdout = String::from_utf8(output.stdout).expect("stdout utf-8");
    assert_eq!(stdout, "ok\n");
    assert!(output.status.success());
}

#[test]
fn invalid_fixture_prints_every_domain_error_on_its_own_line() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let output = Command::new(env!("CARGO_BIN_EXE_airlock"))
        .arg("check-config")
        .arg("--config")
        .arg(manifest_dir.join("tests/fixtures/invalid.json"))
        .output()
        .expect("run airlock");

    let stderr = String::from_utf8(output.stderr).expect("stderr utf-8");
    let lines = stderr.lines().collect::<Vec<_>>();
    assert_eq!(
        lines,
        vec![
            "listen address 192.0.2.1:8080 is not loopback",
            "state_dir \"state\" must be absolute",
        ]
    );
    assert!(!output.status.success());
}

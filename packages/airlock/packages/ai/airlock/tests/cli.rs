mod common;

use common::process::{Airlock, command, health};

#[test]
fn generated_help_and_version_describe_each_command() {
    for (arguments, expected) in [
        (vec!["--help"], vec!["Usage:", "--version", "serve", "ca"]),
        (vec!["--version"], vec![env!("CARGO_PKG_VERSION")]),
        (
            vec!["serve", "--help"],
            vec!["--listen", "127.0.0.1:8318", "--config", "--ca-directory"],
        ),
        (vec!["help", "serve"], vec!["--listen", "--config"]),
        (vec!["ca", "--help"], vec!["init"]),
        (vec!["ca", "init", "--help"], vec!["<DIRECTORY>"]),
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
        let airlock = Airlock::spawn(&[
            "serve".as_ref(),
            "--listen".as_ref(),
            "127.0.0.1:0".as_ref(),
        ]);
        let address = airlock.listen_address();
        let response = health(address);
        assert!(response.starts_with("HTTP/1.1 200 "), "{response}");
        let status = airlock.stop(signal);
        assert!(status.success(), "{status}");
        std::net::TcpListener::bind(address).expect("port released after signal");
    }
}

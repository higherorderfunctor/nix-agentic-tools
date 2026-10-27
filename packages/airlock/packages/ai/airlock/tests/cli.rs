use std::process::Command;

fn command() -> Command {
    Command::new(env!("CARGO_BIN_EXE_airlock"))
}

#[test]
fn generated_help_and_version_describe_each_command() {
    for (arguments, expected) in [
        (vec!["--help"], vec!["Usage:", "--version"]),
        (vec!["--version"], vec![env!("CARGO_PKG_VERSION")]),
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
fn cli_requires_a_supported_argument() {
    for arguments in [vec![], vec!["unknown"]] {
        let output = command().args(&arguments).output().unwrap();
        assert!(!output.status.success(), "{arguments:?}");
        assert!(!output.stderr.is_empty(), "{arguments:?}");
    }
}

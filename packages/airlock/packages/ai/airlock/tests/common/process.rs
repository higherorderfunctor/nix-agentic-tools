//! Run the airlock binary as a child process.
use std::{path::Path, process::Command};

#[allow(dead_code)]
pub fn command() -> Command {
    Command::new(env!("CARGO_BIN_EXE_airlock"))
}

/// The binary with `runtime` as its only runtime base: `XDG_RUNTIME_DIR` set
/// and no inherited `AIRLOCK_HOME`.
#[allow(dead_code)]
pub fn in_runtime(runtime: &Path) -> Command {
    let mut command = command();
    command
        .env("XDG_RUNTIME_DIR", runtime)
        .env_remove("AIRLOCK_HOME");
    command
}

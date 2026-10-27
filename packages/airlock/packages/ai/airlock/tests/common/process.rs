//! Run the airlock binary as a child process.
use std::process::Command;

#[allow(dead_code)]
pub fn command() -> Command {
    Command::new(env!("CARGO_BIN_EXE_airlock"))
}

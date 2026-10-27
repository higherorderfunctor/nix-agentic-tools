use std::{env, process::ExitCode};

const USAGE: &str = "Usage: airlock [--help|--version]";

fn main() -> ExitCode {
    let mut arguments = env::args_os();
    let Some(argument) = arguments.nth(1) else {
        eprintln!("{USAGE}");
        return ExitCode::FAILURE;
    };
    if arguments.next().is_some() {
        eprintln!("airlock: expected exactly one argument");
        eprintln!("{USAGE}");
        return ExitCode::FAILURE;
    }

    match argument.to_string_lossy().as_ref() {
        "--help" => {
            println!("Airlock is a local egress proxy for coding harnesses.");
            println!();
            println!("{USAGE}");
            println!("The proxy listener and configuration interface are not implemented yet.");
            ExitCode::SUCCESS
        }
        "--version" => {
            println!("airlock {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("airlock: unsupported argument");
            eprintln!("{USAGE}");
            ExitCode::FAILURE
        }
    }
}

mod cli;

use std::process::ExitCode;

use airlock::server;
use clap::Parser;
use cli::{Cli, Command};

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("airlock: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<(), String> {
    match cli.command {
        Command::Serve { listen } => server::run(listen).map_err(|error| error.to_string()),
    }
}

mod cli;
mod config;

use std::process::ExitCode;

use airlock::{ca, server};
use clap::Parser;
use cli::{CaCommand, Cli, Command};
use config::Config;

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
        Command::Serve { listen, config } => {
            let listen = match config {
                Some(path) => Config::read(path)?.listen,
                None => listen,
            };
            server::run(listen).map_err(|error| error.to_string())
        }
        Command::Ca {
            command: CaCommand::Init { directory },
        } => {
            println!("{}", ca::init(directory)?.display());
            Ok(())
        }
    }
}

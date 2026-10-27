mod cli;

use std::process::ExitCode;

use airlock::{ca, config::Config, server};
use clap::Parser;
use cli::{CaCommand, Cli, Command};

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
        Command::Serve {
            listen,
            config,
            ca_directory,
        } => {
            let config = match config {
                Some(path) => Config::read(path, ca_directory)?,
                None => Config {
                    listen,
                    clients: None,
                    interception: None,
                },
            };
            server::run(config).map_err(|error| error.to_string())
        }
        Command::Ca {
            command: CaCommand::Init { directory },
        } => {
            println!("{}", ca::init(directory)?.display());
            Ok(())
        }
    }
}

mod cli;

use std::process::ExitCode;

use airlock::{ca, server};
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
        Command::Serve { listen } => server::run(listen).map_err(|error| error.to_string()),
        Command::Ca {
            command: CaCommand::Init { instance },
        } => {
            let base = ca::RuntimeBase::from_environment()?;
            println!("{}", ca::init(&base, &instance)?.display());
            Ok(())
        }
    }
}

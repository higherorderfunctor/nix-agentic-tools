use std::{fs, io, path::PathBuf, process::ExitCode};

use airlock_core::config::{Config, RawConfig};
use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(version, about = "Validate airlock gateway configuration")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    CheckConfig {
        #[arg(long)]
        config: PathBuf,
    },
}

#[derive(Debug, thiserror::Error)]
enum CheckConfigError {
    #[error(transparent)]
    Config(airlock_core::error::ConfigErrors),
    #[error(transparent)]
    Io(io::Error),
    #[error(transparent)]
    Json(serde_json::Error),
}

fn run() -> Result<(), CheckConfigError> {
    let cli = Cli::parse();
    let Command::CheckConfig { config } = cli.command;
    let source = fs::read_to_string(config).map_err(CheckConfigError::Io)?;
    let raw = serde_json::from_str::<RawConfig>(&source).map_err(CheckConfigError::Json)?;

    // Paths are validated without loading secrets: the Nix check renders config at eval time, before secret files exist.
    Config::try_from(raw).map_err(CheckConfigError::Config)?;
    println!("ok");
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(CheckConfigError::Config(errors)) => {
            for error in &errors.0 {
                eprintln!("{error}");
            }
            ExitCode::FAILURE
        }
        Err(error @ (CheckConfigError::Io(_) | CheckConfigError::Json(_))) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

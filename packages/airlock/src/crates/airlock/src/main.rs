use std::{fs, io, path::PathBuf, process::ExitCode};

use airlock_core::config::{Config, RawConfig};
use airlock_gateway::Gateway;
use clap::{Parser, Subcommand};
use tokio::signal::unix::{SignalKind, signal};
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(version, about = "airlock credential gateway")]
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
    Serve {
        #[arg(long)]
        config: PathBuf,
    },
}

#[derive(Debug, thiserror::Error)]
enum Error {
    #[error(transparent)]
    Config(#[from] airlock_core::error::ConfigErrors),
    #[error(transparent)]
    Gateway(#[from] airlock_gateway::Error),
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

async fn run() -> Result<(), Error> {
    let cli = Cli::parse();
    let (Command::CheckConfig { config } | Command::Serve { config }) = &cli.command;
    let source = fs::read_to_string(config)?;
    let raw = serde_json::from_str::<RawConfig>(&source)?;
    // check-config validates paths without loading secrets; secret files may not exist yet.
    let config = Config::try_from(raw)?;
    match cli.command {
        Command::CheckConfig { .. } => println!("ok"),
        Command::Serve { .. } => {
            tracing_subscriber::fmt()
                .json()
                .with_env_filter(
                    EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
                )
                .with_writer(io::stderr)
                .init();
            let mut interrupt = signal(SignalKind::interrupt())?;
            let mut terminate = signal(SignalKind::terminate())?;
            Gateway::bind(config)
                .await?
                .serve(async move {
                    tokio::select! {
                        _ = interrupt.recv() => {},
                        _ = terminate.recv() => {},
                    }
                })
                .await?;
        }
    }
    Ok(())
}

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(Error::Config(errors)) => {
            for error in &errors.0 {
                eprintln!("{error}");
            }
            ExitCode::FAILURE
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

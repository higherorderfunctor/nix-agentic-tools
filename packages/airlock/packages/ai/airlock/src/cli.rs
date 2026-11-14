use std::net::SocketAddr;

use airlock::ca::Instance;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    version,
    about = "Airlock is a local egress proxy for coding harnesses"
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand)]
pub enum Command {
    /// Start the proxy listener.
    Serve {
        /// IP loopback address to listen on (port 0 allowed).
        #[arg(long, default_value = "127.0.0.1:8318")]
        listen: SocketAddr,
    },
    /// Manage the private local CA without installing trust.
    Ca {
        #[command(subcommand)]
        command: CaCommand,
    },
}

#[derive(Subcommand)]
pub enum CaCommand {
    /// Create or validate a private local CA and print its public certificate path.
    Init {
        /// The instance whose runtime directory holds the CA.
        #[arg(long, value_name = "NAME", default_value = "default")]
        instance: Instance,
    },
}

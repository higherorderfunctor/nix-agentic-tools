use std::net::SocketAddr;

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
}

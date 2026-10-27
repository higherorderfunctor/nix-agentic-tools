mod cli;

use clap::Parser;

fn main() {
    cli::Cli::parse();
}

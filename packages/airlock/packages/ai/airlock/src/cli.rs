use clap::Parser;

#[derive(Parser)]
#[command(
    version,
    about = "Airlock is a local egress proxy for coding harnesses",
    arg_required_else_help = true
)]
pub struct Cli {}

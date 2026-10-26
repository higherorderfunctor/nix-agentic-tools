use std::{net::SocketAddr, process::ExitCode, time::Duration};

mod config;

use crate::config::Config;
use airlock::tunnel;

const DEFAULT_LISTEN: &str = "127.0.0.1:8318";
const PROCESS_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);
const USAGE: &str =
    "Usage: airlock [--help|--version | serve [--listen <loopback-address> | --config <file>]]";

fn main() -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("airlock: could not start async runtime: {error}");
            return ExitCode::FAILURE;
        }
    };
    let exit = runtime.block_on(run());
    runtime.shutdown_timeout(PROCESS_SHUTDOWN_TIMEOUT);
    exit
}

async fn run() -> ExitCode {
    let mut arguments = std::env::args_os();
    let Some(command) = arguments.nth(1) else {
        eprintln!("{USAGE}");
        return ExitCode::FAILURE;
    };

    match command.to_string_lossy().as_ref() {
        "--help" => {
            reject_extra(&mut arguments);
            print_help();
            ExitCode::SUCCESS
        }
        "--version" => {
            reject_extra(&mut arguments);
            println!("airlock {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        "serve" => {
            let listen = match parse_listen(&mut arguments) {
                Ok(listen) => listen,
                Err(error) => {
                    eprintln!("airlock: {error}");
                    eprintln!("{USAGE}");
                    return ExitCode::FAILURE;
                }
            };
            start(listen).await
        }
        _ => {
            eprintln!("airlock: unsupported command");
            eprintln!("{USAGE}");
            ExitCode::FAILURE
        }
    }
}

fn reject_extra(arguments: &mut std::env::ArgsOs) {
    if arguments.next().is_some() {
        eprintln!("airlock: unexpected extra argument");
        eprintln!("{USAGE}");
        std::process::exit(1);
    }
}

fn parse_listen(arguments: &mut std::env::ArgsOs) -> Result<SocketAddr, String> {
    let Some(flag) = arguments.next() else {
        return DEFAULT_LISTEN
            .parse()
            .map_err(|error| format!("invalid default listen address: {error}"));
    };

    if flag == "--listen" {
        let Some(address) = arguments.next() else {
            return Err("--listen requires an address".to_owned());
        };
        let listen = address
            .to_str()
            .and_then(|address| address.parse::<SocketAddr>().ok())
            .ok_or_else(|| "--listen requires an IP socket address".to_owned())?;
        reject_trailing(arguments)?;
        return Ok(listen);
    }

    if flag == "--config" {
        let Some(path) = arguments.next() else {
            return Err("--config requires a file".to_owned());
        };
        reject_trailing(arguments)?;
        return Config::read(path).map(|config| config.listen);
    }

    Err("serve accepts only --listen and --config".to_owned())
}

fn reject_trailing(arguments: &mut std::env::ArgsOs) -> Result<(), String> {
    if arguments.next().is_some() {
        return Err("serve accepts only one of --listen and --config".to_owned());
    }
    Ok(())
}

async fn start(listen: SocketAddr) -> ExitCode {
    let listener = match tunnel::bind(listen).await {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("airlock: {error}");
            return ExitCode::FAILURE;
        }
    };
    let address = match listener.local_addr() {
        Ok(address) => address,
        Err(error) => {
            eprintln!("airlock: {error}");
            return ExitCode::FAILURE;
        }
    };
    println!("airlock listening on {address}");

    let shutdown = async {
        let interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt());
        let terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate());
        let (mut interrupt, mut terminate) = match (interrupt, terminate) {
            (Ok(interrupt), Ok(terminate)) => (interrupt, terminate),
            _ => {
                eprintln!("airlock: could not install signal handlers");
                std::process::exit(1);
            }
        };

        tokio::select! {
            _ = interrupt.recv() => {}
            _ = terminate.recv() => {}
        }
    };

    if let Err(error) = tunnel::serve(listener, shutdown).await {
        eprintln!("airlock: {error}");
        return ExitCode::FAILURE;
    }

    ExitCode::SUCCESS
}

fn print_help() {
    println!("Airlock is a local egress proxy for coding harnesses.");
    println!("Airlock listens on loopback and accepts unauthenticated CONNECT tunnels only.");
    println!();
    println!("{USAGE}");
    println!("  serve                  Listen on {DEFAULT_LISTEN}");
    println!(
        "  serve --listen ADDR    Listen on an IP loopback address; port 0 is useful for tests"
    );
    println!(
        "  serve --config FILE    Read a strict JSON document such as {{\"listen\":\"127.0.0.1:8318\"}}"
    );
    println!();
    println!("The proxy forwards opaque bytes without TLS interception.");
    println!(
        "Absolute-form HTTP requests are not supported; native HTTPS client authentication is unchanged."
    );
}

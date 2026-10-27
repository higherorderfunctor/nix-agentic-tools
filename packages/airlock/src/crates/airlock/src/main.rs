use std::{env, ffi::OsString, net::SocketAddr, process::ExitCode};

use airlock::server;

const DEFAULT_LISTEN: &str = "127.0.0.1:8318";
const USAGE: &str = "Usage: airlock [--help|--version | serve [--listen <loopback-address>]]";

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("airlock: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let mut arguments = env::args_os().skip(1);
    let command = arguments.next().ok_or(USAGE)?;

    match command.to_str() {
        Some("--help") => {
            reject_extra(&mut arguments)?;
            println!("Airlock is a local egress proxy for coding harnesses.");
            println!();
            println!("{USAGE}");
            println!("  serve                 Listen on {DEFAULT_LISTEN}");
            println!("  serve --listen ADDR   Listen on an IP loopback address (port 0 allowed)");
            println!();
            println!("GET /health reports readiness. Proxy forwarding is not implemented yet.");
            Ok(())
        }
        Some("--version") => {
            reject_extra(&mut arguments)?;
            println!("airlock {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Some("serve") => {
            let listen = parse_listen(&mut arguments)?;
            server::run(listen).map_err(|error| error.to_string())
        }
        _ => Err(format!("unsupported command\n{USAGE}")),
    }
}

fn reject_extra(arguments: &mut impl Iterator<Item = OsString>) -> Result<(), String> {
    if arguments.next().is_some() {
        return Err(format!("unexpected extra argument\n{USAGE}"));
    }
    Ok(())
}

fn parse_listen(arguments: &mut impl Iterator<Item = OsString>) -> Result<SocketAddr, String> {
    let address = match arguments.next() {
        None => DEFAULT_LISTEN.to_owned(),
        Some(flag) if flag == "--listen" => arguments
            .next()
            .and_then(|address| address.into_string().ok())
            .ok_or("--listen requires an IP socket address")?,
        Some(_) => return Err(format!("serve accepts only --listen\n{USAGE}")),
    };
    reject_extra(arguments)?;
    address
        .parse()
        .map_err(|_| "--listen requires an IP socket address".to_owned())
}

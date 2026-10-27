use std::{env, ffi::OsString, net::SocketAddr, process::ExitCode};

mod config;

use airlock::server;
use config::Config;

const DEFAULT_LISTEN: &str = "127.0.0.1:8318";
const USAGE: &str =
    "Usage: airlock [--help|--version | serve [--listen <loopback-address> | --config <file>]]";

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
            println!("  serve --config FILE   Read a strict JSON listen configuration");
            println!();
            println!("HTTP/1.1 and cleartext HTTP/2 share this listener.");
            println!(
                "GET /health reports readiness. CONNECT forwards opaque TCP without TLS interception."
            );
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
    let listen = match arguments.next() {
        None => DEFAULT_LISTEN
            .parse()
            .expect("valid default listen address"),
        Some(flag) if flag == "--listen" => arguments
            .next()
            .and_then(|address| address.into_string().ok())
            .and_then(|address| address.parse().ok())
            .ok_or("--listen requires an IP socket address")?,
        Some(flag) if flag == "--config" => {
            let path = arguments.next().ok_or("--config requires a file")?;
            reject_serve_extra(arguments)?;
            return Config::read(path).map(|config| config.listen);
        }
        Some(_) => return Err(format!("serve accepts only --listen and --config\n{USAGE}")),
    };
    reject_serve_extra(arguments)?;
    Ok(listen)
}

fn reject_serve_extra(arguments: &mut impl Iterator<Item = OsString>) -> Result<(), String> {
    if arguments.next().is_some() {
        return Err("serve accepts only one of --listen and --config".to_owned());
    }
    Ok(())
}

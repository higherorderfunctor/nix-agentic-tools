use std::{env, ffi::OsString, net::SocketAddr, path::PathBuf, process::ExitCode};

mod config;

use airlock::{ca, server};
use config::Config;

const DEFAULT_LISTEN: &str = "127.0.0.1:8318";
const USAGE: &str = concat!(
    "Usage: airlock [--help|--version | serve [--listen <loopback-address> | ",
    "--config <file>] | ca init DIRECTORY]"
);

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
            println!("  ca init DIRECTORY     Create or validate a private local CA");
            println!();
            println!("HTTP/1.1 forwarding and cleartext HTTP/2 CONNECT share this listener.");
            println!("HTTP/1.1 absolute-form http:// requests stream to upstreams.");
            println!(
                "GET /health reports readiness. CONNECT forwards opaque TCP without TLS interception."
            );
            println!("CA initialization writes ca.pem and ca.key without installing trust.");
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
        Some("ca") => {
            let directory = parse_ca_init(&mut arguments)?;
            let certificate = ca::init(directory)?;
            println!("{}", certificate.display());
            Ok(())
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

fn parse_ca_init(arguments: &mut impl Iterator<Item = OsString>) -> Result<PathBuf, String> {
    match arguments.next() {
        Some(subcommand) if subcommand == "init" => {}
        _ => return Err("ca accepts only init DIRECTORY".to_owned()),
    }
    let directory = arguments.next().ok_or("ca init requires a directory")?;
    if arguments.next().is_some() {
        return Err("ca init accepts only one directory".to_owned());
    }
    Ok(PathBuf::from(directory))
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

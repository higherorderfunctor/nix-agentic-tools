use std::{
    env,
    ffi::OsString,
    fs, io,
    num::NonZeroU64,
    path::{Path, PathBuf},
    process::ExitCode,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use airlock_core::config::{Config, RawConfig};
use airlock_core::storage::SqliteStorage;
use airlock_gateway::Gateway;
use clap::{Parser, Subcommand};
use rustls::RootCertStore;
use tokio::signal::unix::{SignalKind, signal};
use tracing_subscriber::EnvFilter;

mod collector;
mod control;
mod report;

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
        #[arg(long)]
        web_root: Option<PathBuf>,
    },
    Usage {
        #[arg(long)]
        config: PathBuf,
        #[arg(long, default_value_t = 3600)]
        bucket_seconds: u64,
        #[arg(long, default_value_t = report::default_history_limit())]
        history_limit: u64,
        #[arg(long)]
        since_unix: Option<i64>,
        #[arg(long)]
        json: bool,
    },
}

#[derive(Debug, thiserror::Error)]
enum Error {
    #[error(transparent)]
    Config(#[from] airlock_core::error::ConfigErrors),
    #[error(transparent)]
    Control(#[from] control::Error),
    #[error(transparent)]
    Secret(#[from] airlock_core::error::SecretError),
    #[error(transparent)]
    Gateway(#[from] airlock_gateway::Error),
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    RuntimeDirectory(#[from] RuntimeDirectoryError),
    #[error(transparent)]
    Storage(#[from] airlock_core::storage::StorageError),
    #[error(transparent)]
    Task(#[from] tokio::task::JoinError),
    #[error("the system clock is before the Unix epoch")]
    SystemTimeBeforeEpoch,
    #[error("gateway retained storage after serving stopped")]
    StorageOwnership,
    #[error("more than 64 usage credentials are configured")]
    UsageCredentialLimit,
    #[error("invalid usage report options: {0}")]
    UsageOptions(&'static str),
}

#[derive(Debug, thiserror::Error)]
enum RuntimeDirectoryError {
    #[error("XDG_RUNTIME_DIR {path:?} must be absolute")]
    Relative { path: PathBuf },
    #[error("{path} is not on tmpfs or ramfs (filesystem magic {magic:#x})")]
    NotInMemory { magic: u32, path: PathBuf },
    #[error(transparent)]
    Unusable(#[from] airlock_gateway::CaError),
    #[error("could not read the filesystem type of {path}: {source}")]
    Statfs { path: PathBuf, source: io::Error },
    #[error("XDG_RUNTIME_DIR is not set; airlock keeps its CA only on the per-user tmpfs")]
    Unset,
}

/// Resolves the CA directory, `$XDG_RUNTIME_DIR/airlock-<port>`, on a private in-memory mount.
///
/// Never falls back to `/tmp`, which may be disk: memory is what makes the CA rotate at reboot.
/// The runtime directory is checked before anything is created in it; the CA directory itself
/// is checked again after creation, so a mount point there cannot put the CA on disk.
fn ca_directory(
    runtime_directory: Option<OsString>,
    port: u16,
) -> Result<PathBuf, RuntimeDirectoryError> {
    let path = PathBuf::from(runtime_directory.ok_or(RuntimeDirectoryError::Unset)?);
    if !path.is_absolute() {
        return Err(RuntimeDirectoryError::Relative { path });
    }
    airlock_gateway::private_directory(&path)?;
    in_memory(&path)?;
    let directory = path.join(format!("airlock-{port}"));
    airlock_gateway::create_private_directory(&directory)?;
    in_memory(&directory)?;
    Ok(directory)
}

#[cfg(target_os = "linux")]
fn in_memory(path: &Path) -> Result<(), RuntimeDirectoryError> {
    let stat = rustix::fs::statfs(path).map_err(|source| RuntimeDirectoryError::Statfs {
        path: path.to_owned(),
        source: source.into(),
    })?;
    // Filesystem magics are 32-bit; the width of `f_type` varies by architecture.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let magic = stat.f_type as u32;
    if is_in_memory(magic) {
        Ok(())
    } else {
        Err(RuntimeDirectoryError::NotInMemory {
            magic,
            path: path.to_owned(),
        })
    }
}

// Other platforms have no statfs magic to compare; the private-directory checks still apply.
#[cfg(not(target_os = "linux"))]
fn in_memory(_path: &Path) -> Result<(), RuntimeDirectoryError> {
    Ok(())
}

#[cfg(target_os = "linux")]
fn is_in_memory(magic: u32) -> bool {
    const RAMFS_MAGIC: u32 = 0x8584_58f6;
    const TMPFS_MAGIC: u32 = 0x0102_1994;
    matches!(magic, RAMFS_MAGIC | TMPFS_MAGIC)
}

/// The system trust store (`SSL_CERT_FILE` when set); unparseable entries are skipped.
fn upstream_roots() -> RootCertStore {
    let mut roots = RootCertStore::empty();
    roots.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
    roots
}

fn now_unix() -> Result<i64, Error> {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| Error::SystemTimeBeforeEpoch)?
        .as_secs();
    i64::try_from(seconds).map_err(|_| Error::SystemTimeBeforeEpoch)
}

#[expect(
    clippy::too_many_lines,
    reason = "serve startup owns config, storage, collector, gateway, control, and shutdown ordering"
)]
async fn run() -> Result<(), Error> {
    let cli = Cli::parse();
    let config = match &cli.command {
        Command::CheckConfig { config }
        | Command::Serve { config, .. }
        | Command::Usage { config, .. } => config,
    };
    let source = fs::read_to_string(config)?;
    let raw = serde_json::from_str::<RawConfig>(&source)?;
    // check-config validates paths without loading secrets; secret files may not exist yet.
    let config = Config::try_from(raw)?;
    match cli.command {
        Command::CheckConfig { .. } => println!("ok"),
        Command::Usage {
            bucket_seconds,
            history_limit,
            since_unix,
            json,
            ..
        } => {
            let now = now_unix()?;
            let options = report::Options {
                bucket_seconds: NonZeroU64::new(bucket_seconds)
                    .ok_or(Error::UsageOptions("bucket-seconds must be positive"))?,
                history_limit,
                since_unix: since_unix.unwrap_or(now.saturating_sub(7 * 24 * 3600).max(1)),
            };
            options.validate(now).map_err(Error::UsageOptions)?;
            let mut reader =
                airlock_core::storage::ReadOnlyStorage::open(config.state_dir()).await?;
            let value = report::build(&config, &mut reader, &options, now).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&value)?);
            } else {
                println!("{}", report::human(&value));
            }
        }
        Command::Serve { web_root, .. } => {
            if config.usage_collector_credentials().len() > collector::MAX_CREDENTIALS {
                return Err(Error::UsageCredentialLimit);
            }
            tracing_subscriber::fmt()
                .json()
                .with_env_filter(
                    EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
                )
                .with_writer(io::stderr)
                .init();
            let mut interrupt = signal(SignalKind::interrupt())?;
            let mut terminate = signal(SignalKind::terminate())?;
            let ca_directory =
                ca_directory(env::var_os("XDG_RUNTIME_DIR"), config.listen().port())?;
            let (web_root, control_config) = match (web_root, config.control()) {
                (Some(web_root), Some(control)) => (web_root, Some(control)),
                (_, None) => (PathBuf::from("/nonexistent"), None),
                _ => {
                    return Err(Error::Control(control::Error::InvalidWebRoot(
                        PathBuf::from("--web-root is required when control is configured"),
                    )));
                }
            };
            let storage = Arc::new(
                SqliteStorage::open(config.state_dir(), config.storage_identities(now_unix()?))
                    .await?,
            );
            let control_server = match control_config {
                Some(_) => {
                    let token = Arc::new(config.load_control_token()?);
                    Some(
                        control::ControlServer::bind(
                            Arc::new(config.clone()),
                            config.state_dir(),
                            &web_root,
                            token,
                        )
                        .await?,
                    )
                }
                None => None,
            };
            let roots = upstream_roots();
            let gateway = Gateway::bind_with_storage_and_usage(
                config.clone(),
                &ca_directory,
                roots.clone(),
                Some(Arc::clone(&storage)),
                Some(storage.clone()),
            )
            .await?;
            let collector = tokio::spawn(collector::run(
                Arc::new(config.clone()),
                storage.clone(),
                roots,
            ));
            let (shutdown_sender, shutdown_receiver) = tokio::sync::watch::channel(());
            let shutdown_trigger = shutdown_sender.clone();
            let signal_task = tokio::spawn(async move {
                tokio::select! {
                    _ = interrupt.recv() => {},
                    _ = terminate.recv() => {},
                }
                let _ = shutdown_sender.send(());
            });
            let mut gateway_shutdown = shutdown_receiver.clone();
            let mut gateway_task = tokio::spawn(gateway.serve(async move {
                let _ = gateway_shutdown.changed().await;
            }));
            let mut control_task = control_server.map(|server| {
                let mut control_shutdown = shutdown_receiver.clone();
                tokio::spawn(server.serve(async move {
                    let _ = control_shutdown.changed().await;
                }))
            });
            let mut gateway_done = None;
            let mut control_done = None;
            let mut shutdown_observer = shutdown_receiver;
            if let Some(task) = control_task.as_mut() {
                tokio::select! {
                    result = &mut gateway_task => gateway_done = Some(result),
                    result = task => control_done = Some(result),
                    _ = shutdown_observer.changed() => {},
                }
            } else {
                tokio::select! {
                    result = &mut gateway_task => gateway_done = Some(result),
                    _ = shutdown_observer.changed() => {},
                }
            }
            let _ = shutdown_trigger.send(());
            let gateway_result = match gateway_done {
                Some(result) => result,
                None => gateway_task.await,
            };
            let mut first_error = gateway_result
                .map_err(Error::Task)
                .and_then(|result| result.map_err(Error::Gateway))
                .err();
            if let Some(task) = control_task {
                let result = match control_done {
                    Some(result) => result,
                    None => task.await,
                };
                if let Err(error) = result
                    .map_err(Error::Task)
                    .and_then(|result| result.map_err(Error::Control))
                {
                    first_error.get_or_insert(error);
                }
            }
            signal_task.abort();
            let _ = signal_task.await;
            collector.abort();
            let _ = collector.await;
            Arc::try_unwrap(storage)
                .map_err(|_| Error::StorageOwnership)?
                .close()
                .await?;
            if let Some(error) = first_error {
                return Err(error);
            }
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

#[cfg(test)]
mod tests {
    use std::os::unix::fs::DirBuilderExt;

    use super::*;

    #[test]
    fn runtime_directory_must_be_set_and_absolute() {
        assert!(matches!(
            ca_directory(None, 8080),
            Err(RuntimeDirectoryError::Unset)
        ));
        for relative in ["", "run/user/1000"] {
            assert!(matches!(
                ca_directory(Some(relative.into()), 8080),
                Err(RuntimeDirectoryError::Relative { .. })
            ));
        }
    }

    #[test]
    fn runtime_directory_must_be_private() {
        let directory = tempfile::tempdir().expect("tempdir");
        std::fs::set_permissions(
            directory.path(),
            std::os::unix::fs::PermissionsExt::from_mode(0o755),
        )
        .expect("chmod");
        assert!(matches!(
            ca_directory(Some(directory.path().into()), 8080),
            Err(RuntimeDirectoryError::Unusable(_))
        ));
    }

    #[test]
    fn runtime_directory_must_not_be_a_symlink() {
        let directory = tempfile::tempdir().expect("tempdir");
        let target = directory.path().join("target");
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&target)
            .expect("private target");
        let link = directory.path().join("link");
        std::os::unix::fs::symlink(&target, &link).expect("symlink");
        assert!(matches!(
            ca_directory(Some(link.into()), 8080),
            Err(RuntimeDirectoryError::Unusable(
                airlock_gateway::CaError::NotPrivate { .. }
            ))
        ));
        assert_eq!(std::fs::read_dir(&target).expect("target").count(), 0);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn only_tmpfs_and_ramfs_count_as_memory() {
        const EXT4_SUPER_MAGIC: u32 = 0xef53;
        assert!(is_in_memory(0x0102_1994));
        assert!(is_in_memory(0x8584_58f6));
        assert!(!is_in_memory(EXT4_SUPER_MAGIC));
    }
}

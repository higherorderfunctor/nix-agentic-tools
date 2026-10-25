use std::{
    env,
    ffi::OsString,
    fs, io,
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
    #[error(transparent)]
    RuntimeDirectory(#[from] RuntimeDirectoryError),
    #[error(transparent)]
    Storage(#[from] airlock_core::storage::StorageError),
    #[error("the system clock is before the Unix epoch")]
    SystemTimeBeforeEpoch,
    #[error("gateway retained storage after serving stopped")]
    StorageOwnership,
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
            let ca_directory =
                ca_directory(env::var_os("XDG_RUNTIME_DIR"), config.listen().port())?;
            let storage = Arc::new(
                SqliteStorage::open(config.state_dir(), config.storage_identities(now_unix()?))
                    .await?,
            );
            let gateway = Gateway::bind_with_storage_and_usage(
                config,
                &ca_directory,
                upstream_roots(),
                Some(Arc::clone(&storage)),
                Some(storage.clone()),
            )
            .await?;
            let serve_result = gateway
                .serve(async move {
                    tokio::select! {
                        _ = interrupt.recv() => {},
                        _ = terminate.recv() => {},
                    }
                })
                .await;
            Arc::try_unwrap(storage)
                .map_err(|_| Error::StorageOwnership)?
                .close()
                .await?;
            serve_result?;
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

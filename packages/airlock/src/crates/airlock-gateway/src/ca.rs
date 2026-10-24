//! The local CA that signs the leaves airlock presents for intercepted hosts.

use std::{
    collections::HashMap,
    fs::{self, DirBuilder, File, Permissions},
    io::{self, Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, PoisonError},
};

use airlock_core::ids::HostName;
use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa,
    Issuer, KeyPair, KeyUsagePurpose, SanType,
};
use rustls::{
    crypto::CryptoProvider,
    pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, pem::PemObject},
    sign::CertifiedKey,
};
use time::{Duration, OffsetDateTime};
use zeroize::Zeroizing;

const CA_CERT: &str = "ca.pem";
const CA_KEY: &str = "ca.key";
const CA_NAME: &str = "airlock local CA";
// Rotation comes from the tmpfs being wiped at reboot, not from expiry.
const CA_VALIDITY: Duration = Duration::days(3650);
// Backdates every certificate so a client whose clock runs behind still accepts it.
const CLOCK_SKEW: Duration = Duration::hours(1);
// A leaf is re-minted once less than this remains, so no live client sees it expire.
const LEAF_RENEWAL: Duration = Duration::hours(24);
const LEAF_VALIDITY: Duration = Duration::days(7);

#[derive(Debug, thiserror::Error)]
pub enum CaError {
    #[error("{path}: {source}")]
    Io { path: PathBuf, source: io::Error },
    #[error("{present} exists without {missing}; remove it so airlock can create a new CA")]
    Incomplete { missing: PathBuf, present: PathBuf },
    #[error("{path} does not hold a usable CA certificate or PKCS#8 key")]
    Invalid { path: PathBuf },
    #[error("CA key {path} is readable by group or others (mode {mode:04o})")]
    KeyExposed { mode: u32, path: PathBuf },
    #[error("CA key {key} does not match certificate {cert}")]
    KeyMismatch { cert: PathBuf, key: PathBuf },
    #[error("could not create a certificate: {0}")]
    Mint(#[from] rcgen::Error),
    #[error("{path} must be a directory, not a symlink, owned by this user with mode 0700")]
    NotPrivate { path: PathBuf },
    #[error("{path} must be a regular file, not a symlink")]
    NotRegular { path: PathBuf },
    #[error("could not load a minted key: {0}")]
    Tls(#[from] rustls::Error),
}

fn io_error(path: &Path) -> impl FnOnce(io::Error) -> CaError {
    let path = path.to_owned();
    move |source| CaError::Io { path, source }
}

/// Refuses a directory that another user owns or can read, or that is a symlink.
///
/// A symlink is refused rather than followed: it could lead the CA off the in-memory mount.
///
/// # Errors
/// Returns `NotPrivate` unless `path` is a directory owned by the current uid with mode 0700.
pub fn private_directory(path: &Path) -> Result<(), CaError> {
    let metadata = fs::symlink_metadata(path).map_err(io_error(path))?;
    if metadata.is_dir()
        && metadata.uid() == rustix::process::getuid().as_raw()
        && metadata.mode() & 0o777 == 0o700
    {
        Ok(())
    } else {
        Err(CaError::NotPrivate {
            path: path.to_owned(),
        })
    }
}

/// Creates `path` with mode 0700 when it is missing, then applies `private_directory`.
///
/// # Errors
/// Returns an I/O error naming `path`, or `NotPrivate` for an existing unsuitable entry.
pub fn create_private_directory(path: &Path) -> Result<(), CaError> {
    match DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {
            fs::set_permissions(path, Permissions::from_mode(0o700)).map_err(io_error(path))?;
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(io_error(path)(error)),
    }
    private_directory(path)
}

struct Leaf {
    key: Arc<CertifiedKey>,
    not_after: OffsetDateTime,
}

pub(crate) struct Authority {
    cert: CertificateDer<'static>,
    key: Zeroizing<KeyPair>,
    // Only hosts in the configured intercept list reach this map, which bounds it; no eviction.
    leaves: Mutex<HashMap<HostName, Leaf>>,
    provider: Arc<CryptoProvider>,
}

impl Authority {
    /// Loads the CA from `directory`, or creates it there when neither file exists.
    pub(crate) fn open(directory: &Path, provider: Arc<CryptoProvider>) -> Result<Self, CaError> {
        create_private_directory(directory)?;
        let cert_path = directory.join(CA_CERT);
        let key_path = directory.join(CA_KEY);
        let (cert, key) = match (exists(&cert_path)?, exists(&key_path)?) {
            (false, false) => create(directory)?,
            (true, true) => load(&cert_path, &key_path, &provider)?,
            (true, false) => {
                return Err(CaError::Incomplete {
                    missing: key_path,
                    present: cert_path,
                });
            }
            (false, true) => {
                return Err(CaError::Incomplete {
                    missing: cert_path,
                    present: key_path,
                });
            }
        };
        tracing::info!(path = %cert_path.display(), "airlock CA certificate");
        Ok(Self {
            cert,
            key,
            leaves: Mutex::default(),
            provider,
        })
    }

    /// Returns the cached leaf for `host`, minting a new one when it is missing or near expiry.
    pub(crate) fn leaf(&self, host: &HostName) -> Result<Arc<CertifiedKey>, CaError> {
        let now = OffsetDateTime::now_utc();
        let mut leaves = self.leaves.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(leaf) = leaves.get(host)
            && leaf.not_after - now > LEAF_RENEWAL
        {
            return Ok(leaf.key.clone());
        }
        let leaf = self.mint(host, now)?;
        let key = leaf.key.clone();
        leaves.insert(host.clone(), leaf);
        Ok(key)
    }

    fn mint(&self, host: &HostName, now: OffsetDateTime) -> Result<Leaf, CaError> {
        let key = Zeroizing::new(KeyPair::generate()?);
        let mut params = CertificateParams::default();
        params.distinguished_name = DistinguishedName::new();
        params
            .distinguished_name
            .push(DnType::CommonName, host.as_ref());
        params.subject_alt_names = vec![SanType::DnsName(host.as_ref().try_into()?)];
        params.is_ca = IsCa::ExplicitNoCa;
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        params.not_before = now - CLOCK_SKEW;
        params.not_after = now + LEAF_VALIDITY;
        let issuer = Issuer::from_ca_cert_der(&self.cert, &*self.key)?;
        let cert = params.signed_by(&*key, &issuer)?;
        let signing_key = self
            .provider
            .key_provider
            .load_private_key(PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
                key.serialize_der(),
            )))?;
        Ok(Leaf {
            key: Arc::new(CertifiedKey::new(vec![cert.der().clone()], signing_key)),
            not_after: params.not_after,
        })
    }
}

/// Whether `path` exists; a symlink or other non-regular entry is refused, never followed.
///
/// The private directory means only this uid could swap an entry between this check and the open.
fn exists(path: &Path) -> Result<bool, CaError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() => Ok(true),
        Ok(_) => Err(CaError::NotRegular {
            path: path.to_owned(),
        }),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(io_error(path)(error)),
    }
}

fn create(directory: &Path) -> Result<(CertificateDer<'static>, Zeroizing<KeyPair>), CaError> {
    let key = Zeroizing::new(KeyPair::generate()?);
    let now = OffsetDateTime::now_utc();
    let mut params = CertificateParams::default();
    params.distinguished_name = DistinguishedName::new();
    params.distinguished_name.push(DnType::CommonName, CA_NAME);
    params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    params.not_before = now - CLOCK_SKEW;
    params.not_after = now + CA_VALIDITY;
    let cert = params.self_signed(&*key)?;
    // The key lands first: a crash between the two writes leaves an incomplete pair, which load refuses.
    write_new(
        directory,
        CA_KEY,
        0o600,
        Zeroizing::new(key.serialize_pem()).as_bytes(),
    )?;
    write_new(directory, CA_CERT, 0o644, cert.pem().as_bytes())?;
    Ok((cert.der().clone(), key))
}

/// Writes `contents` to a temporary file with its final mode, then renames it without replacing.
fn write_new(directory: &Path, name: &str, mode: u32, contents: &[u8]) -> Result<(), CaError> {
    let path = directory.join(name);
    let mut file = tempfile::Builder::new()
        .prefix(".airlock-")
        .permissions(Permissions::from_mode(mode))
        .tempfile_in(directory)
        .map_err(io_error(&path))?;
    // The creation mode is masked by the umask; set it exactly before any byte is written.
    file.as_file()
        .set_permissions(Permissions::from_mode(mode))
        .map_err(io_error(&path))?;
    file.write_all(contents).map_err(io_error(&path))?;
    file.as_file().sync_all().map_err(io_error(&path))?;
    file.persist_noclobber(&path)
        .map_err(|error| io_error(&path)(error.error))?;
    Ok(())
}

fn load(
    cert_path: &Path,
    key_path: &Path,
    provider: &CryptoProvider,
) -> Result<(CertificateDer<'static>, Zeroizing<KeyPair>), CaError> {
    let mut key_file = File::open(key_path).map_err(io_error(key_path))?;
    let mode = key_file.metadata().map_err(io_error(key_path))?.mode();
    if mode & 0o077 != 0 {
        return Err(CaError::KeyExposed {
            mode: mode & 0o7777,
            path: key_path.to_owned(),
        });
    }
    let mut key_pem = Zeroizing::new(Vec::new());
    key_file
        .read_to_end(&mut key_pem)
        .map_err(io_error(key_path))?;
    let invalid_key = || CaError::Invalid {
        path: key_path.to_owned(),
    };
    let key_der =
        Zeroizing::new(PrivatePkcs8KeyDer::from_pem_slice(&key_pem).map_err(|_| invalid_key())?);
    let key = Zeroizing::new(KeyPair::try_from(&*key_der).map_err(|_| invalid_key())?);
    let invalid_cert = || CaError::Invalid {
        path: cert_path.to_owned(),
    };
    let cert_pem = fs::read(cert_path).map_err(io_error(cert_path))?;
    let cert = CertificateDer::from_pem_slice(&cert_pem).map_err(|_| invalid_cert())?;
    let signing_key = provider
        .key_provider
        .load_private_key(PrivateKeyDer::Pkcs8(key_der.clone_key()))
        .map_err(|_| invalid_key())?;
    CertifiedKey::new(vec![cert.clone()], signing_key)
        .keys_match()
        .map_err(|_| CaError::KeyMismatch {
            cert: cert_path.to_owned(),
            key: key_path.to_owned(),
        })?;
    // Parsing the certificate as an issuer up front keeps a malformed one from failing every mint.
    Issuer::from_ca_cert_der(&cert, &*key).map_err(|_| invalid_cert())?;
    Ok((cert, key))
}

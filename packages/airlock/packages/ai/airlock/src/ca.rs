// cspell:words RGRP RUSR WUSR CLOEXEC Errno fchmod fstat getuid linkat mkdirat NONBLOCK NOTDIR RDONLY rustix statat unlinkat WRONLY Zeroizing
//! Locally generated certificate-authority material for future TLS interception.

use std::{
    fs::File,
    io::{self, Read as _, Write as _},
    path::{Path, PathBuf},
    process,
    sync::atomic::{AtomicU64, Ordering::Relaxed},
};

use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, IsCa, KeyPair, KeyUsagePurpose,
};
use rustix::{
    fd::OwnedFd,
    fs::{
        self as rustix_fs, AtFlags, FileType, Mode, OFlags, fchmod, fstat, linkat, mkdirat, openat,
        statat, unlinkat,
    },
    process::getuid,
};
use time::{Duration, OffsetDateTime};
use x509_parser::{
    der_parser::der::parse_der,
    parse_x509_certificate,
    pem::{Pem, parse_x509_pem},
};
use zeroize::Zeroizing;

const CA_CERTIFICATE: &str = "ca.pem";
const CA_KEY: &str = "ca.key";
const CA_NAME: &str = "airlock local CA";
const CA_VALIDITY: Duration = Duration::days(3650);
const CLOCK_SKEW: Duration = Duration::hours(1);
static TEMPORARY_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Creates or validates Airlock's local CA and returns the public certificate path.
///
/// An existing pair is accepted only when it belongs together, is signed by its
/// own key, is a currently valid CA, and meets the private-directory and key
/// permissions requirements. Nothing is rotated, overwritten, or trusted.
pub fn init(directory: impl AsRef<Path>) -> Result<PathBuf, String> {
    let requested = directory.as_ref();
    let directory_path = lexical_path(requested);
    let directory = open_private_directory(&directory_path)?;
    let certificate_path = directory_path.join(CA_CERTIFICATE);
    let key_path = directory_path.join(CA_KEY);

    match (
        open_regular_file(&directory, CA_CERTIFICATE, &certificate_path)?,
        open_regular_file(&directory, CA_KEY, &key_path)?,
    ) {
        (None, None) => create(&directory)?,
        (Some(mut certificate), Some(mut key)) => {
            validate(&mut certificate, &mut key, &certificate_path, &key_path)?
        }
        (Some(_), None) => {
            return Err(format!(
                "{} exists without {}; remove it before creating a new CA",
                certificate_path.display(),
                key_path.display()
            ));
        }
        (None, Some(_)) => {
            return Err(format!(
                "{} exists without {}; remove it before creating a new CA",
                key_path.display(),
                certificate_path.display()
            ));
        }
    }

    if !path_names_directory(&directory, &directory_path)? {
        return Err(format!(
            "{} was replaced while initializing the CA",
            directory_path.display()
        ));
    }

    Ok(certificate_path)
}

fn io_error(path: &Path) -> impl FnOnce(io::Error) -> String + '_ {
    move |source| format!("{}: {source}", path.display())
}

fn mint_error(error: rcgen::Error) -> String {
    format!("could not generate CA material: {error}")
}

fn lexical_path(path: &Path) -> PathBuf {
    // `link/` and `link/.` otherwise make O_NOFOLLOW inspect a directory after
    // following `link`. Components remove those trailing separators and dots.
    let mut normalized = PathBuf::new();
    for component in path.components() {
        normalized.push(component.as_os_str());
    }
    normalized
}

fn open_private_directory(path: &Path) -> Result<OwnedFd, String> {
    match openat(
        rustix_fs::CWD,
        path,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    ) {
        Ok(directory) => {
            validate_private_directory(&directory, path)?;
            Ok(directory)
        }
        Err(error) if io::Error::from(error).kind() == io::ErrorKind::NotFound => {
            create_private_directory(path)
        }
        Err(rustix::io::Errno::LOOP | rustix::io::Errno::NOTDIR) => {
            Err(private_directory_error(path))
        }
        Err(error) => Err(io_error(path)(io::Error::from(error))),
    }
}

fn create_private_directory(path: &Path) -> Result<OwnedFd, String> {
    let Some(name) = path.file_name() else {
        return Err(format!("{} must be a CA directory path", path.display()));
    };
    let parent = path.parent().unwrap_or(Path::new("."));
    let parent = if parent.as_os_str().is_empty() {
        Path::new(".")
    } else {
        parent
    };
    let parent = openat(
        rustix_fs::CWD,
        parent,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|error| io_error(parent)(io::Error::from(error)))?;

    match mkdirat(&parent, name, Mode::from_raw_mode(0o700)) {
        Ok(()) => {}
        Err(error) if io::Error::from(error).kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(io_error(path)(io::Error::from(error))),
    }

    let directory = openat(
        &parent,
        name,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|error| io_error(path)(io::Error::from(error)))?;
    validate_private_directory(&directory, path)?;
    Ok(directory)
}

fn validate_private_directory(directory: &OwnedFd, path: &Path) -> Result<(), String> {
    let metadata = fstat(directory).map_err(|error| io_error(path)(io::Error::from(error)))?;
    if FileType::from_raw_mode(metadata.st_mode) == FileType::Directory
        && metadata.st_mode & 0o777 == 0o700
        && metadata.st_uid == getuid().as_raw()
    {
        Ok(())
    } else {
        Err(private_directory_error(path))
    }
}

fn private_directory_error(path: &Path) -> String {
    format!(
        "{} must be a directory owned by this user with mode 0700",
        path.display()
    )
}

fn open_regular_file(directory: &OwnedFd, name: &str, path: &Path) -> Result<Option<File>, String> {
    let file = match openat(
        directory,
        name,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
        Mode::empty(),
    ) {
        Ok(file) => file,
        Err(error) if io::Error::from(error).kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(rustix::io::Errno::LOOP) => return Err(regular_file_error(path)),
        Err(error) => return Err(io_error(path)(io::Error::from(error))),
    };
    let metadata = fstat(&file).map_err(|error| io_error(path)(io::Error::from(error)))?;
    if FileType::from_raw_mode(metadata.st_mode) != FileType::RegularFile {
        return Err(regular_file_error(path));
    }
    Ok(Some(file.into()))
}

fn regular_file_error(path: &Path) -> String {
    format!("{} must be a regular file, not a symlink", path.display())
}

fn create(directory: &OwnedFd) -> Result<(), String> {
    let (certificate, key) = generate()?;
    write_new(directory, CA_KEY, Mode::RUSR | Mode::WUSR, key.as_bytes())?;
    if let Err(error) = write_new(
        directory,
        CA_CERTIFICATE,
        Mode::RUSR | Mode::WUSR | Mode::RGRP | Mode::ROTH,
        certificate.as_bytes(),
    ) {
        // Another init may have changed the name after our key was published.
        // Unlink cannot condition on the inode, so leave the partial pair for
        // inspection rather than risk deleting somebody else's replacement.
        return Err(format!(
            "{error}; CA publication failed after writing {CA_KEY}; inspect the directory and remove unusable partial material before retrying"
        ));
    }

    Ok(())
}

fn generate() -> Result<(String, Zeroizing<String>), String> {
    let key = Zeroizing::new(KeyPair::generate().map_err(mint_error)?);
    let now = OffsetDateTime::now_utc();
    let mut parameters = CertificateParams::default();
    parameters.distinguished_name = DistinguishedName::new();
    parameters
        .distinguished_name
        .push(DnType::CommonName, CA_NAME);
    parameters.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    parameters.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    parameters.not_before = now - CLOCK_SKEW;
    parameters.not_after = now + CA_VALIDITY;

    let certificate = parameters.self_signed(&*key).map_err(mint_error)?;
    let key_pem = Zeroizing::new(key.serialize_pem());
    Ok((certificate.pem(), key_pem))
}

/// Writes `contents` through a temporary file in `directory`, then links it without replacing.
fn write_new(directory: &OwnedFd, name: &str, mode: Mode, contents: &[u8]) -> Result<(), String> {
    let path = Path::new(name);
    let sequence = TEMPORARY_SEQUENCE.fetch_add(1, Relaxed);
    let temporary = format!(".airlock-{}-{sequence}", process::id());
    let mut file = File::from(
        openat(
            directory,
            &temporary,
            OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            mode,
        )
        .map_err(|error| io_error(path)(io::Error::from(error)))?,
    );
    if let Err(error) = fchmod(&file, mode) {
        let _ = unlinkat(directory, &temporary, AtFlags::empty());
        return Err(io_error(path)(io::Error::from(error)));
    }

    let write_result = file
        .write_all(contents)
        .and_then(|()| file.sync_all())
        .map_err(|source| io_error(path)(source));
    if let Err(error) = write_result {
        let _ = unlinkat(directory, &temporary, AtFlags::empty());
        return Err(error);
    }

    if let Err(error) =
        linkat(directory, &temporary, directory, name, AtFlags::empty()).map_err(io::Error::from)
    {
        let _ = unlinkat(directory, &temporary, AtFlags::empty());
        return Err(io_error(path)(error));
    }
    if let Err(error) = unlinkat(directory, &temporary, AtFlags::empty()).map_err(io::Error::from) {
        return Err(io_error(path)(error));
    }

    Ok(())
}

fn path_names_directory(directory: &OwnedFd, path: &Path) -> Result<bool, String> {
    let opened = fstat(directory).map_err(|error| io_error(path)(io::Error::from(error)))?;
    let named = statat(rustix_fs::CWD, path, AtFlags::SYMLINK_NOFOLLOW)
        .map_err(|error| io_error(path)(io::Error::from(error)))?;
    Ok(opened.st_dev == named.st_dev && opened.st_ino == named.st_ino)
}

fn read_file(file: &mut File, path: &Path) -> Result<Vec<u8>, String> {
    let mut contents = Vec::new();
    file.read_to_end(&mut contents).map_err(io_error(path))?;
    Ok(contents)
}

fn validate(
    certificate_file: &mut File,
    key_file: &mut File,
    certificate_path: &Path,
    key_path: &Path,
) -> Result<(), String> {
    let key_metadata =
        fstat(&*key_file).map_err(|error| io_error(key_path)(io::Error::from(error)))?;
    if key_metadata.st_mode & 0o777 != 0o600 {
        return Err(format!(
            "CA key {} must have mode 0600 (now {:04o})",
            key_path.display(),
            key_metadata.st_mode & 0o777
        ));
    }

    let key_bytes = Zeroizing::new(read_file(key_file, key_path)?);
    let key_der = Zeroizing::new(pem_contents(&key_bytes, key_path, "PRIVATE KEY")?.contents);
    ensure_complete_der(&key_der, key_path, "PKCS#8 private key")?;
    let key = Zeroizing::new(
        KeyPair::try_from(key_der.as_slice())
            .map_err(|_| invalid(key_path, "expected a PKCS#8 private key"))?,
    );

    let certificate_bytes = read_file(certificate_file, certificate_path)?;
    let certificate_pem = pem_contents(&certificate_bytes, certificate_path, "CERTIFICATE")?;
    let (certificate_rest, certificate) = parse_x509_certificate(&certificate_pem.contents)
        .map_err(|_| invalid(certificate_path, "expected a valid X.509 certificate"))?;
    if !certificate_rest.is_empty() {
        return Err(invalid(
            certificate_path,
            "expected one complete X.509 certificate",
        ));
    }

    let tbs = &certificate.tbs_certificate;
    if tbs.issuer() != tbs.subject() {
        return Err(invalid(
            certificate_path,
            "expected a self-signed certificate",
        ));
    }
    let is_ca = tbs
        .basic_constraints()
        .map_err(|_| invalid(certificate_path, "has invalid basic constraints"))?
        .is_some_and(|constraints| constraints.value.ca);
    if !is_ca {
        return Err(format!(
            "{} is not a CA certificate",
            certificate_path.display()
        ));
    }
    if let Some(key_usage) = tbs
        .key_usage()
        .map_err(|_| invalid(certificate_path, "has an invalid key usage"))?
        && !key_usage.value.key_cert_sign()
    {
        return Err(invalid(
            certificate_path,
            "CA key usage must include keyCertSign",
        ));
    }

    let validity = tbs.validity();
    let now = OffsetDateTime::now_utc();
    if now <= validity.not_before.to_datetime() || now >= validity.not_after.to_datetime() {
        return Err(format!(
            "CA certificate {} is not currently valid",
            certificate_path.display()
        ));
    }

    if tbs.subject_pki.subject_public_key.data != key.public_key_raw() {
        return Err(format!(
            "CA key {} does not match certificate {}",
            key_path.display(),
            certificate_path.display()
        ));
    }
    certificate
        .verify_signature(Some(certificate.public_key()))
        .map_err(|_| invalid(certificate_path, "has an invalid signature"))?;

    Ok(())
}

fn pem_contents(bytes: &[u8], path: &Path, label: &str) -> Result<Pem, String> {
    let reason = format!("expected one {label} PEM block");
    let text = str::from_utf8(bytes).map_err(|_| invalid(path, &reason))?;
    let text = text.strip_suffix('\n').unwrap_or(text);
    let mut ended = false;
    let expected_end = format!("-----END {label}-----");

    for (index, raw_line) in text.split('\n').enumerate() {
        let line = raw_line.strip_suffix('\r').unwrap_or(raw_line);
        if index == 0 {
            let expected_begin = format!("-----BEGIN {label}-----");
            if line != expected_begin {
                return Err(invalid(path, &reason));
            }
        } else if ended || line == expected_end {
            if ended {
                return Err(invalid(path, &reason));
            }
            ended = true;
        } else if line.starts_with("-----") {
            return Err(invalid(path, &reason));
        }
    }

    if !ended {
        return Err(invalid(path, &reason));
    }
    let (rest, pem) = parse_x509_pem(bytes).map_err(|_| invalid(path, &reason))?;
    if !rest.is_empty() || pem.label != label {
        return Err(invalid(path, &reason));
    }
    Ok(pem)
}

fn ensure_complete_der(bytes: &[u8], path: &Path, kind: &str) -> Result<(), String> {
    let (rest, _object) =
        parse_der(bytes).map_err(|_| invalid(path, &format!("expected one complete {kind}")))?;
    if !rest.is_empty() {
        return Err(invalid(path, &format!("expected one complete {kind}")));
    }
    Ok(())
}

fn invalid(path: &Path, reason: &str) -> String {
    format!("{} is not usable: {reason}", path.display())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::TempDir;

    use super::*;

    #[test]
    fn checked_directory_stays_anchored_after_rename_and_symlink_substitution() {
        let root = TempDir::new().expect("create temporary root");
        let requested = root.path().join("ca");
        let directory = open_private_directory(&requested).expect("open private directory");
        let moved = root.path().join("moved");
        fs::rename(&requested, &moved).expect("move checked directory");
        let target = root.path().join("target");
        fs::create_dir(&target).expect("create substitution target");
        std::os::unix::fs::symlink(&target, &requested).expect("substitute directory path");

        create(&directory).expect("create in checked directory");
        assert_eq!(fs::read_dir(&target).expect("read target").count(), 0);
        assert_eq!(
            fs::read_dir(&moved).expect("read moved directory").count(),
            2
        );
        assert!(!path_names_directory(&directory, &requested).expect("compare directory identity"));

        let certificate_path = requested.join(CA_CERTIFICATE);
        let key_path = requested.join(CA_KEY);
        let mut certificate = open_regular_file(&directory, CA_CERTIFICATE, &certificate_path)
            .expect("open anchored certificate")
            .expect("certificate exists");
        let mut key = open_regular_file(&directory, CA_KEY, &key_path)
            .expect("open anchored key")
            .expect("key exists");
        validate(&mut certificate, &mut key, &certificate_path, &key_path)
            .expect("validate anchored material");
    }

    #[test]
    fn certificate_publication_failure_keeps_key_and_existing_certificate() {
        let root = TempDir::new().expect("create temporary root");
        let requested = root.path().join("ca");
        let directory = open_private_directory(&requested).expect("open private directory");
        let certificate_path = requested.join(CA_CERTIFICATE);
        fs::write(&certificate_path, b"another initializer's certificate")
            .expect("publish another certificate");

        let error = create(&directory).expect_err("existing certificate must prevent publication");
        assert!(error.contains("CA publication failed after writing ca.key"));
        assert!(error.contains("inspect the directory"));
        assert_eq!(
            fs::read(&certificate_path).expect("read existing certificate"),
            b"another initializer's certificate"
        );
        assert!(
            fs::read_to_string(requested.join(CA_KEY))
                .expect("read retained key")
                .starts_with("-----BEGIN PRIVATE KEY-----")
        );
        assert_eq!(
            fs::read_dir(&requested).expect("read CA directory").count(),
            2
        );
    }
}

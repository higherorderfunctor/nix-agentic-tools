// cspell:words Zeroizing
//! The CA pair itself: generate one, write a new pair, and validate a pair
//! already on disk.

use std::{
    fs::{self, File},
    os::unix::fs::MetadataExt as _,
    path::Path,
};

use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, IsCa, KeyPair, KeyUsagePurpose,
};
use time::{Duration, OffsetDateTime};
use x509_parser::parse_x509_certificate;
use zeroize::Zeroizing;

use super::{path_error, storage};

const CA_NAME: &str = "airlock local CA";
// A CA serves the session that uses its directory, and a new directory gets a
// new CA; a year outlasts that session without minting a long-lived root.
const CA_VALIDITY: Duration = Duration::days(365);
const CERTIFICATE_MODE: u32 = 0o644;
const CLOCK_SKEW: Duration = Duration::hours(1);
const KEY_MODE: u32 = 0o600;

fn mint_error(error: rcgen::Error) -> String {
    format!("could not generate CA material: {error}")
}

pub(super) fn unpaired(present: &Path, missing: &Path) -> String {
    format!(
        "{} exists without {}; remove it before creating a new CA",
        present.display(),
        missing.display()
    )
}

/// Writes a new pair. If the certificate cannot be written, the key this call
/// created is removed, so a failed create leaves no key behind.
pub(super) fn create(certificate_path: &Path, key_path: &Path) -> Result<(), String> {
    let (certificate, key) = generate()?;
    storage::create(key_path, KEY_MODE, key.as_bytes())
        .map_err(|error| path_error(key_path, error))?;
    if let Err(error) = storage::create(certificate_path, CERTIFICATE_MODE, certificate.as_bytes())
    {
        let _ = fs::remove_file(key_path);
        return Err(path_error(certificate_path, error));
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

pub(super) fn validate(
    certificate_file: &mut File,
    key_file: &mut File,
    certificate_path: &Path,
    key_path: &Path,
) -> Result<(), String> {
    let key_mode = key_file
        .metadata()
        .map_err(|error| path_error(key_path, error))?
        .mode()
        & 0o777;
    if key_mode & 0o077 != 0 {
        return Err(format!(
            "CA key {} must grant no group or other permissions (now {key_mode:04o})",
            key_path.display()
        ));
    }

    let key_bytes = Zeroizing::new(storage::read_file(key_file, key_path)?);
    let key_der = Zeroizing::new(pem_block(&key_bytes, key_path, "PRIVATE KEY")?);
    let key = Zeroizing::new(
        KeyPair::try_from(key_der.as_slice())
            .map_err(|_| invalid(key_path, "expected a PKCS#8 private key"))?,
    );

    let certificate_bytes = storage::read_file(certificate_file, certificate_path)?;
    let certificate_der = pem_block(&certificate_bytes, certificate_path, "CERTIFICATE")?;
    let (certificate_rest, certificate) = parse_x509_certificate(&certificate_der)
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

/// The DER of the single PEM block in `bytes`; another block, a mismatched END
/// label or another label is refused.
fn pem_block(bytes: &[u8], path: &Path, label: &str) -> Result<Vec<u8>, String> {
    let refused = || invalid(path, &format!("expected one {label} PEM block"));
    let blocks = pem::parse_many(bytes).map_err(|_| refused())?;
    let [block] = <[pem::Pem; 1]>::try_from(blocks).map_err(|_| refused())?;
    if block.tag() != label {
        return Err(refused());
    }
    Ok(block.into_contents())
}

fn invalid(path: &Path, reason: &str) -> String {
    format!("{} is not usable: {reason}", path.display())
}

#[cfg(test)]
mod tests {
    use tempfile::TempDir;

    use super::*;
    use crate::ca::{CA_CERTIFICATE, CA_KEY};

    #[test]
    fn failed_certificate_write_removes_the_new_key_and_keeps_the_existing_certificate() {
        let root = TempDir::new().expect("create temporary root");
        let certificate_path = root.path().join(CA_CERTIFICATE);
        let key_path = root.path().join(CA_KEY);
        fs::write(&certificate_path, b"existing certificate").expect("write certificate");

        create(&certificate_path, &key_path).expect_err("an existing certificate stops create");
        assert!(!key_path.exists(), "a failed create left its key behind");
        assert_eq!(
            fs::read(&certificate_path).expect("read existing certificate"),
            b"existing certificate"
        );
    }
}

// cspell:words getuid rustix
mod common;

use std::{
    fs::{self, File},
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    process::Stdio,
    thread,
    time::Duration as StdDuration,
};

use airlock::ca;
use common::{private_root, process::command};
use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa,
    Issuer, KeyPair, KeyUsagePurpose,
};
use tempfile::TempDir;
use time::{Duration, OffsetDateTime};
use x509_parser::pem::parse_x509_pem;

struct Material {
    directory: PathBuf,
    certificate: PathBuf,
    key: PathBuf,
}

impl Material {
    fn new(root: &TempDir) -> Self {
        let directory = root.path().join("ca");
        let certificate = directory.join("ca.pem");
        let key = directory.join("ca.key");
        Self {
            directory,
            certificate,
            key,
        }
    }
}

fn mode(path: &Path) -> u32 {
    fs::metadata(path)
        .expect("read metadata")
        .permissions()
        .mode()
        & 0o777
}

fn set_mode(path: &Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).expect("set mode");
}

fn write_pair(directory: &Path, certificate: &str, key: &str) {
    fs::DirBuilder::new()
        .mode(0o700)
        .create(directory)
        .expect("create CA directory");
    fs::write(directory.join("ca.pem"), certificate).expect("write certificate");
    set_mode(&directory.join("ca.pem"), 0o644);
    fs::write(directory.join("ca.key"), key).expect("write key");
    set_mode(&directory.join("ca.key"), 0o600);
}

fn generated(
    is_ca: bool,
    not_before: OffsetDateTime,
    not_after: OffsetDateTime,
) -> (String, String) {
    let key = KeyPair::generate().expect("generate key");
    let mut parameters = CertificateParams::default();
    parameters.distinguished_name = DistinguishedName::new();
    parameters
        .distinguished_name
        .push(DnType::CommonName, "test certificate");
    parameters.not_before = not_before;
    parameters.not_after = not_after;
    if is_ca {
        parameters.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
        parameters.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    } else {
        parameters.is_ca = IsCa::ExplicitNoCa;
        parameters.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    }

    let certificate = parameters.self_signed(&key).expect("sign test certificate");
    (certificate.pem(), key.serialize_pem())
}

/// A currently valid CA pair signed by its own key, named as issued by
/// `issuer` and carrying `key_usages`, so only those can make init refuse it.
fn ca_with(issuer: &str, key_usages: Vec<KeyUsagePurpose>) -> (String, String) {
    let key = KeyPair::generate().expect("generate key");
    let now = OffsetDateTime::now_utc();
    let mut parameters = CertificateParams::default();
    parameters.distinguished_name = DistinguishedName::new();
    parameters
        .distinguished_name
        .push(DnType::CommonName, "test certificate");
    parameters.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    parameters.key_usages = key_usages;
    parameters.not_before = now - Duration::hours(1);
    parameters.not_after = now + Duration::days(365);
    let mut issuer_parameters = parameters.clone();
    issuer_parameters.distinguished_name = DistinguishedName::new();
    issuer_parameters
        .distinguished_name
        .push(DnType::CommonName, issuer);
    let certificate = parameters
        .signed_by(&key, &Issuer::from_params(&issuer_parameters, &key))
        .expect("sign with the subject key");
    (certificate.pem(), key.serialize_pem())
}

fn wrongly_signed() -> (String, String) {
    let subject_key = KeyPair::generate().expect("generate subject key");
    let signer = KeyPair::generate().expect("generate wrong signer");
    let now = OffsetDateTime::now_utc();
    let mut parameters = CertificateParams::default();
    parameters.distinguished_name = DistinguishedName::new();
    parameters
        .distinguished_name
        .push(DnType::CommonName, "wrongly signed certificate");
    parameters.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    parameters.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    parameters.not_before = now - Duration::hours(1);
    parameters.not_after = now + Duration::days(365);
    let issuer = Issuer::new(parameters.clone(), signer);
    let certificate = parameters
        .signed_by(&subject_key, &issuer)
        .expect("sign with the wrong key");

    (certificate.pem(), subject_key.serialize_pem())
}

fn with_trailing_der(text: &str) -> String {
    let block = pem::parse(text).expect("parse generated PEM");
    let mut der = block.contents().to_vec();
    der.extend_from_slice(&[0, 0]);
    pem::encode(&pem::Pem::new(block.tag(), der))
}

fn entries(directory: &Path) -> usize {
    fs::read_dir(directory).expect("read CA directory").count()
}

#[test]
fn init_generates_a_valid_private_pair_and_reuses_it() {
    let root = private_root();
    let material = Material::new(&root);
    let returned = ca::init(&material.directory).expect("create CA");
    assert_eq!(returned, material.certificate);

    let metadata = fs::symlink_metadata(&material.directory).expect("directory metadata");
    assert_eq!(mode(&material.directory), 0o700);
    assert_eq!(
        metadata.uid(),
        rustix::process::getuid().as_raw(),
        "another user owns the CA directory"
    );
    assert_eq!(mode(&material.key), 0o600);
    assert_eq!(mode(&material.certificate), 0o644);
    assert!(
        fs::read_to_string(&material.key)
            .expect("read key")
            .starts_with("-----BEGIN PRIVATE KEY-----")
    );

    let certificate_bytes = fs::read(&material.certificate).expect("read certificate DER");
    let (rest, certificate_pem) =
        parse_x509_pem(&certificate_bytes).expect("parse generated certificate PEM");
    assert!(rest.is_empty());
    let certificate = certificate_pem
        .parse_x509()
        .expect("parse generated certificate DER");
    let constraints = certificate
        .tbs_certificate
        .basic_constraints()
        .expect("parse basic constraints")
        .expect("basic constraints are present");
    assert!(constraints.value.ca);
    assert!(
        certificate
            .tbs_certificate
            .key_usage()
            .expect("parse key usage")
            .expect("key usage is present")
            .value
            .key_cert_sign()
    );
    assert_eq!(
        certificate.tbs_certificate.issuer(),
        certificate.tbs_certificate.subject()
    );
    certificate
        .verify_signature(None)
        .expect("verify self-signature");

    let original_certificate = fs::read(&material.certificate).expect("read original certificate");
    let original_key = fs::read(&material.key).expect("read original key");
    let reused = ca::init(&material.directory).expect("reuse CA");
    assert_eq!(reused, material.certificate);
    assert_eq!(
        fs::read(&material.certificate).expect("read reused certificate"),
        original_certificate,
        "init replaced the certificate"
    );
    assert_eq!(
        fs::read(&material.key).expect("read reused key"),
        original_key,
        "init replaced the key"
    );
    assert_eq!(entries(&material.directory), 2);
}

#[test]
fn ca_init_cli_prints_only_the_public_certificate_path() {
    let root = private_root();
    let material = Material::new(&root);
    let output = command()
        .arg("ca")
        .arg("init")
        .arg(&material.directory)
        .output()
        .expect("run Airlock CA init");

    assert!(output.status.success(), "output: {output:?}");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert_eq!(
        stdout,
        format!("{}\n", material.certificate.display()),
        "CA init must expose only the public certificate path"
    );
    assert!(output.stderr.is_empty(), "unexpected stderr: {output:?}");
    assert_eq!(mode(&material.key), 0o600);
}

// The test holds the lock an init in progress would hold. Without the lock,
// both runs finish before it is released, or one finds the other's half-made
// pair.
#[test]
fn concurrent_inits_wait_for_the_lock_and_share_one_valid_pair() {
    let root = private_root();
    let material = Material::new(&root);
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&material.directory)
        .expect("create CA directory");
    let held = File::open(&material.directory).expect("open CA directory");
    held.lock().expect("hold the CA directory lock");
    let mut runs: Vec<_> = (0..2)
        .map(|_| {
            command()
                .arg("ca")
                .arg("init")
                .arg(&material.directory)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .expect("start Airlock CA init")
        })
        .collect();
    thread::sleep(StdDuration::from_millis(300));
    for run in &mut runs {
        assert!(
            run.try_wait().expect("check CA init").is_none(),
            "init finished while another held the lock"
        );
    }
    assert_eq!(entries(&material.directory), 0);

    drop(held);
    for run in runs {
        let output = run.wait_with_output().expect("wait for CA init");
        assert!(output.status.success(), "output: {output:?}");
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            format!("{}\n", material.certificate.display())
        );
    }
    let certificate = fs::read(&material.certificate).expect("read certificate");
    ca::init(&material.directory).expect("the shared pair is valid");
    assert_eq!(
        fs::read(&material.certificate).expect("reread certificate"),
        certificate
    );
    assert_eq!(entries(&material.directory), 2);
}

#[test]
fn init_refuses_unusable_existing_material_without_replacing_it() {
    let now = OffsetDateTime::now_utc();
    let valid = generated(true, now - Duration::hours(1), now + Duration::days(365));
    let wrong_key = KeyPair::generate().expect("generate mismatch key");
    let invalid_signature = wrongly_signed();
    let non_ca = generated(false, now - Duration::hours(1), now + Duration::days(365));
    let expired = generated(true, now - Duration::hours(2), now - Duration::hours(1));
    let future = generated(true, now + Duration::hours(1), now + Duration::days(365));
    let without_key_cert_sign = ca_with("test certificate", vec![KeyUsagePurpose::CrlSign]);
    let foreign_issuer = ca_with(
        "another issuer",
        vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign],
    );

    // The same fixture with its own name as issuer and keyCertSign is
    // accepted, so each refusal below comes from the field it varies.
    let root = private_root();
    let material = Material::new(&root);
    let control = ca_with(
        "test certificate",
        vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign],
    );
    write_pair(&material.directory, &control.0, &control.1);
    ca::init(&material.directory).expect("accept the control pair");

    let cases: [(String, String, &str); 12] = [
        (
            valid.0.clone(),
            wrong_key.serialize_pem(),
            "does not match certificate",
        ),
        (non_ca.0, non_ca.1, "is not a CA certificate"),
        (
            invalid_signature.0,
            invalid_signature.1,
            "has an invalid signature",
        ),
        (expired.0, expired.1, "is not currently valid"),
        (future.0, future.1, "is not currently valid"),
        (
            without_key_cert_sign.0,
            without_key_cert_sign.1,
            "CA key usage must include keyCertSign",
        ),
        (
            foreign_issuer.0,
            foreign_issuer.1,
            "expected a self-signed certificate",
        ),
        (
            valid.0.replace("END CERTIFICATE", "END PRIVATE KEY"),
            valid.1.clone(),
            "ca.pem is not usable: expected one CERTIFICATE PEM block",
        ),
        (
            valid.0.clone(),
            valid.1.replace("END PRIVATE KEY", "END CERTIFICATE"),
            "ca.key is not usable: expected one PRIVATE KEY PEM block",
        ),
        (
            with_trailing_der(&valid.0),
            valid.1.clone(),
            "ca.pem is not usable: expected one complete X.509 certificate",
        ),
        (
            valid.0.clone(),
            with_trailing_der(&valid.1),
            "ca.key is not usable: expected a PKCS#8 private key",
        ),
        (
            "not a certificate".to_owned(),
            valid.1,
            "ca.pem is not usable: expected one CERTIFICATE PEM block",
        ),
    ];

    for (index, (certificate, key, expected_error)) in cases.into_iter().enumerate() {
        let root = private_root();
        let material = Material::new(&root);
        write_pair(&material.directory, &certificate, &key);
        let original_certificate = fs::read(&material.certificate).expect("read certificate");
        let original_key = fs::read(&material.key).expect("read key");
        let error = ca::init(&material.directory)
            .expect_err("unusable CA material must be refused")
            .to_string();

        assert!(
            error.contains(expected_error),
            "case {index}: expected {expected_error:?}, got {error:?}"
        );
        assert_eq!(
            fs::read(&material.certificate).expect("reread certificate"),
            original_certificate,
            "case {index}: certificate was replaced"
        );
        assert_eq!(
            fs::read(&material.key).expect("reread key"),
            original_key,
            "case {index}: key was replaced"
        );
        assert_eq!(entries(&material.directory), 2, "case {index}");
    }
}

#[test]
fn init_refuses_partial_exposed_and_redirected_ca_material() {
    let root = private_root();
    let material = Material::new(&root);
    ca::init(&material.directory).expect("create CA");
    let certificate = fs::read(&material.certificate).expect("read certificate");
    let key = fs::read(&material.key).expect("read key");

    fs::remove_file(&material.certificate).expect("remove certificate");
    let error = ca::init(&material.directory)
        .expect_err("certificate-only material must be refused")
        .to_string();
    assert!(
        error.contains("exists without") && error.contains("ca.pem"),
        "{error}"
    );
    assert_eq!(
        fs::read(&material.key).expect("reread key"),
        key,
        "refusal replaced the existing key"
    );

    fs::write(&material.certificate, &certificate).expect("restore certificate");
    fs::remove_file(&material.key).expect("remove key");
    let error = ca::init(&material.directory)
        .expect_err("key-only material must be refused")
        .to_string();
    assert!(
        error.contains("exists without") && error.contains("ca.key"),
        "{error}"
    );
    assert_eq!(
        fs::read(&material.certificate).expect("reread certificate"),
        certificate,
        "refusal replaced the existing certificate"
    );

    fs::write(&material.key, &key).expect("restore key");
    for exposed in [0o640, 0o604, 0o610] {
        set_mode(&material.key, exposed);
        let error = ca::init(&material.directory)
            .expect_err("exposed key must be refused")
            .to_string();
        assert!(
            error.contains("must grant no group or other permissions") && error.contains("ca.key"),
            "{exposed:o}: {error}"
        );
    }
    set_mode(&material.key, 0o600);

    for exposed in [0o750, 0o701] {
        set_mode(&material.directory, exposed);
        let error = ca::init(&material.directory)
            .expect_err("exposed directory must be refused")
            .to_string();
        assert!(
            error.contains("cannot hold the CA: it grants group or other permissions"),
            "{exposed:o}: {error}"
        );
    }
    set_mode(&material.directory, 0o700);

    let target = root.path().join("target");
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&target)
        .expect("create target directory");
    let linked = root.path().join("linked-ca");
    std::os::unix::fs::symlink(&target, &linked).expect("link CA directory");
    for suffix in ["", "/", "/.", "/./"] {
        let requested = PathBuf::from(format!("{}{suffix}", linked.display()));
        let error = ca::init(&requested).expect_err("symlinked directory must be refused");
        assert!(
            error.contains("cannot hold the CA: it is not a directory"),
            "{requested:?}: {error}"
        );
    }
    assert_eq!(entries(&target), 0, "symlinked init followed a link");

    let moved = root.path().join("moved-ca.pem");
    fs::rename(&material.certificate, &moved).expect("move certificate");
    std::os::unix::fs::symlink(&moved, &material.certificate).expect("link certificate");
    let error = ca::init(&material.directory)
        .expect_err("symlinked certificate must be refused")
        .to_string();
    assert!(
        error.contains("must be a regular file, not a symlink") && error.contains("ca.pem"),
        "{error}"
    );
    assert!(
        fs::symlink_metadata(&material.certificate)
            .expect("certificate metadata")
            .file_type()
            .is_symlink(),
        "refusal replaced the certificate symlink"
    );
}

#[test]
fn init_accepts_modes_stricter_than_0700_and_0600() {
    let root = private_root();
    let material = Material::new(&root);
    ca::init(&material.directory).expect("create CA");
    set_mode(&material.key, 0o400);
    set_mode(&material.directory, 0o500);
    let reused = ca::init(&material.directory);
    set_mode(&material.directory, 0o700);
    assert_eq!(reused.expect("reuse stricter modes"), material.certificate);
}

#[test]
fn init_refuses_a_parent_others_can_write_before_creating_anything() {
    let root = private_root();
    let parent = root.path().join("parent");
    fs::create_dir(&parent).expect("create parent");
    let directory = parent.join("ca");
    for writable in [0o770, 0o707, 0o1777] {
        set_mode(&parent, writable);
        let error = ca::init(&directory).expect_err("writable parent must be refused");
        assert!(
            error.contains("is writable by group or others") && error.contains("parent"),
            "{writable:o}: {error}"
        );
        assert!(!directory.exists(), "{writable:o}: init created the CA");
    }
    set_mode(&parent, 0o755);
    ca::init(&directory).expect("a parent only its owner writes is accepted");
}

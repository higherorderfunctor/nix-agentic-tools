// cspell:words alpn
// cspell:words getuid rustix
mod common;

use std::{
    fs::{self, File},
    io::Cursor,
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Output, Stdio},
    sync::Arc,
    thread,
    time::Duration as StdDuration,
};

use airlock::ca::{self, Instance, RuntimeBase};
use common::{
    private_root,
    process::{command, in_runtime},
    replaceable_ancestor, trusted_root,
};
use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa,
    Issuer, KeyPair, KeyUsagePurpose,
};
use rustls::{
    ClientConfig, ClientConnection, RootCertStore, ServerConfig, ServerConnection,
    pki_types::ServerName,
};
use tempfile::TempDir;
use time::{Duration, OffsetDateTime};
use x509_parser::pem::parse_x509_pem;

/// The default instance's CA under `XDG_RUNTIME_DIR` set to a private root.
struct Material {
    base: RuntimeBase,
    directory: PathBuf,
    certificate: PathBuf,
    key: PathBuf,
}

impl Material {
    fn new(root: &TempDir) -> Self {
        let directory = root.path().join("airlock/default");
        let certificate = directory.join("ca.pem");
        let key = directory.join("ca.key");
        Self {
            base: RuntimeBase::Xdg(root.path().to_owned()),
            directory,
            certificate,
            key,
        }
    }

    fn init(&self) -> Result<PathBuf, String> {
        ca::init(&self.base, &Instance::default())
    }

    fn authority<const N: usize>(&self, names: [&str; N]) -> Result<ca::Authority, String> {
        ca::Authority::open(&self.base, &Instance::default(), names)
    }

    /// Creates the instance directory as `init` would, with nothing in it.
    fn create_directory(&self) {
        fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(&self.directory)
            .expect("create CA directory");
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

fn write_pair(material: &Material, certificate: &str, key: &str) {
    material.create_directory();
    fs::write(&material.certificate, certificate).expect("write certificate");
    set_mode(&material.certificate, 0o644);
    fs::write(&material.key, key).expect("write key");
    set_mode(&material.key, 0o600);
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
    let returned = material.init().expect("create CA");
    assert_eq!(returned, material.certificate);

    let metadata = fs::symlink_metadata(&material.directory).expect("directory metadata");
    assert_eq!(mode(&material.directory), 0o700);
    assert_eq!(mode(&root.path().join("airlock")), 0o700);
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
    let reused = material.init().expect("reuse CA");
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
    for (arguments, directory) in [
        (vec![], material.directory.clone()),
        (
            vec!["--instance", "work_2-b"],
            root.path().join("airlock/work_2-b"),
        ),
    ] {
        let output = in_runtime(root.path())
            .args(["ca", "init"])
            .args(&arguments)
            .output()
            .expect("run Airlock CA init");

        assert!(output.status.success(), "{arguments:?}: {output:?}");
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(
            stdout,
            format!("{}\n", directory.join("ca.pem").display()),
            "CA init must expose only the instance's public certificate path"
        );
        assert!(output.stderr.is_empty(), "unexpected stderr: {output:?}");
        assert_eq!(mode(&directory.join("ca.key")), 0o600);
    }
}

#[test]
fn ca_init_refuses_an_unset_or_empty_runtime_directory_without_a_fallback() {
    let root = private_root();
    for runtime in [None, Some("")] {
        let mut init = command();
        init.args(["ca", "init"])
            .env_remove("AIRLOCK_HOME")
            .env("TMPDIR", root.path());
        match runtime {
            Some(value) => init.env("XDG_RUNTIME_DIR", value),
            None => init.env_remove("XDG_RUNTIME_DIR"),
        };
        let output = init.output().expect("run Airlock CA init");
        assert!(!output.status.success(), "{runtime:?}: {output:?}");
        assert!(
            String::from_utf8_lossy(&output.stderr).contains("XDG_RUNTIME_DIR is unset or empty"),
            "{runtime:?}: {output:?}"
        );
        assert_eq!(
            entries(root.path()),
            0,
            "{runtime:?}: init fell back to TMPDIR"
        );
    }
}

// Resolved against each process's working directory, a relative value would
// give `ca init` and `serve` started in different directories different CAs.
#[test]
fn ca_init_refuses_a_relative_runtime_directory() {
    let root = private_root();
    let output = in_runtime(Path::new("relative"))
        .args(["ca", "init"])
        .current_dir(root.path())
        .output()
        .expect("run Airlock CA init");
    assert!(!output.status.success(), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("XDG_RUNTIME_DIR must be an absolute path"),
        "{output:?}"
    );
    assert_eq!(entries(root.path()), 0, "init created a relative directory");
}

#[test]
fn ca_init_refuses_a_relative_airlock_home() {
    let root = private_root();
    let output = command()
        .args(["ca", "init"])
        .env("AIRLOCK_HOME", "relative")
        .current_dir(root.path())
        .output()
        .expect("run Airlock CA init");
    assert!(!output.status.success(), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("AIRLOCK_HOME must be an absolute path"),
        "{output:?}"
    );
    assert_eq!(entries(root.path()), 0, "init created a relative directory");
}

// The test holds the lock an init in progress would hold. Without the lock,
// both runs finish before it is released, or one finds the other's half-made
// pair.
#[test]
fn concurrent_inits_wait_for_the_lock_and_share_one_valid_pair() {
    let root = private_root();
    let material = Material::new(&root);
    material.create_directory();
    let held = File::open(&material.directory).expect("open CA directory");
    held.lock().expect("hold the CA directory lock");
    let mut runs: Vec<_> = (0..2)
        .map(|_| {
            in_runtime(root.path())
                .args(["ca", "init"])
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
    material.init().expect("the shared pair is valid");
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
    write_pair(&material, &control.0, &control.1);
    material.init().expect("accept the control pair");

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
        write_pair(&material, &certificate, &key);
        let original_certificate = fs::read(&material.certificate).expect("read certificate");
        let original_key = fs::read(&material.key).expect("read key");
        let error = material
            .init()
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
    material.init().expect("create CA");
    let certificate = fs::read(&material.certificate).expect("read certificate");
    let key = fs::read(&material.key).expect("read key");

    fs::remove_file(&material.certificate).expect("remove certificate");
    let error = material
        .init()
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
    let error = material
        .init()
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
        let error = material
            .init()
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
        let error = material
            .init()
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
    let other = root.path().join("airlock/other");
    std::os::unix::fs::symlink(&target, &other).expect("link CA directory");
    let error = ca::init(&material.base, &"other".parse().expect("valid instance"))
        .expect_err("symlinked directory must be refused");
    assert!(
        error.contains("cannot hold the CA: it is not a directory"),
        "{error}"
    );
    assert_eq!(entries(&target), 0, "symlinked init followed a link");

    let moved = root.path().join("moved-ca.pem");
    fs::rename(&material.certificate, &moved).expect("move certificate");
    std::os::unix::fs::symlink(&moved, &material.certificate).expect("link certificate");
    let error = material
        .init()
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
    material.init().expect("create CA");
    set_mode(&material.key, 0o400);
    set_mode(&material.directory, 0o500);
    let reused = material.init();
    set_mode(&material.directory, 0o700);
    assert_eq!(reused.expect("reuse stricter modes"), material.certificate);
}

// Only `XDG_RUNTIME_DIR` itself is trusted, so `airlock` below it is opened
// without following a link: through one into a directory others can write,
// another user could replace the instance directory after init checked it.
#[test]
fn init_refuses_a_symlinked_airlock_directory_under_xdg_runtime_dir() {
    let root = private_root();
    let shared = root.path().join("shared");
    fs::create_dir(&shared).expect("create shared directory");
    set_mode(&shared, 0o777);
    let link = root.path().join("airlock");
    std::os::unix::fs::symlink(&shared, &link).expect("link the shared directory");

    let output = in_runtime(root.path())
        .args(["ca", "init"])
        .output()
        .expect("run Airlock CA init");
    assert!(!output.status.success(), "{output:?}");
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        format!(
            "airlock: {} cannot hold {}: it is not a directory\n",
            link.display(),
            link.join("default").display()
        )
    );
    assert_eq!(
        entries(&shared),
        0,
        "init created a directory through a link"
    );
}

/// `ca <subcommand>` with `AIRLOCK_HOME` set to `home` and an
/// `XDG_RUNTIME_DIR` it must not use.
fn ca_in_home(root: &TempDir, home: &Path, subcommand: &str) -> Output {
    let runtime = root.path().join("xdg");
    fs::create_dir_all(&runtime).expect("create unused runtime directory");
    let output = command()
        .args(["ca", subcommand])
        .env("AIRLOCK_HOME", home)
        .env("XDG_RUNTIME_DIR", &runtime)
        .output()
        .expect("run Airlock CA");
    assert_eq!(
        entries(&runtime),
        0,
        "AIRLOCK_HOME did not replace XDG_RUNTIME_DIR"
    );
    output
}

/// The directory a refusal names as unable to hold `directory`.
fn refused_ancestor(output: &Output, directory: &Path) -> Option<PathBuf> {
    let stderr = String::from_utf8_lossy(&output.stderr);
    let refused = stderr
        .strip_prefix("airlock: ")?
        .strip_suffix('\n')?
        .split_once(&format!(" cannot hold {}: it ", directory.display()))?
        .0;
    Some(PathBuf::from(refused))
}

/// Init under `home` succeeds in its canonical runtime directory when nothing
/// above `root` is replaceable, and otherwise refuses exactly the nearest
/// replaceable directory: a build sandbox or a shared /tmp can hold the root.
fn assert_home_accepted(root: &TempDir, home: &Path, canonical_home: &Path) {
    let directory = canonical_home.join("runtime/default");
    let output = ca_in_home(root, home, "init");
    match replaceable_ancestor(root.path()) {
        None => {
            assert!(output.status.success(), "{output:?}");
            assert_eq!(
                String::from_utf8_lossy(&output.stdout),
                format!("{}\n", directory.join("ca.pem").display()),
                "init must use the canonical path"
            );
            assert_eq!(mode(&directory), 0o700);
            assert_eq!(mode(&directory.join("ca.key")), 0o600);
        }
        Some(replaceable) => assert_eq!(
            refused_ancestor(&output, &directory),
            Some(replaceable),
            "{output:?}"
        ),
    }
}

/// `root/shared/private`, a private directory inside a shared one.
fn shared_with_private(root: &TempDir) -> (PathBuf, PathBuf) {
    let shared = root.path().join("shared");
    let private = shared.join("private");
    fs::DirBuilder::new()
        .mode(0o700)
        .recursive(true)
        .create(&private)
        .expect("create private directory in a shared one");
    (shared, private)
}

// The private directory between the shared one and AIRLOCK_HOME passes, so a
// check of only the nearest existing directory accepts this path.
#[test]
fn airlock_home_refuses_an_ancestor_others_can_write_before_creating_anything() {
    let root = trusted_root();
    let (shared, private) = shared_with_private(&root);
    let home = private.join("home");
    let canonical_shared = fs::canonicalize(&shared).expect("canonical shared directory");
    let canonical_home = fs::canonicalize(&private)
        .expect("canonical private directory")
        .join("home");
    for writable in [0o770, 0o707, 0o1777] {
        set_mode(&shared, writable);
        let output = ca_in_home(&root, &home, "init");
        assert!(!output.status.success(), "{writable:o}: {output:?}");
        assert_eq!(
            refused_ancestor(&output, &canonical_home.join("runtime/default")),
            Some(canonical_shared.clone()),
            "{writable:o}: {output:?}"
        );
        assert!(
            String::from_utf8_lossy(&output.stderr).contains("is writable by group or others"),
            "{writable:o}: {output:?}"
        );
        assert_eq!(
            entries(&private),
            0,
            "{writable:o}: init created a directory"
        );
    }
    set_mode(&shared, 0o700);
    assert_home_accepted(&root, &home, &canonical_home);
}

// The link sits in the private root, and the directory it names is private
// too: only the shared directory above that target makes the path
// replaceable, so a walk of the path as written accepts it.
#[test]
fn airlock_home_refuses_a_symlinked_ancestor_that_resolves_into_a_shared_directory() {
    let root = private_root();
    let (shared, private) = shared_with_private(&root);
    set_mode(&shared, 0o770);
    let link = root.path().join("link");
    std::os::unix::fs::symlink(&private, &link).expect("link the private directory");
    let canonical_shared = fs::canonicalize(&shared).expect("canonical shared directory");

    let output = ca_in_home(&root, &link.join("home"), "init");
    assert!(!output.status.success(), "{output:?}");
    assert_eq!(
        refused_ancestor(
            &output,
            &canonical_shared.join("private/home/runtime/default")
        ),
        Some(canonical_shared.clone()),
        "{output:?}"
    );
    assert_eq!(entries(&private), 0, "init created a directory");
}

// Through a link to a private directory, the path as written and its canonical
// form name the same files, so only the printed path tells a resolver that
// keeps the written path apart from one that uses the canonical path.
#[test]
fn airlock_home_creates_and_reports_its_canonical_runtime_directory() {
    let root = trusted_root();
    let private = root.path().join("private");
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&private)
        .expect("create private directory");
    let link = root.path().join("link");
    std::os::unix::fs::symlink(&private, &link).expect("link the private directory");
    let canonical_home = fs::canonicalize(&private)
        .expect("canonical private directory")
        .join("home");
    assert_home_accepted(&root, &link.join("home"), &canonical_home);
}

// Only `AIRLOCK_HOME` is canonicalized, so `runtime/other` is opened without
// following its link: resolved as part of the base, instance `other` would
// reuse instance `default`'s CA.
#[test]
fn airlock_home_refuses_a_symlinked_instance_directory() {
    let root = trusted_root();
    let home = root.path().join("home");
    let canonical_home = fs::canonicalize(root.path())
        .expect("canonical root")
        .join("home");
    let output = ca_in_home(&root, &home, "init");
    if let Some(replaceable) = replaceable_ancestor(root.path()) {
        // Every path here is refused before its instance directory is read.
        assert_eq!(
            refused_ancestor(&output, &canonical_home.join("runtime/default")),
            Some(replaceable),
            "{output:?}"
        );
        return;
    }
    assert!(output.status.success(), "{output:?}");
    let default = canonical_home.join("runtime/default");
    let certificate = fs::read(default.join("ca.pem")).expect("read certificate");
    let key = fs::read(default.join("ca.key")).expect("read key");
    let other = home.join("runtime/other");
    std::os::unix::fs::symlink("default", &other).expect("link the other instance");

    let output = command()
        .args(["ca", "init", "--instance", "other"])
        .env("AIRLOCK_HOME", &home)
        .output()
        .expect("run Airlock CA init");
    assert!(!output.status.success(), "{output:?}");
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        format!(
            "airlock: {} cannot hold the CA: it is not a directory\n",
            canonical_home.join("runtime/other").display()
        )
    );
    assert_eq!(
        fs::read(default.join("ca.pem")).expect("reread"),
        certificate
    );
    assert_eq!(fs::read(default.join("ca.key")).expect("reread"), key);
    assert_eq!(entries(&default), 2, "init changed the linked instance");
}

// An instance directory that already exists names the same path as one init
// is about to create, with no trailing separator.
#[test]
fn airlock_home_names_an_existing_instance_directory_without_a_trailing_slash() {
    let root = trusted_root();
    let (shared, private) = shared_with_private(&root);
    let directory = private.join("home/runtime/default");
    fs::DirBuilder::new()
        .mode(0o700)
        .recursive(true)
        .create(&directory)
        .expect("create the instance directory");
    set_mode(&shared, 0o770);
    let output = ca_in_home(&root, &private.join("home"), "init");
    set_mode(&shared, 0o700);
    assert!(!output.status.success(), "{output:?}");
    assert_eq!(
        refused_ancestor(
            &output,
            &fs::canonicalize(&directory).expect("canonical instance directory")
        ),
        Some(fs::canonicalize(&shared).expect("canonical shared directory")),
        "{output:?}"
    );
}

// Client trust reads the CA through this path, so a walk or canonical form it
// skipped would let a client trust a CA that init refuses to create.
#[test]
fn ca_directory_resolves_and_refuses_as_init_does_without_creating_anything() {
    let root = trusted_root();
    let output = in_runtime(root.path())
        .args(["ca", "directory", "--instance", "work"])
        .output()
        .expect("run Airlock CA directory");
    assert!(output.status.success(), "{output:?}");
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        format!("{}\n", root.path().join("airlock/work").display())
    );
    assert_eq!(entries(root.path()), 0, "CA directory created a directory");

    let (shared, private) = shared_with_private(&root);
    let link = root.path().join("link");
    std::os::unix::fs::symlink(&private, &link).expect("link the private directory");
    let canonical_shared = fs::canonicalize(&shared).expect("canonical shared directory");
    let directory = canonical_shared.join("private/home/runtime/default");
    set_mode(&shared, 0o770);
    let output = ca_in_home(&root, &link.join("home"), "directory");
    assert!(!output.status.success(), "{output:?}");
    assert_eq!(
        refused_ancestor(&output, &directory),
        Some(canonical_shared.clone()),
        "{output:?}"
    );

    set_mode(&shared, 0o700);
    let output = ca_in_home(&root, &link.join("home"), "directory");
    match replaceable_ancestor(root.path()) {
        None => assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            format!("{}\n", directory.display()),
            "{output:?}"
        ),
        Some(replaceable) => assert_eq!(
            refused_ancestor(&output, &directory),
            Some(replaceable),
            "{output:?}"
        ),
    }
    assert_eq!(entries(&private), 0, "CA directory created a directory");

    let runtime = private_root();
    let target = runtime.path().join("target");
    fs::create_dir(&target).expect("create target directory");
    let link = runtime.path().join("airlock");
    std::os::unix::fs::symlink(&target, &link).expect("link the airlock directory");
    let output = in_runtime(runtime.path())
        .args(["ca", "directory"])
        .output()
        .expect("run Airlock CA directory");
    assert!(!output.status.success(), "{output:?}");
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        format!(
            "airlock: {} cannot hold {}: it is not a directory\n",
            link.display(),
            link.join("default").display()
        )
    );
}

// Created one by one, `missing/..` would climb above the checked directory
// into one nothing checked.
#[test]
fn airlock_home_refuses_a_parent_component_below_a_missing_directory() {
    let root = private_root();
    let home = root.path().join("missing/../home");
    let output = ca_in_home(&root, &home, "init");
    assert!(!output.status.success(), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("`..` follows a missing directory"),
        "{output:?}"
    );
    assert_eq!(
        entries(root.path()),
        1,
        "init created a directory: {output:?}"
    );
}

#[test]
fn an_empty_airlock_home_leaves_xdg_runtime_dir_in_place() {
    let root = private_root();
    let material = Material::new(&root);
    let output = in_runtime(root.path())
        .args(["ca", "init"])
        .env("AIRLOCK_HOME", "")
        .output()
        .expect("run Airlock CA init");
    assert!(output.status.success(), "{output:?}");
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        format!("{}\n", material.certificate.display())
    );
}

fn served_leaf(authority: &ca::Authority, host: &str, ca_der: Vec<u8>) -> Vec<u8> {
    let leaf = authority.leaf_for(host).expect("get selected leaf");
    let config =
        ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .expect("select protocols")
            .with_no_client_auth()
            .with_single_cert(vec![leaf.certificate.clone()], leaf.key.clone_key().into())
            .expect("leaf key matches its certificate");
    let mut roots = RootCertStore::empty();
    roots.add(ca_der.into()).expect("trust fixture CA");
    let client_config =
        ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .expect("select protocols")
            .with_root_certificates(roots)
            .with_no_client_auth();
    let mut client = ClientConnection::new(
        Arc::new(client_config),
        ServerName::try_from(host.to_owned()).expect("fixture DNS name"),
    )
    .expect("create TLS client");
    let mut server = ServerConnection::new(Arc::new(config)).expect("create TLS server");
    for _ in 0..8 {
        let mut bytes = Vec::new();
        client.write_tls(&mut bytes).expect("write client TLS");
        server
            .read_tls(&mut Cursor::new(bytes))
            .expect("read client TLS");
        server.process_new_packets().expect("process client TLS");
        let mut bytes = Vec::new();
        server.write_tls(&mut bytes).expect("write server TLS");
        client
            .read_tls(&mut Cursor::new(bytes))
            .expect("read server TLS");
        client.process_new_packets().expect("verify server TLS");
        if !client.is_handshaking() && !server.is_handshaking() {
            return client.peer_certificates().expect("server certificate")[0].to_vec();
        }
    }
    panic!("TLS fixture handshake did not complete");
}

#[test]
fn authority_reuses_the_initialized_ca_and_serves_only_exact_selected_dns_leaves() {
    let root = private_root();
    let material = Material::new(&root);
    let names = ["api.example.test", "files.example.test"];
    material.init().expect("create CA");
    let authority = material.authority(names).expect("open runtime CA");
    let ca_bytes = fs::read(&material.certificate).expect("read public CA");
    let (_, ca_pem) = parse_x509_pem(&ca_bytes).expect("parse CA PEM");
    let ca_certificate = ca_pem.parse_x509().expect("parse CA DER");
    for host in names {
        let leaf_der = served_leaf(&authority, host, ca_pem.contents.clone());
        let (_, leaf) = x509_parser::parse_x509_certificate(&leaf_der).expect("parse leaf");
        let san = leaf
            .subject_alternative_name()
            .expect("parse SAN")
            .expect("leaf SAN");
        assert_eq!(
            san.value.general_names,
            vec![x509_parser::extensions::GeneralName::DNSName(host)]
        );
        assert_eq!(leaf.issuer(), ca_certificate.subject());
        leaf.verify_signature(Some(ca_certificate.public_key()))
            .expect("verify leaf signature");
        let now = OffsetDateTime::now_utc();
        assert!(leaf.validity().not_before.to_datetime() <= now);
        assert!(
            (leaf.validity().not_after.to_datetime() - now - Duration::days(7)).abs()
                < Duration::seconds(5)
        );
    }
    for host in [
        "example.test",
        "other.example.test",
        "API.example.test",
        "api.example.test.attacker.test",
    ] {
        assert!(
            authority.leaf_for(host).is_err(),
            "accepted unselected {host}"
        );
    }
    let key = fs::read(&material.key).expect("read initial key");
    material.authority(names).expect("reopen runtime CA");
    assert_eq!(fs::read(&material.key).expect("read reused key"), key);
    assert_eq!(
        fs::read(&material.certificate).expect("read reused certificate"),
        ca_bytes
    );
    assert_eq!(
        fs::read_dir(&material.directory)
            .expect("CA directory")
            .count(),
        2
    );
}

#[test]
fn authority_refuses_invalid_names_and_never_creates_a_missing_ca() {
    let root = private_root();
    let material = Material::new(&root);
    material.init().expect("create CA");
    for name in ["*.example.test", "127.0.0.1", "bad/name", ""] {
        assert!(material.authority([name]).is_err(), "accepted {name}");
    }

    let instance = "missing".parse().expect("valid instance");
    let missing = root.path().join("airlock/missing");
    let open = || {
        ca::Authority::open(&material.base, &instance, ["api.example.test"])
            .err()
            .expect("a missing CA must be refused")
    };
    let instruction = format!(
        "{} must hold ca.pem and ca.key; create them with `airlock ca init --instance missing`",
        missing.display()
    );
    let error = open();
    assert!(error.contains(&instruction), "{error}");
    assert!(!missing.exists(), "opening created a CA directory");

    fs::DirBuilder::new()
        .mode(0o700)
        .create(&missing)
        .expect("create empty CA directory");
    let error = open();
    assert!(error.contains(&instruction), "{error}");
    assert_eq!(entries(&missing), 0, "opening created CA material");
}

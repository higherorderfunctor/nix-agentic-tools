// cspell:words alpn
// cspell:words getuid rustix
use std::{
    fs,
    io::Cursor,
    os::unix::{
        ffi::OsStrExt,
        fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    process::Command,
    sync::Arc,
};

use airlock::ca;
use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa,
    Issuer, KeyPair, KeyUsagePurpose,
};
use rustls::{
    ClientConfig, ClientConnection, RootCertStore, ServerConnection, pki_types::ServerName,
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

fn write_pair(directory: &Path, certificate: &str, key: &str) {
    fs::DirBuilder::new()
        .mode(0o700)
        .create(directory)
        .expect("create CA directory");
    fs::write(directory.join("ca.pem"), certificate).expect("write certificate");
    fs::set_permissions(directory.join("ca.pem"), fs::Permissions::from_mode(0o644))
        .expect("set certificate mode");
    fs::write(directory.join("ca.key"), key).expect("write key");
    fs::set_permissions(directory.join("ca.key"), fs::Permissions::from_mode(0o600))
        .expect("set key mode");
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

fn assert_no_temporary_files(directory: &Path) {
    let temporary = fs::read_dir(directory)
        .expect("read CA directory")
        .filter_map(|entry| entry.ok())
        .any(|entry| entry.file_name().as_bytes().starts_with(b".airlock-"));
    assert!(!temporary, "a temporary CA file was left behind");
}

#[test]
fn init_generates_a_valid_private_pair_and_reuses_it() {
    let root = TempDir::new().expect("create temporary root");
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
    assert!(
        fs::read_to_string(&material.certificate)
            .expect("read certificate")
            .starts_with("-----BEGIN CERTIFICATE-----")
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
        "idempotent init rotated the certificate"
    );
    assert_eq!(
        fs::read(&material.key).expect("read reused key"),
        original_key,
        "idempotent init rotated the key"
    );
    assert_no_temporary_files(&material.directory);
}

#[test]
fn ca_init_cli_prints_only_the_public_certificate_path() {
    let root = TempDir::new().expect("create temporary root");
    let material = Material::new(&root);
    let output = Command::new(env!("CARGO_BIN_EXE_airlock"))
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

    let cases: &[(&[&str], &str)] = &[
        (&["ca"], "Usage: airlock ca"),
        (&["ca", "init"], "<DIRECTORY>"),
        (&["ca", "rotate", "unused"], "unrecognized subcommand"),
        (&["ca", "init", "unused", "extra"], "unexpected argument"),
    ];
    for (arguments, expected_error) in cases {
        let output = Command::new(env!("CARGO_BIN_EXE_airlock"))
            .args(*arguments)
            .output()
            .expect("run invalid Airlock CA command");
        assert!(!output.status.success(), "accepted {arguments:?}");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains(expected_error), "{arguments:?}: {stderr}");
    }
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

    let cases: [(String, String, &str); 10] = [
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
            valid.0.replace("END CERTIFICATE", "END PRIVATE KEY"),
            valid.1.clone(),
            "expected one CERTIFICATE PEM block",
        ),
        (
            valid.0.clone(),
            valid.1.replace("END PRIVATE KEY", "END CERTIFICATE"),
            "expected one PRIVATE KEY PEM block",
        ),
        (
            with_trailing_der(&valid.0),
            valid.1.clone(),
            "expected one complete X.509 certificate",
        ),
        (
            valid.0.clone(),
            with_trailing_der(&valid.1),
            "expected one complete PKCS#8 private key",
        ),
        (
            "not a certificate".to_owned(),
            valid.1,
            "expected one CERTIFICATE PEM block",
        ),
    ];

    for (index, (certificate, key, expected_error)) in cases.into_iter().enumerate() {
        let root = TempDir::new().expect("create temporary root");
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
        assert_no_temporary_files(&material.directory);
    }
}

#[test]
fn init_refuses_partial_exposed_and_redirected_ca_material() {
    let root = TempDir::new().expect("create temporary root");
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
    fs::set_permissions(&material.key, fs::Permissions::from_mode(0o640)).expect("expose key");
    let error = ca::init(&material.directory)
        .expect_err("exposed key must be refused")
        .to_string();
    assert!(
        error.contains("must have mode 0600") && error.contains("ca.key"),
        "{error}"
    );
    fs::set_permissions(&material.key, fs::Permissions::from_mode(0o600))
        .expect("restore key mode");

    fs::set_permissions(&material.directory, fs::Permissions::from_mode(0o750))
        .expect("expose directory");
    let error = ca::init(&material.directory)
        .expect_err("exposed directory must be refused")
        .to_string();
    assert!(
        error.contains("must be a directory owned by this user with mode 0700"),
        "{error}"
    );
    fs::set_permissions(&material.directory, fs::Permissions::from_mode(0o700))
        .expect("restore directory mode");

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
            error.contains("must be a directory owned by this user with mode 0700"),
            "{requested:?}: {error}"
        );
    }
    assert_eq!(
        fs::read_dir(&target).expect("read target").count(),
        0,
        "symlinked init followed a link"
    );

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

fn served_leaf(authority: &ca::Authority, host: &str, ca_der: Vec<u8>) -> Vec<u8> {
    let config = authority.config_for(host).expect("get selected leaf");
    assert_eq!(config.alpn_protocols, [b"http/1.1".to_vec()]);
    let mut roots = RootCertStore::empty();
    roots.add(ca_der.into()).expect("trust fixture CA");
    let mut client_config =
        ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .expect("select protocols")
            .with_root_certificates(roots)
            .with_no_client_auth();
    client_config.alpn_protocols = vec![b"http/1.1".to_vec()];
    let mut client = ClientConnection::new(
        Arc::new(client_config),
        ServerName::try_from(host.to_owned()).expect("fixture DNS name"),
    )
    .expect("create TLS client");
    let mut server = ServerConnection::new(config).expect("create TLS server");
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
            assert_eq!(client.alpn_protocol(), Some(b"http/1.1".as_slice()));
            return client.peer_certificates().expect("server certificate")[0].to_vec();
        }
    }
    panic!("TLS fixture handshake did not complete");
}

#[test]
fn authority_creates_and_reuses_ca_and_serves_only_exact_selected_dns_leaves() {
    let root = TempDir::new().expect("create temporary root");
    let material = Material::new(&root);
    let names = ["api.example.test", "files.example.test"];
    let authority = ca::Authority::open(&material.directory, names).expect("open runtime CA");
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
        assert!(leaf.validity().not_before >= ca_certificate.validity().not_before);
        assert!(leaf.validity().not_after <= ca_certificate.validity().not_after);
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
            authority.config_for(host).is_err(),
            "accepted unselected {host}"
        );
    }
    let key = fs::read(&material.key).expect("read initial key");
    ca::init(&material.directory).expect("CLI path reuses runtime material");
    ca::Authority::open(&material.directory, names).expect("reopen runtime CA");
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
fn authority_caps_leaf_validity_at_existing_ca_expiry_and_rejects_invalid_names() {
    let now = OffsetDateTime::now_utc();
    let root = TempDir::new().expect("create temporary root");
    let material = Material::new(&root);
    let (certificate, key) = generated(true, now - Duration::minutes(10), now + Duration::hours(2));
    write_pair(&material.directory, &certificate, &key);
    let (_, ca_pem) = parse_x509_pem(certificate.as_bytes()).expect("parse CA PEM");
    let ca_certificate = ca_pem.parse_x509().expect("parse CA");
    let authority =
        ca::Authority::open(&material.directory, ["api.example.test"]).expect("open CA");
    let leaf_der = served_leaf(&authority, "api.example.test", ca_pem.contents.clone());
    let (_, leaf) = x509_parser::parse_x509_certificate(&leaf_der).expect("parse leaf");
    assert_eq!(
        leaf.validity().not_before,
        ca_certificate.validity().not_before
    );
    assert_eq!(
        leaf.validity().not_after,
        ca_certificate.validity().not_after
    );
    for name in ["*.example.test", "127.0.0.1", "bad/name", ""] {
        assert!(
            ca::Authority::open(root.path().join("unused"), [name]).is_err(),
            "accepted {name}"
        );
    }
    assert!(!root.path().join("unused").exists());
}

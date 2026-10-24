//! Passthrough interception: airlock's leaf to the client, verified TLS upstream, bytes unchanged.

mod support;

use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    time::Duration,
};

use airlock_gateway::{CaError, Error, Gateway};
use support::{Running, TOKEN, TestCa, config, fields, sink, tls_upstream};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::oneshot,
    time::timeout,
};
use x509_parser::{extensions::GeneralName, prelude::FromDer};

const LARGE_BODY: usize = 64 << 20;

/// The upstream's ALPN list, and the protocol both sides must end up with.
type AlpnCase = (&'static [&'static [u8]], Option<&'static [u8]>);

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;

fn fnv1a(hash: u64, bytes: &[u8]) -> u64 {
    bytes.iter().fold(hash, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

#[tokio::test]
async fn round_trip_passes_bytes_unchanged_and_never_logs_them() {
    let ca = TestCa::new();
    let upstream = tls_upstream(ca.server_config(&[])).await;
    let payload =
        b"GET /v1/messages HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer fake-SECRET-upstream-token\r\n\r\nbody\x00\xff";
    let upstream_task = tokio::spawn(async move {
        let mut tls = upstream
            .accepted
            .await
            .expect("accept")
            .expect("upstream TLS");
        let mut received = vec![0; payload.len()];
        tls.read_exact(&mut received).await.expect("request");
        tls.write_all(&received).await.expect("echo");
        let mut rest = Vec::new();
        timeout(Duration::from_secs(1), tls.read_to_end(&mut rest))
            .await
            .expect("close_notify deadline")
            .expect("clean close");
        assert_eq!(rest, b"");
        received
    });
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = server
        .handshake(upstream.port, "localhost", &[], true)
        .await
        .expect("client handshake");
    client.write_all(payload).await.expect("send");
    let mut echoed = vec![0; payload.len()];
    timeout(Duration::from_secs(1), client.read_exact(&mut echoed))
        .await
        .expect("echo deadline")
        .expect("echo");
    assert_eq!(echoed, payload);
    client.shutdown().await.expect("close_notify");
    assert_eq!(upstream_task.await.expect("upstream task"), payload);
    drop(client);
    let capture = server.capture.clone();
    let events = server.stop().await;
    // Read after stop has joined every connection, so the close event is in the capture.
    let text = capture.text();
    assert!(!text.contains("fake-SECRET"), "audit exposed bytes: {text}");
    assert_eq!(events.len(), 1);
    let audit = fields(&events[0]);
    assert_eq!(audit["client"], "harness");
    assert_eq!(audit["host"], "localhost");
    assert_eq!(audit["sni"], "localhost");
    assert_eq!(audit["alpn"], "");
    assert_eq!(audit["decision"], "intercept");
    assert_eq!(audit["outcome"], "closed");
    assert_eq!(audit["client_to_upstream"], payload.len());
    assert_eq!(audit["upstream_to_client"], payload.len());
}

#[tokio::test]
async fn first_chunk_reaches_the_client_before_the_upstream_sends_the_last() {
    let ca = TestCa::new();
    let upstream = tls_upstream(ca.server_config(&[])).await;
    let (first_seen, first_seen_by_client) = oneshot::channel();
    let upstream_task = tokio::spawn(async move {
        let mut tls = upstream
            .accepted
            .await
            .expect("accept")
            .expect("upstream TLS");
        tls.write_all(b"chunk-0;").await.expect("first chunk");
        // A gateway that buffered the body would never let the client see the first chunk.
        timeout(Duration::from_secs(2), first_seen_by_client)
            .await
            .expect("client saw the first chunk before the last was sent")
            .expect("signal");
        for index in 1..4 {
            tokio::time::sleep(Duration::from_millis(20)).await;
            tls.write_all(format!("chunk-{index};").as_bytes())
                .await
                .expect("chunk");
        }
        tls.shutdown().await.expect("close_notify");
    });
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = server
        .handshake(upstream.port, "localhost", &[], true)
        .await
        .expect("client handshake");
    let mut first = [0; 8];
    timeout(Duration::from_secs(1), client.read_exact(&mut first))
        .await
        .expect("first chunk deadline")
        .expect("first chunk");
    assert_eq!(&first, b"chunk-0;");
    first_seen.send(()).expect("signal upstream");
    let mut rest = Vec::new();
    timeout(Duration::from_secs(2), client.read_to_end(&mut rest))
        .await
        .expect("rest deadline")
        .expect("rest");
    assert_eq!(rest, b"chunk-1;chunk-2;chunk-3;");
    upstream_task.await.expect("upstream task");
    drop(client);
    let events = server.stop().await;
    assert_eq!(fields(&events[0])["outcome"], "closed");
}

#[tokio::test]
async fn large_body_streams_through_without_buffering() {
    let ca = TestCa::new();
    let upstream = tls_upstream(ca.server_config(&[])).await;
    let upstream_task = tokio::spawn(async move {
        let mut tls = upstream
            .accepted
            .await
            .expect("accept")
            .expect("upstream TLS");
        let mut chunk = vec![0; 64 << 10];
        let mut hash = FNV_OFFSET;
        for index in 0..LARGE_BODY / chunk.len() {
            for (offset, byte) in chunk.iter_mut().enumerate() {
                *byte = (index.wrapping_mul(31) ^ offset).to_le_bytes()[0];
            }
            hash = fnv1a(hash, &chunk);
            tls.write_all(&chunk).await.expect("chunk");
        }
        tls.shutdown().await.expect("close_notify");
        hash
    });
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = server
        .handshake(upstream.port, "localhost", &[], true)
        .await
        .expect("client handshake");
    let mut buffer = vec![0; 16 << 10];
    let mut hash = FNV_OFFSET;
    let mut total = 0;
    timeout(Duration::from_secs(120), async {
        loop {
            let read = client.read(&mut buffer).await.expect("body");
            if read == 0 {
                break;
            }
            hash = fnv1a(hash, &buffer[..read]);
            total += read;
        }
    })
    .await
    .expect("body deadline");
    assert_eq!(total, LARGE_BODY);
    assert_eq!(hash, upstream_task.await.expect("upstream task"));
    drop(client);
    let events = server.stop().await;
    let audit = fields(&events[0]);
    assert_eq!(audit["outcome"], "closed");
    assert_eq!(audit["upstream_to_client"], LARGE_BODY);
}

#[tokio::test]
async fn alpn_is_mirrored_from_the_upstream() {
    let ca = TestCa::new();
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let cases: [AlpnCase; 3] = [
        (&[b"h2"], Some(b"h2")),
        (&[b"http/1.1"], Some(b"http/1.1")),
        (&[], None),
    ];
    for (upstream_alpn, expected) in cases {
        let upstream = tls_upstream(ca.server_config(upstream_alpn)).await;
        let client = server
            .handshake(upstream.port, "localhost", &[b"h2", b"http/1.1"], true)
            .await
            .expect("client handshake");
        assert_eq!(client.get_ref().1.alpn_protocol(), expected);
        let tls = upstream
            .accepted
            .await
            .expect("accept")
            .expect("upstream TLS");
        assert_eq!(tls.get_ref().1.alpn_protocol(), expected);
        drop(client);
        drop(tls);
    }
    let events = server.stop().await;
    let alpn = events
        .iter()
        .map(|event| fields(event)["alpn"].as_str().expect("alpn").to_owned())
        .collect::<Vec<_>>();
    assert_eq!(alpn, ["h2", "http/1.1", ""]);
}

#[tokio::test]
async fn leaf_is_minted_once_for_the_host_and_chains_to_the_airlock_ca() {
    let ca = TestCa::new();
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut leaves = Vec::new();
    for _ in 0..2 {
        let upstream = tls_upstream(ca.server_config(&[])).await;
        // Trusting only ca.pem, a completed handshake is the chain validating to airlock's CA.
        let client = server
            .handshake(upstream.port, "localhost", &[], true)
            .await
            .expect("client handshake");
        let chain = client.get_ref().1.peer_certificates().expect("chain");
        assert_eq!(chain.len(), 1);
        leaves.push(chain[0].to_vec());
    }
    assert_eq!(leaves[0], leaves[1], "the cached leaf was re-minted");
    let ca_pem = fs::read(server.ca_directory.join("ca.pem")).expect("ca.pem");
    let ca_der = rustls::pki_types::pem::PemObject::from_pem_slice(&ca_pem)
        .map(|der: rustls::pki_types::CertificateDer<'static>| der.to_vec())
        .expect("CA DER");
    let (_, authority) =
        x509_parser::certificate::X509Certificate::from_der(&ca_der).expect("parse CA");
    let (_, leaf) =
        x509_parser::certificate::X509Certificate::from_der(&leaves[0]).expect("parse leaf");
    assert_eq!(leaf.issuer(), authority.subject());
    let names = &leaf
        .subject_alternative_name()
        .expect("SAN extension")
        .expect("SAN present")
        .value
        .general_names;
    assert!(matches!(
        names.as_slice(),
        [GeneralName::DNSName("localhost")]
    ));
    let validity = leaf.validity();
    let lifetime = validity.not_after.timestamp() - validity.not_before.timestamp();
    assert!(lifetime <= 7 * 86_400 + 3_600, "lifetime {lifetime}s");
    assert!(!leaf.is_ca());
    let key_usage = leaf
        .extended_key_usage()
        .expect("EKU extension")
        .expect("EKU present");
    assert!(key_usage.value.server_auth);
    let constraints = authority
        .basic_constraints()
        .expect("CA constraints")
        .expect("basicConstraints present")
        .value;
    assert!(constraints.ca);
    assert_eq!(constraints.path_len_constraint, Some(0));
    server.stop().await;
}

#[tokio::test]
async fn sni_mismatch_missing_sni_and_plaintext_never_reach_the_upstream() {
    let listener = sink().await;
    let port = listener.local_addr().expect("sink address").port();
    let server = Running::start_with("deny", &["localhost"], TestCa::new().roots(), None).await;
    assert!(
        server
            .handshake(port, "other.test", &[], true)
            .await
            .is_err()
    );
    assert!(
        server
            .handshake(port, "localhost", &[], false)
            .await
            .is_err()
    );
    let mut socket = server.connect(port).await;
    socket
        .write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        .await
        .expect("plaintext");
    let mut reply = Vec::new();
    timeout(Duration::from_secs(2), socket.read_to_end(&mut reply))
        .await
        .expect("closed deadline")
        .expect("closed");
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    drop(socket);
    let events = server.stop().await;
    let outcomes = events
        .iter()
        .map(|event| {
            let audit = fields(event);
            assert_eq!(audit["decision"], "intercept");
            (
                audit["outcome"].as_str().expect("outcome").to_owned(),
                audit["sni"].as_str().expect("sni").to_owned(),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        outcomes,
        [
            ("sni_mismatch".to_owned(), "other.test".to_owned()),
            ("sni_missing".to_owned(), String::new()),
            ("not_tls".to_owned(), String::new()),
        ]
    );
}

#[tokio::test]
async fn untrusted_upstream_fails_the_client_handshake_and_forwards_nothing() {
    let trusted = TestCa::new();
    let upstream = tls_upstream(TestCa::new().server_config(&[])).await;
    let server = Running::start_with("deny", &["localhost"], trusted.roots(), None).await;
    assert!(
        server
            .handshake(upstream.port, "localhost", &[], true)
            .await
            .is_err()
    );
    assert!(
        upstream.accepted.await.expect("upstream task").is_err(),
        "the upstream completed a handshake with an unverified gateway"
    );
    let events = server.stop().await;
    let audit = fields(&events[0]);
    assert_eq!(audit["outcome"], "upstream_tls_error");
    assert_eq!(audit["client_to_upstream"], 0);
}

#[tokio::test]
async fn client_drop_mid_stream_closes_the_upstream_within_a_second() {
    let ca = TestCa::new();
    let upstream = tls_upstream(ca.server_config(&[])).await;
    let upstream_task = tokio::spawn(async move {
        let mut tls = upstream
            .accepted
            .await
            .expect("accept")
            .expect("upstream TLS");
        let mut received = [0; 7];
        tls.read_exact(&mut received).await.expect("partial");
        tls.write_all(b"streaming").await.expect("response start");
        let mut rest = Vec::new();
        timeout(Duration::from_secs(1), tls.read_to_end(&mut rest))
            .await
            .expect("upstream saw EOF within a second")
            .expect("upstream EOF");
        received
    });
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = server
        .handshake(upstream.port, "localhost", &[], true)
        .await
        .expect("client handshake");
    client.write_all(b"partial").await.expect("partial");
    let mut start = [0; 9];
    client.read_exact(&mut start).await.expect("response start");
    // Dropping the stream closes TCP without close_notify.
    drop(client);
    assert_eq!(&upstream_task.await.expect("upstream task"), b"partial");
    let events = server.stop().await;
    let audit = fields(&events[0]);
    assert_eq!(audit["outcome"], "io_error");
    assert_eq!(audit["client_to_upstream"], 7);
    assert_eq!(audit["upstream_to_client"], 9);
}

#[tokio::test]
async fn a_client_that_stops_reading_cannot_hold_a_closed_relay_open() {
    let ca = TestCa::new();
    let upstream = tls_upstream(ca.server_config(&[])).await;
    let upstream_task = tokio::spawn(async move {
        let mut tls = upstream
            .accepted
            .await
            .expect("accept")
            .expect("upstream TLS");
        // Writes until the gateway stops reading: its ciphertext to the client is backed up.
        let chunk = vec![0; 64 << 10];
        while tls.write_all(&chunk).await.is_ok() {}
    });
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = server
        .handshake(upstream.port, "localhost", &[], true)
        .await
        .expect("client handshake");
    // Let the socket buffers fill, then close our side without ever reading.
    tokio::time::sleep(Duration::from_millis(200)).await;
    client.shutdown().await.expect("close_notify");
    let closed = timeout(Duration::from_secs(3), async {
        while server.capture.text().is_empty() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await;
    assert!(closed.is_ok(), "the relay outlived a stalled reader");
    upstream_task.await.expect("upstream task");
    drop(client);
    let events = server.stop().await;
    let audit = fields(&events[0]);
    assert_eq!(audit["outcome"], "closed");
    assert!(audit["upstream_to_client"].as_u64().expect("count") > 0);
}

#[tokio::test]
async fn symlinked_ca_directory_or_files_are_refused() {
    let ca = TestCa::new();
    let directory = tempfile::tempdir().expect("tempdir");
    fs::write(directory.path().join("token"), format!("{TOKEN}\n")).expect("token");
    let bind = async |ca_directory: &std::path::Path| {
        Gateway::bind(
            config(&directory, "deny", &["localhost"]),
            ca_directory,
            ca.roots(),
        )
        .await
        .err()
        .expect("startup refused")
    };
    // A private directory elsewhere, for example on disk, reached through a symlink.
    let elsewhere = directory.path().join("elsewhere");
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&elsewhere)
        .expect("private target");
    let linked = directory.path().join("airlock-8080");
    std::os::unix::fs::symlink(&elsewhere, &linked).expect("symlink directory");
    let error = bind(&linked).await;
    assert!(
        matches!(&error, Error::Authority(CaError::NotPrivate { path }) if *path == linked),
        "{error}"
    );
    assert_eq!(fs::read_dir(&elsewhere).expect("target").count(), 0);

    let ca_directory = directory.path().join("airlock-8081");
    let first = Running::start_with("deny", &["localhost"], ca.roots(), Some(&ca_directory)).await;
    first.stop().await;
    let key = ca_directory.join("ca.key");
    let moved = elsewhere.join("ca.key");
    fs::rename(&key, &moved).expect("move ca.key");
    std::os::unix::fs::symlink(&moved, &key).expect("symlink ca.key");
    let error = bind(&ca_directory).await;
    assert!(
        matches!(&error, Error::Authority(CaError::NotRegular { path }) if *path == key),
        "{error}"
    );
}

#[tokio::test]
async fn ca_is_reused_across_binds_and_refused_when_exposed_or_incomplete() {
    let ca = TestCa::new();
    let directory = tempfile::tempdir().expect("tempdir");
    let ca_directory = directory.path().join("airlock-8080");
    let cert = ca_directory.join("ca.pem");
    let key = ca_directory.join("ca.key");
    let mode =
        |path: &std::path::Path| fs::metadata(path).expect("metadata").permissions().mode() & 0o777;

    let first = Running::start_with("deny", &["localhost"], ca.roots(), Some(&ca_directory)).await;
    assert_eq!(mode(&ca_directory), 0o700);
    assert_eq!(mode(&key), 0o600);
    assert_eq!(mode(&cert), 0o644);
    let issued = fs::read(&cert).expect("ca.pem");
    first.stop().await;

    let second = Running::start_with("deny", &["localhost"], ca.roots(), Some(&ca_directory)).await;
    assert_eq!(
        fs::read(&cert).expect("ca.pem"),
        issued,
        "the CA was re-minted"
    );
    let upstream = tls_upstream(ca.server_config(&[])).await;
    second
        .handshake(upstream.port, "localhost", &[], true)
        .await
        .expect("leaf from the reused CA");
    second.stop().await;

    let bind = async || {
        fs::write(directory.path().join("token"), format!("{TOKEN}\n")).expect("token");
        Gateway::bind(
            config(&directory, "deny", &["localhost"]),
            &ca_directory,
            ca.roots(),
        )
        .await
        .err()
        .expect("startup refused")
    };
    fs::set_permissions(&key, fs::Permissions::from_mode(0o644)).expect("chmod");
    let error = bind().await;
    assert!(
        matches!(&error, Error::Authority(CaError::KeyExposed { path, .. }) if *path == key),
        "{error}"
    );
    assert!(error.to_string().contains(key.to_str().expect("path")));

    fs::set_permissions(&key, fs::Permissions::from_mode(0o600)).expect("chmod");
    fs::remove_file(&cert).expect("remove ca.pem");
    let error = bind().await;
    assert!(
        matches!(&error, Error::Authority(CaError::Incomplete { present, .. }) if *present == key),
        "{error}"
    );
    assert!(error.to_string().contains(key.to_str().expect("path")));

    fs::write(&cert, &issued).expect("restore ca.pem");
    fs::remove_file(&key).expect("remove ca.key");
    let error = bind().await;
    assert!(
        matches!(&error, Error::Authority(CaError::Incomplete { present, .. }) if *present == cert),
        "{error}"
    );
    assert_eq!(
        fs::read(&cert).expect("ca.pem"),
        issued,
        "ca.pem was overwritten"
    );
}

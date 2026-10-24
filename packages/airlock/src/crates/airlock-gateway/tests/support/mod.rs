//! Fixtures shared by the gateway's integration tests.
#![allow(dead_code)]

use std::{
    io::{self, Write},
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

use airlock_core::config::{Config, RawConfig};
use airlock_gateway::{Error, Gateway};
use base64::{Engine as _, prelude::BASE64_STANDARD};
use rcgen::{
    BasicConstraints, CertificateParams, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair,
    KeyUsagePurpose,
};
use rustls::{
    ClientConfig, RootCertStore, ServerConfig,
    crypto::CryptoProvider,
    pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, pem::PemObject},
};
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    task::JoinHandle,
    time::timeout,
};
use tokio_rustls::{TlsAcceptor, TlsConnector, client, server};
use tracing::instrument::WithSubscriber;

pub const TOKEN: &str = "fake-SECRET-harness-token";

#[derive(Clone, Default)]
pub struct Capture(Arc<Mutex<Vec<u8>>>);

impl Write for Capture {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0
            .lock()
            .expect("capture lock")
            .extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Capture {
    pub fn text(&self) -> String {
        let bytes = self.0.lock().expect("capture lock");
        String::from_utf8(bytes.clone()).expect("JSON UTF-8")
    }

    pub fn events(&self) -> Vec<Value> {
        let text = self.text();
        assert!(!text.contains(TOKEN), "audit exposed token: {text}");
        assert!(
            !text.contains(&BASE64_STANDARD.encode(format!("harness:{TOKEN}"))),
            "audit exposed Basic credentials"
        );
        assert!(!text.to_ascii_lowercase().contains("proxy-authorization"));
        text.lines()
            .map(|line| serde_json::from_str(line).expect("JSON event"))
            .collect()
    }
}

pub struct Running {
    pub address: SocketAddr,
    pub ca_directory: PathBuf,
    pub capture: Capture,
    pub directory: TempDir,
    pub shutdown: oneshot::Sender<()>,
    pub task: JoinHandle<Result<(), Error>>,
}

impl Running {
    pub async fn start(unknown_hosts: &str, intercepted: &[&str]) -> Self {
        Self::start_with(unknown_hosts, intercepted, TestCa::new().roots(), None).await
    }

    /// Starts a gateway that trusts `roots` upstream; `ca_directory` defaults to a fresh one.
    pub async fn start_with(
        unknown_hosts: &str,
        intercepted: &[&str],
        roots: RootCertStore,
        ca_directory: Option<&Path>,
    ) -> Self {
        let directory = tempfile::tempdir().expect("tempdir");
        std::fs::write(directory.path().join("token"), format!("{TOKEN}\n")).expect("write token");
        let ca_directory = ca_directory.map_or_else(|| directory.path().join("ca"), Path::to_owned);
        let gateway = Gateway::bind(
            config(&directory, unknown_hosts, intercepted),
            &ca_directory,
            roots,
        )
        .await
        .expect("bind gateway");
        let address = gateway.local_addr();
        assert_eq!(address.ip(), std::net::Ipv4Addr::LOCALHOST);
        let capture = Capture::default();
        let writer = capture.clone();
        let subscriber = tracing_subscriber::fmt()
            .json()
            .with_writer(move || writer.clone())
            .finish();
        let (shutdown, receiver) = oneshot::channel();
        let task = tokio::spawn(
            gateway
                .serve(async {
                    let _ = receiver.await;
                })
                .with_subscriber(subscriber),
        );
        Self {
            address,
            ca_directory,
            capture,
            directory,
            shutdown,
            task,
        }
    }

    pub async fn stop(self) -> Vec<Value> {
        self.shutdown.send(()).expect("request shutdown");
        timeout(Duration::from_secs(7), self.task)
            .await
            .expect("bounded shutdown")
            .expect("server task")
            .expect("serve");
        self.capture.events()
    }

    pub async fn request(
        &self,
        method: &str,
        target: &str,
        authorization: Option<&str>,
    ) -> (TcpStream, String) {
        let mut socket = TcpStream::connect(self.address)
            .await
            .expect("connect gateway");
        let auth = authorization.map_or_else(String::new, |value| {
            format!("Proxy-Authorization: {value}\r\n")
        });
        socket
            .write_all(
                format!("{method} {target} HTTP/1.1\r\nHost: localhost\r\n{auth}\r\n").as_bytes(),
            )
            .await
            .expect("request");
        let mut header = Vec::new();
        timeout(Duration::from_secs(2), async {
            while !header.ends_with(b"\r\n\r\n") {
                header.push(socket.read_u8().await.expect("response header"));
                assert!(header.len() < 8192);
            }
        })
        .await
        .expect("timely response");
        (socket, String::from_utf8(header).expect("header UTF-8"))
    }

    /// CONNECTs to `localhost:<port>`, expecting 200, and returns the raw tunnel.
    pub async fn connect(&self, port: u16) -> TcpStream {
        let (socket, header) = self
            .request(
                "CONNECT",
                &format!("localhost:{port}"),
                Some(&basic("harness", TOKEN)),
            )
            .await;
        assert!(
            header.starts_with("HTTP/1.1 200 Connection Established\r\n"),
            "{header}"
        );
        socket
    }

    /// CONNECTs, then handshakes trusting only airlock's `ca.pem`.
    pub async fn handshake(
        &self,
        port: u16,
        server_name: &str,
        alpn: &[&[u8]],
        sni: bool,
    ) -> io::Result<client::TlsStream<TcpStream>> {
        let socket = self.connect(port).await;
        let mut roots = RootCertStore::empty();
        roots
            .add(CertificateDer::from_pem_file(self.ca_directory.join("ca.pem")).expect("ca.pem"))
            .expect("trust airlock CA");
        let mut config = ClientConfig::builder_with_provider(provider())
            .with_safe_default_protocol_versions()
            .expect("protocol versions")
            .with_root_certificates(roots)
            .with_no_client_auth();
        config.alpn_protocols = alpn.iter().map(|protocol| protocol.to_vec()).collect();
        config.enable_sni = sni;
        timeout(
            Duration::from_secs(5),
            TlsConnector::from(Arc::new(config)).connect(
                ServerName::try_from(server_name.to_owned()).expect("server name"),
                socket,
            ),
        )
        .await
        .expect("client handshake deadline")
    }
}

pub fn config(directory: &TempDir, unknown_hosts: &str, intercepted: &[&str]) -> Config {
    Config::try_from(serde_json::from_value::<RawConfig>(json!({
        "clients": {"harness": {
            "grants": [{"credentials": ["claude"], "upstream": "anthropic"}],
            "token_file": directory.path().join("token")
        }},
        "credentials": {"claude": {
            "auth": {"file": directory.path().join("unused-upstream-secret"), "type": "oauth_bearer"},
            "upstream": "anthropic"
        }},
        "listen": "127.0.0.1:0",
        "state_dir": directory.path(),
        "unknown_hosts": unknown_hosts,
        "upstreams": {"anthropic": {"intercept": intercepted, "provider": "anthropic"}}
    })).expect("raw config")).expect("validated config")
}

pub fn basic(client: &str, token: &str) -> String {
    format!(
        "Basic {}",
        BASE64_STANDARD.encode(format!("{client}:{token}"))
    )
}

pub async fn sink() -> TcpListener {
    TcpListener::bind("127.0.0.1:0").await.expect("bind sink")
}

pub fn fields(event: &Value) -> &Value {
    assert_eq!(event["fields"]["message"], "CONNECT closed");
    &event["fields"]
}

pub fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// A CA standing in for the public roots that real upstreams chain to.
pub struct TestCa {
    cert: CertificateDer<'static>,
    issuer: Issuer<'static, KeyPair>,
}

impl TestCa {
    pub fn new() -> Self {
        let key = KeyPair::generate().expect("CA key");
        let mut params = CertificateParams::new(Vec::new()).expect("CA params");
        params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        params.key_usages = vec![KeyUsagePurpose::KeyCertSign];
        let cert = params.self_signed(&key).expect("CA cert").der().clone();
        Self {
            cert,
            issuer: Issuer::new(params, key),
        }
    }

    pub fn roots(&self) -> RootCertStore {
        let mut roots = RootCertStore::empty();
        roots.add(self.cert.clone()).expect("test root");
        roots
    }

    /// A mock upstream's TLS config: a `localhost` leaf from this CA, offering `alpn`.
    pub fn server_config(&self, alpn: &[&[u8]]) -> Arc<ServerConfig> {
        let key = KeyPair::generate().expect("leaf key");
        let mut params = CertificateParams::new(vec!["localhost".to_owned()]).expect("leaf");
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        let cert = params.signed_by(&key, &self.issuer).expect("leaf cert");
        let mut config = ServerConfig::builder_with_provider(provider())
            .with_safe_default_protocol_versions()
            .expect("protocol versions")
            .with_no_client_auth()
            .with_single_cert(
                vec![cert.der().clone()],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der())),
            )
            .expect("upstream config");
        config.alpn_protocols = alpn.iter().map(|protocol| protocol.to_vec()).collect();
        Arc::new(config)
    }
}

/// A mock TLS upstream on `127.0.0.1:0` that accepts one connection.
pub struct Upstream {
    pub accepted: JoinHandle<io::Result<server::TlsStream<TcpStream>>>,
    pub port: u16,
}

pub async fn tls_upstream(config: Arc<ServerConfig>) -> Upstream {
    let listener = sink().await;
    let port = listener.local_addr().expect("upstream address").port();
    let accepted = tokio::spawn(async move {
        let (socket, _) = listener.accept().await?;
        TlsAcceptor::from(config).accept(socket).await
    });
    Upstream { accepted, port }
}

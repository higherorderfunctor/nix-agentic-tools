//! Fixtures shared by the gateway's integration tests.
#![allow(dead_code)]

use std::{
    io::{self, Write},
    net::SocketAddr,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use airlock_core::config::{Config, RawConfig};
use airlock_core::storage::SqliteStorage;
use airlock_gateway::{Error, Gateway, RequestUsageSink};
use base64::{Engine as _, prelude::BASE64_STANDARD};
use http_body_util::BodyExt;
use hyper::{
    Method, Request, Response, StatusCode, Uri,
    body::{Body, Bytes, Frame, Incoming},
    client::conn,
    header::{HeaderMap, HeaderName, HeaderValue},
    server::conn as server_conn,
    service::service_fn,
};
use hyper_util::rt::{TokioExecutor, TokioIo};
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
    sync::{Notify, mpsc, oneshot},
    task::JoinHandle,
    time::{sleep, timeout},
};
use tokio_rustls::{TlsAcceptor, TlsConnector, client, server};
use tracing::instrument::WithSubscriber;

pub const TOKEN: &str = "fake-SECRET-harness-token";
pub const CLIENT_OAUTH_TOKEN: &str = "fake-CLIENT-oauth";
pub const CLIENT_API_KEY: &str = "fake-CLIENT-api-key";
pub const REAL_OAUTH_TOKEN: &str = "fake-REAL-oauth";
pub const REAL_API_KEY: &str = "fake-REAL-api-key";

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
        for prefix in ["fake-REAL", "fake-CLIENT"] {
            assert!(!text.contains(prefix), "audit exposed credential: {text}");
        }
        text.lines()
            .map(|line| serde_json::from_str(line).expect("JSON event"))
            .collect()
    }

    pub fn request_events(&self) -> Vec<Value> {
        let events: Vec<_> = self
            .events()
            .into_iter()
            .filter(|event| event["fields"]["message"] == "request")
            .collect();
        assert!(!events.is_empty(), "no request events");
        for event in &events {
            let path = event["fields"]["path"].as_str().expect("request path");
            assert!(
                !path.contains('?'),
                "request path exposed its query: {path}"
            );
        }
        events
    }
}

pub struct Running {
    pub address: SocketAddr,
    pub ca_directory: PathBuf,
    pub capture: Capture,
    pub directory: TempDir,
    pub shutdown: oneshot::Sender<()>,
    pub storage: Option<Arc<SqliteStorage>>,
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
        Self::start_with_auth(
            unknown_hosts,
            intercepted,
            roots,
            ca_directory,
            FixtureAuth::OauthBearer,
            None,
        )
        .await
    }

    pub async fn start_with_port(roots: RootCertStore, upstream_port: u16) -> Self {
        Self::start_with_auth(
            "deny",
            &["localhost"],
            roots,
            None,
            FixtureAuth::OauthBearer,
            Some(upstream_port),
        )
        .await
    }

    pub async fn start_with_policy(
        unknown_hosts: &str,
        intercepted: &[&str],
        policy: &str,
    ) -> Self {
        let directory = tempfile::tempdir().expect("tempdir");
        write_fixtures(&directory, FixtureAuth::OauthBearer);
        let ca_directory = directory.path().join("ca");
        let config = config_with_auth(
            &directory,
            unknown_hosts,
            intercepted,
            FixtureAuth::OauthBearer,
            None,
            Some(policy),
        );
        Self::start_config(directory, config, ca_directory, TestCa::new().roots(), None).await
    }

    pub async fn start_with_auth(
        unknown_hosts: &str,
        intercepted: &[&str],
        roots: RootCertStore,
        ca_directory: Option<&Path>,
        auth: FixtureAuth,
        upstream_port: Option<u16>,
    ) -> Self {
        let directory = tempfile::tempdir().expect("tempdir");
        write_fixtures(&directory, auth);
        let ca_directory = ca_directory.map_or_else(|| directory.path().join("ca"), Path::to_owned);
        let config = config_with_auth(
            &directory,
            unknown_hosts,
            intercepted,
            auth,
            upstream_port,
            None,
        );
        Self::start_config(directory, config, ca_directory, roots, None).await
    }

    pub async fn start_multiplex(roots: RootCertStore, primary_port: u16, zai_port: u16) -> Self {
        let primary_endpoint = format!("https://localhost:{primary_port}");
        Self::start_multiplex_with_primary(roots, zai_port, &primary_endpoint).await
    }

    pub async fn start_multiplex_with_primary(
        roots: RootCertStore,
        zai_port: u16,
        primary_endpoint: &str,
    ) -> Self {
        Self::start_multiplex_with_usage(roots, zai_port, primary_endpoint, None).await
    }

    pub async fn start_multiplex_with_usage(
        roots: RootCertStore,
        zai_port: u16,
        primary_endpoint: &str,
        usage: Option<Arc<dyn RequestUsageSink>>,
    ) -> Self {
        let directory = tempfile::tempdir().expect("tempdir");
        write_fixtures(&directory, FixtureAuth::OauthBearer);
        std::fs::write(directory.path().join("zai"), "fake-REAL-zai\n").expect("zai secret");
        let config = Config::try_from(serde_json::from_value::<RawConfig>(json!({
            "clients": {"harness": {"grants": ["anthropic"], "token_file": directory.path().join("token")}},
            "credentials": {
                "claude": {"auth": {"file": directory.path().join("claude"), "type": "oauth_bearer"}, "provider": "claude"},
                "zai": {"auth": {"file": directory.path().join("zai"), "type": "api_key"}, "provider": "zai"}
            },
            "groups": {"anthropic": {"intercept": ["localhost"], "members": {
                "claude": {"models": []}, "zai": {"models": ["glm-4.7"]}
            }, "primary": "claude", "protocol": "anthropic"}},
            "listen": "127.0.0.1:0",
            "providers": {
                "claude": {"endpoints": {"anthropic": primary_endpoint}},
                "zai": {"preset": "zai", "endpoints": {"anthropic": format!("https://localhost:{zai_port}/api/anthropic")}}
            },
            "state_dir": directory.path(),
            "unknown_hosts": "deny"
        })).expect("raw multiplex config")).expect("multiplex config");
        let ca_directory = directory.path().join("ca");
        Self::start_config(directory, config, ca_directory, roots, usage).await
    }

    pub async fn start_managed(roots: RootCertStore, upstream_port: u16) -> Self {
        let directory = tempfile::tempdir().expect("tempdir");
        Self::start_managed_in(directory, roots, upstream_port).await
    }

    pub async fn start_managed_in(
        directory: TempDir,
        roots: RootCertStore,
        upstream_port: u16,
    ) -> Self {
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
            .expect("private state directory");
        std::fs::write(directory.path().join("token"), format!("{TOKEN}\n")).expect("client token");
        std::fs::write(
            directory.path().join("stranger-token"),
            "fake-STRANGER-token\n",
        )
        .expect("other client token");
        std::fs::write(directory.path().join("spare-key"), "fake-SPARE-key\n")
            .expect("other group credential");
        let config = Config::try_from(serde_json::from_value::<RawConfig>(json!({
            "clients": {
                "harness": {"grants": ["anthropic"], "token_file": directory.path().join("token")},
                "stranger": {"grants": ["other"], "token_file": directory.path().join("stranger-token")}
            },
            "credentials": {
                "claude": {"auth": {"type": "oauth_managed"}, "provider": "claude"},
                "spare": {"auth": {"file": directory.path().join("spare-key"), "type": "api_key"}, "provider": "claude"}
            },
            "groups": {
                "anthropic": {"intercept": ["localhost", "platform.claude.com"], "members": {
                    "claude": {"models": []}
                }, "primary": "claude", "protocol": "anthropic"},
                "other": {"intercept": ["other.invalid"], "members": {
                    "spare": {"models": []}
                }, "primary": "spare", "protocol": "anthropic"}
            },
            "listen": "127.0.0.1:0",
            "providers": {"claude": {"preset": "claude", "endpoints": {"anthropic": format!("https://localhost:{upstream_port}")}}},
            "state_dir": directory.path(),
            "unknown_hosts": "deny"
        })).expect("raw managed config")).expect("managed config");
        let storage = Arc::new(
            SqliteStorage::open(config.state_dir(), config.storage_identities(1))
                .await
                .expect("managed storage"),
        );
        let ca_directory = directory.path().join("ca");
        Self::start_config_with_storage(directory, config, ca_directory, roots, Some(storage), None)
            .await
    }

    async fn start_config(
        directory: TempDir,
        config: Config,
        ca_directory: PathBuf,
        roots: RootCertStore,
        usage: Option<Arc<dyn RequestUsageSink>>,
    ) -> Self {
        Self::start_config_with_storage(directory, config, ca_directory, roots, None, usage).await
    }

    async fn start_config_with_storage(
        directory: TempDir,
        config: Config,
        ca_directory: PathBuf,
        roots: RootCertStore,
        storage: Option<Arc<SqliteStorage>>,
        usage: Option<Arc<dyn RequestUsageSink>>,
    ) -> Self {
        let gateway = Gateway::bind(config, &ca_directory, roots, storage.clone(), usage)
            .await
            .expect("bind gateway");
        let address = gateway.local_addr();
        assert_eq!(address.ip(), std::net::Ipv4Addr::LOCALHOST);
        let capture = Capture::default();
        let writer = capture.clone();
        let subscriber = tracing_subscriber::fmt()
            .json()
            .with_max_level(tracing::Level::DEBUG)
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
            storage,
            task,
        }
    }

    pub async fn closed_event(&self) -> Value {
        timeout(Duration::from_secs(3), async {
            loop {
                if let Some(event) = self
                    .capture
                    .events()
                    .into_iter()
                    .find(|event| event["fields"]["message"] == "CONNECT closed")
                {
                    return event;
                }
                sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("CONNECT audit deadline")
    }

    pub async fn stop(self) -> Vec<Value> {
        self.stop_with_directory().await.1
    }

    pub async fn stop_with_directory(self) -> (TempDir, Vec<Value>) {
        self.shutdown.send(()).expect("request shutdown");
        timeout(Duration::from_secs(7), self.task)
            .await
            .expect("bounded shutdown")
            .expect("server task")
            .expect("serve");
        if let Some(storage) = self.storage {
            Arc::try_unwrap(storage)
                .unwrap_or_else(|_| panic!("gateway retained managed storage after shutdown"))
                .close()
                .await
                .expect("close managed storage");
        }
        let events = self
            .capture
            .events()
            .into_iter()
            .filter(|event| event["fields"]["message"] == "CONNECT closed")
            .collect();
        (self.directory, events)
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

#[derive(Clone, Copy)]
pub enum FixtureAuth {
    ApiKey,
    OauthBearer,
}

fn write_fixtures(directory: &TempDir, auth: FixtureAuth) {
    std::fs::write(directory.path().join("token"), format!("{TOKEN}\n")).expect("write token");
    std::fs::write(
        directory.path().join("claude"),
        format!(
            "{}\n",
            match auth {
                FixtureAuth::ApiKey => REAL_API_KEY,
                FixtureAuth::OauthBearer => REAL_OAUTH_TOKEN,
            }
        ),
    )
    .expect("write primary credential");
    std::fs::write(
        directory.path().join("backup"),
        format!(
            "{}\n",
            match auth {
                FixtureAuth::ApiKey => REAL_OAUTH_TOKEN,
                FixtureAuth::OauthBearer => REAL_API_KEY,
            }
        ),
    )
    .expect("write backup credential");
}

pub fn config(directory: &TempDir, unknown_hosts: &str, intercepted: &[&str]) -> Config {
    config_with_auth(
        directory,
        unknown_hosts,
        intercepted,
        FixtureAuth::OauthBearer,
        None,
        None,
    )
}

fn config_with_auth(
    directory: &TempDir,
    unknown_hosts: &str,
    intercepted: &[&str],
    auth: FixtureAuth,
    upstream_port: Option<u16>,
    authorization: Option<&str>,
) -> Config {
    let primary = match auth {
        FixtureAuth::ApiKey => json!({
            "file": directory.path().join("claude"), "type": "api_key"
        }),
        FixtureAuth::OauthBearer => json!({
            "file": directory.path().join("claude"), "type": "oauth_bearer"
        }),
    };
    let endpoint = match upstream_port {
        Some(port) => format!(
            "https://{}:{port}",
            intercepted.first().unwrap_or(&"localhost")
        ),
        None => format!("https://{}", intercepted.first().unwrap_or(&"localhost")),
    };
    let mut value = json!({
        "clients": {"harness": {
            "grants": ["anthropic"],
            "token_file": directory.path().join("token")
        }},
        "credentials": {
            "backup": {"auth": {
                "file": directory.path().join("backup"),
                "type": if matches!(auth, FixtureAuth::ApiKey) { "oauth_bearer" } else { "api_key" }
            }, "provider": "claude"},
            "claude": {"auth": primary, "provider": "claude"}
        },
        "groups": {"anthropic": {
            "intercept": intercepted,
            "members": {"claude": {"models": []}},
            "primary": "claude", "protocol": "anthropic"
        }},
        "listen": "127.0.0.1:0",
        "providers": {"claude": {"endpoints": {"anthropic": endpoint}}},
        "state_dir": directory.path(),
        "unknown_hosts": unknown_hosts
    });
    if let Some(authorization) = authorization {
        value["authorization"] = json!(authorization);
    }
    let raw = serde_json::from_value::<RawConfig>(value).expect("raw config");
    Config::try_from(raw).expect("validated config")
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HttpProtocol {
    Http1,
    Http2,
}

impl HttpProtocol {
    pub fn client_alpn(self) -> &'static [&'static [u8]] {
        match self {
            Self::Http1 => &[b"http/1.1"],
            Self::Http2 => &[b"h2"],
        }
    }

    pub fn server_alpn(self) -> &'static [&'static [u8]] {
        self.client_alpn()
    }
}

#[derive(Debug)]
pub struct RequestRecord {
    pub authority: Option<String>,
    pub body: Bytes,
    pub body_hash: u64,
    pub body_len: usize,
    pub headers: HeaderMap,
    pub method: Method,
    pub path: String,
    pub query: Option<String>,
}

pub struct StallGates {
    pub backpressure: Notify,
    pub response_started: Notify,
}

pub struct UpgradeBytes {
    pub client_to_upstream: AtomicU64,
}

#[derive(Clone)]
pub struct QuotaFixture {
    pub body: &'static [u8],
    pub headers: Vec<(&'static str, &'static str)>,
    pub release_body: Option<Arc<Notify>>,
    pub status: StatusCode,
}

#[derive(Clone)]
pub enum UpstreamMode {
    CloseAfterResponse,
    DropMidResponse,
    Echo,
    Fixed {
        body: &'static [u8],
        content_type: &'static str,
        encoding: Option<&'static str>,
    },
    Encoded {
        body: Bytes,
        content_type: &'static str,
    },
    Gate(Arc<Notify>),
    HashUpload,
    Metadata,
    Quota(Arc<QuotaFixture>),
    Models,
    Oauth,
    OauthDelayedReply {
        body: &'static [u8],
        delay: Duration,
    },
    OauthRefreshReply {
        initial: Option<&'static [u8]>,
        refresh: &'static [u8],
    },
    OauthWithoutNewRefresh,
    OauthReply {
        body: &'static [u8],
        status: StatusCode,
    },
    OauthStall(Arc<StallGates>),
    Sse(Arc<Notify>),
    ToolSearchSse {
        release: Arc<Notify>,
        content_type: &'static str,
        cr_only: bool,
    },
    Stall(Arc<StallGates>),
    UpgradeEcho(Arc<UpgradeBytes>),
}

async fn serve_raw_upgrade(
    mut tls: server::TlsStream<TcpStream>,
    bytes: Arc<UpgradeBytes>,
) -> io::Result<()> {
    let mut header = Vec::new();
    while !header.ends_with(b"\r\n\r\n") {
        let mut byte = [0];
        let read = tls.read(&mut byte).await?;
        if read == 0 {
            return Err(io::Error::from(io::ErrorKind::UnexpectedEof));
        }
        bytes
            .client_to_upstream
            .fetch_add(read as u64, Ordering::Relaxed);
        header.push(byte[0]);
        assert!(header.len() < 8192);
    }
    tls.write_all(
        b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: test\r\n\r\n",
    )
    .await?;
    let mut buffer = [0; 4096];
    loop {
        let read = tls.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        bytes
            .client_to_upstream
            .fetch_add(read as u64, Ordering::Relaxed);
        tls.write_all(&buffer[..read]).await?;
    }
    tls.shutdown().await
}

async fn request_body(mode: &UpstreamMode, mut body: Incoming) -> (Bytes, u64, usize) {
    let echo = matches!(
        mode,
        UpstreamMode::Echo
            | UpstreamMode::Fixed { .. }
            | UpstreamMode::Oauth
            | UpstreamMode::OauthDelayedReply { .. }
            | UpstreamMode::OauthRefreshReply { .. }
            | UpstreamMode::OauthWithoutNewRefresh
            | UpstreamMode::OauthReply { .. }
            | UpstreamMode::OauthStall(_)
            | UpstreamMode::Encoded { .. }
            | UpstreamMode::ToolSearchSse { .. }
    );
    let mut collected = Vec::new();
    let mut hash = FNV_OFFSET;
    let mut len = 0;
    while let Some(frame) = body.frame().await {
        let frame = frame.expect("upstream body");
        if let Ok(bytes) = frame.into_data() {
            hash = fnv1a_test(hash, &bytes);
            len += bytes.len();
            if echo {
                collected.extend_from_slice(&bytes);
            }
        }
    }
    (Bytes::from(collected), hash, len)
}

fn toolsearch_sse_chunks(cr_only: bool) -> &'static [&'static [u8]] {
    if cr_only {
        &[
            b"event: content_block_start\rdata: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"name\":\"ToolSearch_\",\"input\":{}}}\r\r",
            b"event: message\rdata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\r\r",
        ]
    } else {
        &[
            b"event: content_block_start\r\ndata: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"name\":\"Tool",
            b"Search_\",\"input\":{}}}\r\n\r",
            b"\nevent: message\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\n\n",
        ]
    }
}

fn fixed_response(
    body: Bytes,
    content_type: &'static str,
    encoding: Option<&'static str>,
) -> Response<ReceiverBody> {
    let mut response = Response::builder()
        .header("content-type", content_type)
        .header("content-length", body.len().to_string());
    if let Some(encoding) = encoding {
        response = response.header("content-encoding", encoding);
    }
    response.body(queued_body(body)).expect("fixed response")
}

fn quota_response(fixture: &QuotaFixture) -> Response<ReceiverBody> {
    let mut builder = Response::builder().status(fixture.status);
    for (name, value) in &fixture.headers {
        builder = builder.header(
            HeaderName::from_bytes(name.as_bytes()).expect("fixture header name"),
            HeaderValue::from_str(value).expect("fixture header value"),
        );
    }
    let body = if let Some(release) = &fixture.release_body {
        let (sender, receiver) = mpsc::channel(1);
        let release = release.clone();
        let bytes = Bytes::from_static(fixture.body);
        tokio::spawn(async move {
            release.notified().await;
            let _ = sender.send(Ok(Frame::data(bytes))).await;
        });
        ReceiverBody::new(receiver)
    } else {
        queued_body(Bytes::from_static(fixture.body))
    };
    builder.body(body).expect("quota response")
}

fn model_list_response(path: &str, query: Option<&str>) -> Response<ReceiverBody> {
    let path_query = format!("{path}?{}", query.unwrap_or_default());
    let (status, body): (StatusCode, &'static [u8]) = if path_query.contains("fail=") {
        (
            StatusCode::from_u16(529).expect("Anthropic overloaded status"),
            br#"{"type":"error","error":{"type":"overloaded_error","message":"fake upstream busy"}}"#,
        )
    } else if path_query.contains("after=claude-a") {
        (
            StatusCode::OK,
            br#"{"data":[{"id":"claude-b"}],"first_id":"claude-a","has_more":false,"last_id":"claude-b"}"#,
        )
    } else {
        (
            StatusCode::OK,
            br#"{"data":[{"id":"claude-a"}],"first_id":null,"has_more":true,"last_id":"claude-a"}"#,
        )
    };
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .header("anthropic-version", "fake-pagination")
        .body(queued_body(Bytes::from_static(body)))
        .expect("model-list response")
}

fn oauth_response(path: &str, body: &Bytes, omit_refresh: bool) -> Response<ReceiverBody> {
    let response: &'static [u8] = if path == "/v1/oauth/token"
        && body.windows(18).any(|part| part == b"authorization_code")
    {
        br#"{"access_token":"fake-REAL-access-one","refresh_token":"fake-REAL-refresh-one","expires_in":3600,"refresh_token_expires_in":2592000,"scope":"user:inference user:profile","account":{"uuid":"fake-account"}}"#
    } else if path == "/v1/oauth/token" && omit_refresh {
        br#"{"access_token":"fake-REAL-access-two","expires_in":3600,"scope":"user:inference user:profile"}"#
    } else if path == "/v1/oauth/token" {
        br#"{"access_token":"fake-REAL-access-two","refresh_token":"fake-REAL-refresh-two","expires_in":3600,"refresh_token_expires_in":2592000,"scope":"user:inference user:profile"}"#
    } else if path == "/v1/oauth/token/revoke" {
        b""
    } else {
        br#"{"ok":true}"#
    };
    Response::builder()
        .header("content-type", "application/json")
        .body(queued_body(Bytes::from_static(response)))
        .expect("OAuth response")
}

fn oauth_reply(body: &'static [u8], status: StatusCode) -> Response<ReceiverBody> {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(queued_body(Bytes::from_static(body)))
        .expect("OAuth fixture response")
}

fn oauth_delayed_reply(body: &'static [u8], delay: Duration) -> Response<ReceiverBody> {
    let (sender, receiver) = mpsc::channel(1);
    tokio::spawn(async move {
        tokio::time::sleep(delay).await;
        let _ = sender.send(Ok(Frame::data(Bytes::from_static(body)))).await;
    });
    Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "application/json")
        .body(ReceiverBody::new(receiver))
        .expect("delayed OAuth response")
}

fn oauth_stalled_response(gates: Arc<StallGates>) -> Response<ReceiverBody> {
    let (sender, receiver) = mpsc::channel(1);
    tokio::spawn(async move {
        gates.response_started.notify_one();
        gates.backpressure.notified().await;
        drop(sender);
    });
    Response::builder()
        .status(StatusCode::OK)
        .header("content-length", "1")
        .body(ReceiverBody::new(receiver))
        .expect("stalled OAuth response")
}

fn oauth_refresh_response(
    path: &str,
    request_body: &Bytes,
    initial: Option<&'static [u8]>,
    refresh: &'static [u8],
) -> Response<ReceiverBody> {
    if path == "/v1/oauth/token"
        && request_body
            .windows(b"refresh_token".len())
            .any(|part| part == b"refresh_token")
    {
        oauth_reply(refresh, StatusCode::OK)
    } else if let Some(initial) = initial {
        oauth_reply(initial, StatusCode::OK)
    } else {
        oauth_response(path, request_body, false)
    }
}

async fn gated_response(release: Arc<Notify>, path: &str) -> Response<ReceiverBody> {
    if path == "/blocked" {
        release.notified().await;
    } else {
        release.notify_one();
    }
    Response::new(queued_body(Bytes::from_static(b"released")))
}

async fn upstream_response(
    mode: UpstreamMode,
    path: &str,
    query: Option<&str>,
    body: Bytes,
    body_hash: u64,
) -> Response<ReceiverBody> {
    match mode {
        UpstreamMode::CloseAfterResponse => Response::builder()
            .header("connection", "close")
            .body(queued_body(Bytes::from_static(b"upstream-closed")))
            .expect("close response"),
        UpstreamMode::DropMidResponse => {
            let (sender, receiver) = mpsc::channel(1);
            tokio::spawn(async move {
                let _ = sender
                    .send(Ok(Frame::data(Bytes::from_static(b"first-event;"))))
                    .await;
                let _ = sender
                    .send(Err(io::Error::from(io::ErrorKind::BrokenPipe)))
                    .await;
            });
            Response::new(ReceiverBody::new(receiver))
        }
        UpstreamMode::Echo => Response::new(queued_body(body)),
        UpstreamMode::Fixed {
            body,
            content_type,
            encoding,
        } => fixed_response(Bytes::from_static(body), content_type, encoding),
        UpstreamMode::Encoded { body, content_type } => {
            fixed_response(body, content_type, Some("gzip"))
        }
        UpstreamMode::Gate(release) => gated_response(release, path).await,
        UpstreamMode::HashUpload => Response::new(queued_body(Bytes::from(body_hash.to_string()))),
        UpstreamMode::Metadata => Response::builder()
            .status(StatusCode::TOO_MANY_REQUESTS)
            .header("retry-after", "7")
            .header("x-upstream", "metadata")
            .header("upgrade", "websocket")
            .body(queued_body(Bytes::from_static(b"quota")))
            .expect("metadata response"),
        UpstreamMode::Quota(fixture) => quota_response(&fixture),
        UpstreamMode::Models => model_list_response(path, query),
        UpstreamMode::Oauth => oauth_response(path, &body, false),
        UpstreamMode::OauthDelayedReply { body, delay } => oauth_delayed_reply(body, delay),
        UpstreamMode::OauthRefreshReply { initial, refresh } => {
            oauth_refresh_response(path, &body, initial, refresh)
        }
        UpstreamMode::OauthWithoutNewRefresh => oauth_response(path, &body, true),
        UpstreamMode::OauthReply { body, status } => oauth_reply(body, status),
        UpstreamMode::OauthStall(gates) => oauth_stalled_response(gates),
        UpstreamMode::Sse(release) => {
            let (sender, receiver) = mpsc::channel(2);
            tokio::spawn(async move {
                let _ = sender
                    .send(Ok(Frame::data(Bytes::from_static(b"event:first\n\n"))))
                    .await;
                release.notified().await;
                let _ = sender
                    .send(Ok(Frame::data(Bytes::from_static(b"event:last\n\n"))))
                    .await;
            });
            Response::new(ReceiverBody::new(receiver))
        }
        UpstreamMode::ToolSearchSse {
            release,
            content_type,
            cr_only,
        } => {
            let (sender, receiver) = mpsc::channel(4);
            tokio::spawn(async move {
                for part in toolsearch_sse_chunks(cr_only) {
                    if sender
                        .send(Ok(Frame::data(Bytes::copy_from_slice(part))))
                        .await
                        .is_err()
                    {
                        return;
                    }
                }
                release.notified().await;
                let _ = sender
                    .send(Ok(Frame::data(Bytes::from_static(
                        b"event: done\ndata: [DONE]\n\n",
                    ))))
                    .await;
            });
            Response::builder()
                .header("content-type", content_type)
                .body(ReceiverBody::new(receiver))
                .expect("SSE response")
        }
        UpstreamMode::Stall(_) => unreachable!("raw stalled-reader upstream"),
        UpstreamMode::UpgradeEcho(_) => unreachable!("raw upgrade upstream"),
    }
}

async fn serve_raw_stall(
    mut tls: server::TlsStream<TcpStream>,
    gates: Arc<StallGates>,
) -> io::Result<()> {
    let mut request = Vec::new();
    while !request.ends_with(b"\r\n\r\n") {
        let mut byte = [0];
        let read = tls.read(&mut byte).await?;
        if read == 0 {
            return Err(io::Error::from(io::ErrorKind::UnexpectedEof));
        }
        request.push(byte[0]);
        assert!(request.len() < 8192);
    }
    tls.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
        .await?;
    tls.flush().await?;
    gates.response_started.notify_one();
    let chunk = vec![b'x'; 1024 * 1024];
    loop {
        let write = async {
            write_chunk(&mut tls, &chunk).await?;
            tls.flush().await
        };
        tokio::pin!(write);
        if let Ok(result) = timeout(Duration::from_millis(100), write.as_mut()).await {
            result?;
        } else {
            gates.backpressure.notify_one();
            write.await?;
        }
    }
}

async fn write_chunk<T>(tls: &mut T, chunk: &[u8]) -> io::Result<()>
where
    T: AsyncWriteExt + Unpin,
{
    let length = format!("{:x}\r\n", chunk.len());
    tls.write_all(length.as_bytes()).await?;
    tls.write_all(chunk).await?;
    tls.write_all(b"\r\n").await
}

pub struct HttpUpstream {
    pub done: JoinHandle<io::Result<()>>,
    pub port: u16,
    pub records: std::sync::Arc<std::sync::Mutex<Vec<RequestRecord>>>,
}

pub async fn wait_for_request(upstream: &HttpUpstream, path: &str) {
    timeout(Duration::from_secs(1), async {
        loop {
            if records(upstream).iter().any(|record| record.path == path) {
                return;
            }
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("upstream request deadline");
}

pub fn records(upstream: &HttpUpstream) -> Vec<RequestRecord> {
    let records = upstream.records.lock().expect("records lock");
    records
        .iter()
        .map(|record| RequestRecord {
            authority: record.authority.clone(),
            body: record.body.clone(),
            body_hash: record.body_hash,
            body_len: record.body_len,
            headers: record.headers.clone(),
            method: record.method.clone(),
            path: record.path.clone(),
            query: record.query.clone(),
        })
        .collect()
}

pub async fn http_upstream(
    ca: &TestCa,
    protocol: HttpProtocol,
    mode: UpstreamMode,
) -> HttpUpstream {
    let listener = sink().await;
    let port = listener.local_addr().expect("upstream address").port();
    let records = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let acceptor = TlsAcceptor::from(ca.server_config(protocol.server_alpn()));
    let task_records = records.clone();

    let done = tokio::spawn(async move {
        let (socket, _) = listener.accept().await?;
        let tls = acceptor.accept(socket).await?;
        if let UpstreamMode::Stall(gates) = &mode {
            return serve_raw_stall(tls, gates.clone()).await;
        }
        if let UpstreamMode::UpgradeEcho(bytes) = &mode {
            return serve_raw_upgrade(tls, bytes.clone()).await;
        }
        let is_h2 = tls.get_ref().1.alpn_protocol() == Some(&b"h2"[..]);
        let service_records = task_records.clone();
        let service_mode = mode.clone();
        let service = service_fn(move |request: Request<Incoming>| {
            let records = service_records.clone();
            let mode = service_mode.clone();
            async move {
                let authority = request.uri().authority().map(ToString::to_string);
                let method = request.method().clone();
                let path = request.uri().path().to_owned();
                let query = request.uri().query().map(ToOwned::to_owned);
                let headers = request.headers().clone();
                let body = request.into_body();
                let (body, body_hash, body_len) = request_body(&mode, body).await;
                records.lock().expect("records lock").push(RequestRecord {
                    authority,
                    body: body.clone(),
                    body_hash,
                    body_len,
                    headers,
                    method,
                    path: path.clone(),
                    query: query.clone(),
                });

                let response =
                    upstream_response(mode, path.as_str(), query.as_deref(), body, body_hash).await;
                Ok::<_, std::convert::Infallible>(response)
            }
        });

        let result = if is_h2 {
            server_conn::http2::Builder::new(TokioExecutor::new())
                .serve_connection(TokioIo::new(tls), service)
                .await
        } else {
            server_conn::http1::Builder::new()
                .serve_connection(TokioIo::new(tls), service)
                .with_upgrades()
                .await
        };
        result.map_err(|error| io::Error::other(error.to_string()))?;
        Ok(())
    });

    HttpUpstream {
        done,
        port,
        records,
    }
}

pub struct ReceiverBody {
    receiver: mpsc::Receiver<Result<Frame<Bytes>, io::Error>>,
    closed: bool,
}

fn queued_body(bytes: Bytes) -> ReceiverBody {
    let (sender, receiver) = mpsc::channel(1);
    sender.try_send(Ok(Frame::data(bytes))).expect("queue body");
    ReceiverBody::new(receiver)
}

impl ReceiverBody {
    pub fn new(receiver: mpsc::Receiver<Result<Frame<Bytes>, io::Error>>) -> Self {
        Self {
            receiver,
            closed: false,
        }
    }

    fn closed() -> Self {
        let (_sender, receiver) = mpsc::channel(1);
        Self {
            receiver,
            closed: true,
        }
    }
}

impl Body for ReceiverBody {
    type Data = Bytes;
    type Error = io::Error;

    fn poll_frame(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        if self.closed {
            return std::task::Poll::Ready(None);
        }
        match self.receiver.poll_recv(cx) {
            std::task::Poll::Pending => std::task::Poll::Pending,
            std::task::Poll::Ready(None) => std::task::Poll::Ready(None),
            std::task::Poll::Ready(Some(Err(error))) => std::task::Poll::Ready(Some(Err(error))),
            std::task::Poll::Ready(Some(Ok(frame))) => std::task::Poll::Ready(Some(Ok(frame))),
        }
    }
}

enum ClientSender {
    Http1(conn::http1::SendRequest<ReceiverBody>),
    Http2(conn::http2::SendRequest<ReceiverBody>),
}

pub struct HttpClient {
    sender: ClientSender,
    task: JoinHandle<()>,
}

impl Drop for HttpClient {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl HttpClient {
    pub async fn connect(server: &Running, upstream_port: u16, protocol: HttpProtocol) -> Self {
        let tls = server
            .handshake(upstream_port, "localhost", protocol.client_alpn(), true)
            .await
            .expect("client handshake");
        let (sender, task) = match protocol {
            HttpProtocol::Http1 => {
                let (sender, connection) =
                    conn::http1::handshake::<_, ReceiverBody>(TokioIo::new(tls))
                        .await
                        .expect("HTTP/1 client handshake");
                let task = tokio::spawn(async move {
                    let _ = connection.with_upgrades().await;
                });
                (ClientSender::Http1(sender), task)
            }
            HttpProtocol::Http2 => {
                let (sender, connection) = conn::http2::handshake::<_, _, ReceiverBody>(
                    TokioExecutor::new(),
                    TokioIo::new(tls),
                )
                .await
                .expect("HTTP/2 client handshake");
                let task = tokio::spawn(async move {
                    let _ = connection.await;
                });
                (ClientSender::Http2(sender), task)
            }
        };
        Self { sender, task }
    }

    pub async fn send(&mut self, request: Request<ReceiverBody>) -> Response<Incoming> {
        match &mut self.sender {
            ClientSender::Http1(sender) => sender.send_request(request).await.expect("send"),
            ClientSender::Http2(sender) => sender.send_request(request).await.expect("send"),
        }
    }

    pub fn http2_sender(&self) -> conn::http2::SendRequest<ReceiverBody> {
        let ClientSender::Http2(sender) = &self.sender else {
            panic!("HTTP/1 senders are not cloneable");
        };
        sender.clone()
    }
}

pub fn request(
    method: &str,
    path: &str,
    headers: &[(HeaderName, &'static str)],
    body: ReceiverBody,
) -> Request<ReceiverBody> {
    let mut builder = Request::builder()
        .method(method)
        .uri(Uri::try_from(path).expect("request URI"));
    for (name, value) in headers {
        builder = builder.header(name, *value);
    }
    builder.body(body).expect("request")
}

pub fn full_body(bytes: &'static [u8]) -> ReceiverBody {
    let (sender, receiver) = mpsc::channel(1);
    sender
        .try_send(Ok(Frame::data(Bytes::from_static(bytes))))
        .expect("queue body");
    ReceiverBody::new(receiver)
}

pub fn owned_body(bytes: Vec<u8>) -> ReceiverBody {
    queued_body(Bytes::from(bytes))
}

pub fn streaming_body(
    capacity: usize,
) -> (mpsc::Sender<Result<Frame<Bytes>, io::Error>>, ReceiverBody) {
    let (sender, receiver) = mpsc::channel(capacity);
    (sender, ReceiverBody::new(receiver))
}

pub const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;

pub fn fnv1a_test(hash: u64, bytes: &[u8]) -> u64 {
    bytes.iter().fold(hash, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

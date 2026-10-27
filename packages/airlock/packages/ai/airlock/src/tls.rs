//! TLS interception for selected CONNECT destinations: which destinations are
//! selected, which upstream roots are trusted, and the two handshakes that put
//! Airlock between the client and the upstream. `inner` serves the HTTP inside.
// cspell:words alpn
use std::{collections::BTreeSet, fs, io, path::Path, sync::Arc, time::Duration};

use rustls::{
    ClientConfig, RootCertStore, ServerConfig,
    crypto::CryptoProvider,
    pki_types::{DnsName, ServerName},
    server::{Acceptor, ServerSessionMemoryCache},
};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::TcpStream,
    time::{Instant, timeout_at},
};
use tokio_rustls::{LazyConfigAcceptor, TlsConnector, client, server};

use crate::{authority, ca::Authority, config, inner, upstream::connect_upstream};

// Bounds the client hello, the upstream connection and both TLS handshakes.
const TLS_SETUP_TIMEOUT: Duration = Duration::from_secs(10);
// rustls's default size for a server's session cache.
const SESSION_CACHE_SIZE: usize = 256;

pub(crate) struct Interceptor {
    authority: Authority,
    destinations: BTreeSet<(String, u16)>,
    upstream: Arc<ClientConfig>,
    // Each handshake gets a fresh server config; sharing the session cache
    // still lets a client resume an earlier session.
    sessions: Arc<ServerSessionMemoryCache>,
}

impl Interceptor {
    pub(crate) fn open(config: &config::Interception) -> io::Result<Self> {
        let destinations = parse_destinations(&config.destinations)?;
        let mut upstream = ClientConfig::builder_with_provider(provider())
            .with_safe_default_protocol_versions()
            .map_err(io::Error::other)?
            .with_root_certificates(load_roots(config.upstream_roots.as_deref())?)
            .with_no_client_auth();
        upstream.alpn_protocols = alpn_protocols();
        let authority = Authority::open(
            &config.ca_directory,
            destinations.iter().map(|(host, _)| host),
        )
        .map_err(io::Error::other)?;
        Ok(Self {
            authority,
            destinations,
            upstream: Arc::new(upstream),
            sessions: ServerSessionMemoryCache::new(SESSION_CACHE_SIZE),
        })
    }

    /// The configured name when `host:port` is selected for interception.
    pub(crate) fn selected_name(&self, host: &str, port: u16) -> Option<String> {
        let host = without_root_dot(host);
        self.destinations
            .contains(&(host.to_owned(), port))
            .then(|| host.to_owned())
    }

    pub(crate) async fn relay(
        self: Arc<Self>,
        client: impl AsyncRead + AsyncWrite + Unpin + Send + 'static,
        host: String,
        port: u16,
    ) -> io::Result<()> {
        let deadline = Instant::now() + TLS_SETUP_TIMEOUT;
        let (client, upstream) = timeout_at(deadline, self.accept_and_connect(client, &host, port))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "TLS setup timed out"))??;
        inner::serve(client, upstream, host, port).await
    }

    /// Read the client hello, connect and authenticate the upstream, then
    /// finish the client handshake with a leaf for `host`.
    async fn accept_and_connect<C: AsyncRead + AsyncWrite + Unpin>(
        &self,
        client: C,
        host: &str,
        port: u16,
    ) -> io::Result<(server::TlsStream<C>, client::TlsStream<TcpStream>)> {
        let hello = LazyConfigAcceptor::new(Acceptor::default(), client).await?;
        if hello.client_hello().server_name() != Some(host) {
            return Err(io::Error::other("TLS SNI must match CONNECT destination"));
        }
        let socket = connect_upstream(host.to_owned(), port).await?;
        let name = ServerName::try_from(host.to_owned()).map_err(io::Error::other)?;
        // Authentication must finish before Airlock presents a trusted leaf.
        let upstream = TlsConnector::from(Arc::clone(&self.upstream))
            .connect(name, socket)
            .await?;
        let client = hello.into_stream(self.server_config(host)?).await?;
        Ok((client, upstream))
    }

    fn server_config(&self, host: &str) -> io::Result<Arc<ServerConfig>> {
        let leaf = self.authority.leaf_for(host).map_err(io::Error::other)?;
        let mut config = ServerConfig::builder_with_provider(provider())
            .with_safe_default_protocol_versions()
            .map_err(io::Error::other)?
            .with_no_client_auth()
            .with_single_cert(vec![leaf.certificate.clone()], leaf.key.clone_key().into())
            .map_err(io::Error::other)?;
        config.alpn_protocols = alpn_protocols();
        config.session_storage = Arc::clone(&self.sessions) as _;
        Ok(Arc::new(config))
    }
}

/// Parse `host:port` destinations, keeping DNS names only: a leaf certificate
/// can name a DNS host, and an IP literal never arrives as TLS SNI.
fn parse_destinations(destinations: &[String]) -> io::Result<BTreeSet<(String, u16)>> {
    let mut parsed = BTreeSet::new();
    for destination in destinations {
        let (host, port) = authority::parse(destination, None)
            .filter(|(host, _)| DnsName::try_from(host.as_str()).is_ok())
            .ok_or_else(|| io::Error::other("interception requires DNS-name:port destinations"))?;
        if !parsed.insert((without_root_dot(&host).to_owned(), port)) {
            return Err(io::Error::other("duplicate interception destination"));
        }
    }
    if parsed.is_empty() {
        return Err(io::Error::other("interception requires destinations"));
    }
    Ok(parsed)
}

// `name.` and `name` are the same DNS name; without this, a CONNECT to the
// absolute form would bypass interception as an opaque tunnel.
fn without_root_dot(host: &str) -> &str {
    host.strip_suffix('.').unwrap_or(host)
}

/// The system trust store plus an optional PEM bundle of extra roots.
fn load_roots(extra: Option<&Path>) -> io::Result<RootCertStore> {
    let mut roots = RootCertStore::empty();
    for certificate in rustls_native_certs::load_native_certs().certs {
        roots.add(certificate).map_err(io::Error::other)?;
    }
    if let Some(path) = extra {
        let certificates = pem::parse_many(fs::read(path)?).map_err(io::Error::other)?;
        if certificates.is_empty() || certificates.iter().any(|pem| pem.tag() != "CERTIFICATE") {
            return Err(io::Error::other(
                "upstream roots must contain PEM certificates",
            ));
        }
        for certificate in certificates {
            roots
                .add(certificate.into_contents().into())
                .map_err(io::Error::other)?;
        }
    }
    if roots.is_empty() {
        return Err(io::Error::other("no upstream trust roots available"));
    }
    Ok(roots)
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

fn alpn_protocols() -> Vec<Vec<u8>> {
    vec![b"http/1.1".to_vec()]
}

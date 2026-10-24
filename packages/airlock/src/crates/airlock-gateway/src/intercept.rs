//! Passthrough interception: terminate the client's TLS, open verified TLS upstream, relay bytes.

use std::{path::Path, sync::Arc, time::Duration};

use airlock_core::{ids::HostName, target::ConnectTarget};
use hyper::upgrade::Upgraded;
use hyper_util::rt::TokioIo;
use rustls::{
    ClientConfig, RootCertStore, ServerConfig, crypto::CryptoProvider, pki_types::ServerName,
    server::Acceptor, sign::SingleCertAndKey,
};
use tokio::{net::TcpStream, time::timeout};
use tokio_rustls::{LazyConfigAcceptor, TlsConnector, client};

use crate::{Audit, CONNECT_TIMEOUT, Error, ca::Authority, relay};

// A client gets this long to send its ClientHello, and later to finish its handshake.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

pub(crate) struct Interceptor {
    authority: Authority,
    provider: Arc<CryptoProvider>,
    upstream: Arc<ClientConfig>,
}

impl Interceptor {
    pub(crate) fn new(ca_directory: &Path, upstream_roots: RootCertStore) -> Result<Self, Error> {
        if upstream_roots.is_empty() {
            return Err(Error::NoUpstreamRoots);
        }
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let upstream = ClientConfig::builder_with_provider(provider.clone())
            .with_safe_default_protocol_versions()?
            .with_root_certificates(upstream_roots)
            .with_no_client_auth();
        Ok(Self {
            authority: Authority::open(ca_directory, provider.clone())?,
            provider,
            upstream: Arc::new(upstream),
        })
    }

    pub(crate) async fn run(
        &self,
        client: TokioIo<Upgraded>,
        target: ConnectTarget,
        mut audit: Audit,
    ) {
        // A timeout, a non-handshake first record and an unparseable hello all mean "not TLS".
        let Ok(Ok(start)) = timeout(
            HANDSHAKE_TIMEOUT,
            LazyConfigAcceptor::new(Acceptor::default(), client),
        )
        .await
        else {
            audit.outcome = "not_tls";
            return;
        };
        let hello = start.client_hello();
        let Some(sni) = hello.server_name().map(str::to_owned) else {
            audit.outcome = "sni_missing";
            return;
        };
        let offered = hello
            .alpn()
            .into_iter()
            .flatten()
            .map(<[u8]>::to_vec)
            .collect();
        // Without this a client could CONNECT to one host and speak TLS to another under its leaf.
        let matches = HostName::try_from(sni.as_str()).is_ok_and(|host| host == *target.host());
        audit.sni = Some(sni);
        if !matches {
            audit.outcome = "sni_mismatch";
            return;
        }
        // Dropping `start` on any failure below closes the client before its handshake completes.
        let upstream = match self.connect(&target, offered).await {
            Ok(upstream) => upstream,
            Err(outcome) => {
                audit.outcome = outcome;
                return;
            }
        };
        let negotiated = upstream.get_ref().1.alpn_protocol().map(<[u8]>::to_vec);
        audit.alpn = negotiated
            .as_deref()
            .map(|protocol| String::from_utf8_lossy(protocol).into_owned());
        let Ok(config) = self.server_config(target.host(), negotiated) else {
            audit.outcome = "leaf_error";
            return;
        };
        let Ok(Ok(client)) = timeout(HANDSHAKE_TIMEOUT, start.into_stream(config)).await else {
            audit.outcome = "client_tls_error";
            return;
        };
        relay(client, upstream, audit).await;
    }

    /// Opens verified TLS to the real host, offering exactly the client's ALPN list.
    async fn connect(
        &self,
        target: &ConnectTarget,
        alpn: Vec<Vec<u8>>,
    ) -> Result<client::TlsStream<TcpStream>, &'static str> {
        let name = ServerName::try_from(target.host().as_ref().to_owned())
            .map_err(|_| "upstream_tls_error")?;
        let mut config = (*self.upstream).clone();
        config.alpn_protocols = alpn;
        let connector = TlsConnector::from(Arc::new(config));
        timeout(CONNECT_TIMEOUT, async {
            let socket = TcpStream::connect((target.host().as_ref(), target.port()))
                .await
                .map_err(|_| "connect_error")?;
            connector
                .connect(name, socket)
                .await
                .map_err(|_| "upstream_tls_error")
        })
        .await
        .map_err(|_| "connect_timeout")?
    }

    /// Presents the host's leaf and offers only the protocol the upstream chose.
    fn server_config(
        &self,
        host: &HostName,
        alpn: Option<Vec<u8>>,
    ) -> Result<Arc<ServerConfig>, Error> {
        let mut config = ServerConfig::builder_with_provider(self.provider.clone())
            .with_safe_default_protocol_versions()?
            .with_no_client_auth()
            .with_cert_resolver(Arc::new(SingleCertAndKey::from(self.authority.leaf(host)?)));
        config.alpn_protocols = alpn.into_iter().collect();
        Ok(Arc::new(config))
    }
}

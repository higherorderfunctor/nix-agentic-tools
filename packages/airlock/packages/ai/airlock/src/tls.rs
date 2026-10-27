// cspell:words alpn keepalive
use std::{collections::BTreeSet, convert::Infallible, fs, io, sync::Arc};

use http_body_util::Either;
use hyper::{
    Method, Request, StatusCode,
    body::Incoming,
    header::{HOST, UPGRADE},
    service::service_fn,
};
use hyper_util::rt::{TokioIo, TokioTimer};
use rustls::{
    ClientConfig, RootCertStore,
    pki_types::{DnsName, ServerName},
};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::Mutex,
    time::{Instant, timeout_at},
};
use tokio_rustls::{LazyConfigAcceptor, TlsConnector};

use crate::{
    ca::Authority,
    config, forward,
    tunnel::{self, CONNECT_TIMEOUT},
};

pub(crate) struct Interception {
    authority: Authority,
    destinations: BTreeSet<(String, u16)>,
    upstream: Arc<ClientConfig>,
}

impl Interception {
    pub(crate) fn open(config: config::Interception) -> io::Result<Self> {
        let mut destinations = BTreeSet::new();
        for destination in config.destinations {
            let (host, port) = tunnel::parse_authority(&destination, None)
                .filter(|(host, _)| DnsName::try_from(host.as_str()).is_ok())
                .ok_or_else(|| {
                    io::Error::other("interception requires DNS-name:port destinations")
                })?;
            if !destinations.insert((host, port)) {
                return Err(io::Error::other("duplicate interception destination"));
            }
        }
        if destinations.is_empty() {
            return Err(io::Error::other("interception requires destinations"));
        }
        let mut roots = RootCertStore::empty();
        for certificate in rustls_native_certs::load_native_certs().certs {
            roots.add(certificate).map_err(io::Error::other)?;
        }
        if let Some(path) = config.upstream_roots {
            let certificates = pem::parse_many(fs::read(path)?).map_err(io::Error::other)?;
            if certificates.is_empty() || certificates.iter().any(|pem| pem.tag() != "CERTIFICATE")
            {
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
        let mut upstream =
            ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .map_err(io::Error::other)?
                .with_root_certificates(roots)
                .with_no_client_auth();
        upstream.alpn_protocols = vec![b"http/1.1".to_vec()];
        let authority = Authority::open(
            config.ca_directory,
            destinations.iter().map(|(host, _)| host),
        )
        .map_err(io::Error::other)?;
        Ok(Self {
            authority,
            destinations,
            upstream: Arc::new(upstream),
        })
    }

    pub(crate) fn selected(&self, host: &str, port: u16) -> bool {
        self.destinations.contains(&(host.to_owned(), port))
    }

    pub(crate) async fn relay(
        self: Arc<Self>,
        client: impl AsyncRead + AsyncWrite + Unpin + Send + 'static,
        host: String,
        port: u16,
    ) -> io::Result<()> {
        let deadline = Instant::now() + CONNECT_TIMEOUT;
        let setup = async {
            let hello =
                LazyConfigAcceptor::new(rustls::server::Acceptor::default(), client).await?;
            if hello.client_hello().server_name() != Some(host.as_str()) {
                return Err(io::Error::other("TLS SNI must match CONNECT destination"));
            }
            let socket = tunnel::dial(host.clone(), port).await?;
            let name = ServerName::try_from(host.clone()).map_err(io::Error::other)?;
            // Authentication must finish before Airlock presents a trusted leaf.
            let upstream = TlsConnector::from(Arc::clone(&self.upstream))
                .connect(name, socket)
                .await?;
            let config = self.authority.config_for(&host).map_err(io::Error::other)?;
            let client = hello.into_stream(config).await?;
            Ok::<_, io::Error>((client, upstream))
        };
        let (client, upstream) = timeout_at(deadline, setup)
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "TLS setup timed out"))??;
        let (sender, driver) = hyper::client::conn::http1::handshake(TokioIo::new(upstream))
            .await
            .map_err(io::Error::other)?;
        let sender = Arc::new(Mutex::new(sender));
        let service = service_fn(move |request| {
            let sender = Arc::clone(&sender);
            let host = host.clone();
            async move { Ok::<_, Infallible>(inner(request, &host, port, sender).await) }
        });
        let downstream = hyper::server::conn::http1::Builder::new()
            .timer(TokioTimer::new())
            .header_read_timeout(CONNECT_TIMEOUT)
            .half_close(true)
            .serve_connection(TokioIo::new(client), service);
        // Driver completion closes keepalive but drains any active response.
        // Both futures remain owned by the outer connection's cancellation.
        tokio::pin!(downstream);
        tokio::select! {
            result = &mut downstream => result.map_err(io::Error::other),
            _ = driver => {
                downstream.as_mut().graceful_shutdown();
                downstream.await.map_err(io::Error::other)
            },
        }
    }
}

async fn inner(
    mut request: Request<Incoming>,
    host: &str,
    port: u16,
    sender: Arc<Mutex<hyper::client::conn::http1::SendRequest<Incoming>>>,
) -> forward::ProxyResponse {
    let bound = |authority: &str| {
        tunnel::parse_authority(authority, Some(443)) == Some((host.to_owned(), port))
    };
    let hosts = request.headers().get_all(HOST);
    let mut hosts = hosts.iter();
    if request.method() == Method::CONNECT
        || request.headers().contains_key(UPGRADE)
        || !hosts
            .next()
            .and_then(|value| value.to_str().ok())
            .is_some_and(bound)
        || hosts.next().is_some()
        || request
            .uri()
            .scheme()
            .is_some_and(|scheme| scheme.as_str() != "https")
        || request
            .uri()
            .authority()
            .is_some_and(|authority| !bound(authority.as_str()))
        || !request.uri().path().starts_with('/')
    {
        return forward::response(
            StatusCode::BAD_REQUEST,
            "inner request must match CONNECT destination",
        );
    }
    if let Err((status, message)) = forward::prepare_request(&mut request) {
        return forward::response(status, message);
    }
    request
        .headers_mut()
        .insert(HOST, format!("{host}:{port}").parse().unwrap());
    *request.uri_mut() = request
        .uri()
        .path_and_query()
        .unwrap()
        .as_str()
        .parse()
        .unwrap();
    let result = async {
        let mut sender = sender.lock().await;
        sender.ready().await?;
        sender.send_request(request).await
    }
    .await;
    let mut response = match result {
        Ok(response) => response,
        _ => return forward::response(StatusCode::BAD_GATEWAY, "upstream request failed"),
    };
    if response.status() == StatusCode::SWITCHING_PROTOCOLS {
        return forward::response(StatusCode::BAD_GATEWAY, "upstream upgrade is unsupported");
    }
    if let Err(message) = forward::prepare_response(&mut response) {
        return forward::response(StatusCode::BAD_GATEWAY, message);
    }
    response.map(Either::Right)
}

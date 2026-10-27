// cspell:words alpn keepalive
use std::{
    collections::BTreeSet, convert::Infallible, fs, future::Future, io, pin::Pin, sync::Arc,
};

use http_body_util::Either;
use hyper::{
    Method, Request, StatusCode, Version,
    body::Incoming,
    header::{HOST, UPGRADE},
    service::service_fn,
};
use hyper_util::{
    rt::{TokioIo, TokioTimer},
    server::conn::auto,
};
use rustls::{
    ClientConfig, RootCertStore,
    pki_types::{DnsName, ServerName},
};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::{Mutex, Notify},
    time::{Instant, sleep, timeout_at},
};
use tokio_rustls::{LazyConfigAcceptor, TlsConnector};

use crate::{
    authority,
    ca::Authority,
    config, forward,
    tls_tasks::Tasks,
    upstream::{CONNECT_TIMEOUT, connect_upstream},
};

type Driver = Pin<Box<dyn Future<Output = Result<(), hyper::Error>> + Send>>;

pub(crate) struct Interception {
    authority: Authority,
    destinations: BTreeSet<(String, u16)>,
    upstream: Arc<ClientConfig>,
}

impl Interception {
    pub(crate) fn open(config: config::Interception) -> io::Result<Self> {
        let mut destinations = BTreeSet::new();
        for destination in config.destinations {
            let (host, port) = authority::parse(&destination, None)
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
        upstream.alpn_protocols = alpn_protocols();
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
            let socket = connect_upstream(host.clone(), port).await?;
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
        let downstream_version = version(client.get_ref().1.alpn_protocol())?;
        let upstream_version = version(upstream.get_ref().1.alpn_protocol())?;
        let tasks = Tasks::new();
        let executor = tasks.executor();
        let (sender, driver): (Sender, Driver) = if upstream_version == Version::HTTP_2 {
            let (sender, driver) = timeout_at(
                deadline,
                hyper::client::conn::http2::handshake(executor.clone(), TokioIo::new(upstream)),
            )
            .await
            .map_err(|_| {
                io::Error::new(io::ErrorKind::TimedOut, "upstream HTTP/2 setup timed out")
            })?
            .map_err(io::Error::other)?;
            (Sender::H2(sender), Box::pin(driver))
        } else {
            let (sender, driver) = hyper::client::conn::http1::handshake(TokioIo::new(upstream))
                .await
                .map_err(io::Error::other)?;
            (Sender::H1(Arc::new(Mutex::new(sender))), Box::pin(driver))
        };
        let started = Arc::new(Notify::new());
        let observed = Arc::clone(&started);
        let service = service_fn(move |request| {
            observed.notify_one();
            let sender = sender.clone();
            let host = host.clone();
            async move { Ok::<_, Infallible>(inner(request, &host, port, sender).await) }
        });
        let mut builder = auto::Builder::new(executor);
        builder
            .http1()
            .timer(TokioTimer::new())
            .header_read_timeout(CONNECT_TIMEOUT)
            .half_close(true);
        builder.http2().max_concurrent_streams(32);
        let builder = if downstream_version == Version::HTTP_2 {
            builder.http2_only()
        } else {
            builder.http1_only()
        };
        let downstream = builder.serve_connection(TokioIo::new(client), service);
        // Driver completion disables keepalive and drains active responses;
        // session cancellation drops all internal H2 futures as well as drivers.
        tokio::pin!(downstream);
        let traffic = async {
            tokio::select! {
                result = &mut downstream => result.map_err(io::Error::other),
                _ = driver => {
                    downstream.as_mut().graceful_shutdown();
                    downstream.await.map_err(io::Error::other)
                },
            }
        };
        let initial = async {
            tokio::select! {
                _ = started.notified() => std::future::pending::<()>().await,
                _ = sleep(CONNECT_TIMEOUT) => {},
            }
        };
        tokio::select! {
            result = traffic => result,
            result = tasks.run() => result,
            () = initial => Err(io::Error::new(io::ErrorKind::TimedOut, "initial inner HTTP request timed out")),
        }
    }
}

async fn inner(
    mut request: Request<Incoming>,
    host: &str,
    port: u16,
    sender: Sender,
) -> forward::ProxyResponse {
    let downstream_version = request.version();
    let bound =
        |authority: &str| authority::parse(authority, Some(443)) == Some((host.to_owned(), port));
    let hosts = request.headers().get_all(HOST);
    let mut hosts = hosts.iter();
    if request.method() == Method::CONNECT
        || request.headers().contains_key(UPGRADE)
        || match hosts.next() {
            Some(value) => !value.to_str().ok().is_some_and(bound),
            None => downstream_version != Version::HTTP_2,
        }
        || hosts.next().is_some()
        || request
            .uri()
            .scheme()
            .is_some_and(|scheme| scheme.as_str() != "https")
        || request
            .uri()
            .authority()
            .is_some_and(|authority| !bound(authority.as_str()))
        || (downstream_version == Version::HTTP_2
            && (request.uri().scheme().is_none() || request.uri().authority().is_none()))
        || !request.uri().path().starts_with('/')
    {
        return forward::response(
            StatusCode::BAD_REQUEST,
            "inner request must match CONNECT destination",
        );
    }
    if let Err((status, message)) = forward::prepare_request(&mut request, sender.version()) {
        return forward::response(status, message);
    }
    request
        .headers_mut()
        .insert(HOST, format!("{host}:{port}").parse().unwrap());
    let path = request.uri().path_and_query().unwrap().as_str();
    *request.uri_mut() = if sender.version() == Version::HTTP_2 {
        format!("https://{host}:{port}{path}").parse().unwrap()
    } else {
        path.parse().unwrap()
    };
    let result = sender.send(request).await;
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
    *response.version_mut() = downstream_version;
    response.map(Either::Right)
}

pub(crate) fn alpn_protocols() -> Vec<Vec<u8>> {
    vec![b"h2".to_vec(), b"http/1.1".to_vec()]
}

fn version(alpn: Option<&[u8]>) -> io::Result<Version> {
    match alpn {
        Some(b"h2") => Ok(Version::HTTP_2),
        Some(b"http/1.1") | None => Ok(Version::HTTP_11),
        _ => Err(io::Error::other("unsupported negotiated ALPN")),
    }
}

#[derive(Clone)]
enum Sender {
    H1(Arc<Mutex<hyper::client::conn::http1::SendRequest<Incoming>>>),
    H2(hyper::client::conn::http2::SendRequest<Incoming>),
}

impl Sender {
    fn version(&self) -> Version {
        match self {
            Self::H1(_) => Version::HTTP_11,
            Self::H2(_) => Version::HTTP_2,
        }
    }

    async fn send(
        &self,
        request: Request<Incoming>,
    ) -> Result<hyper::Response<Incoming>, hyper::Error> {
        match self {
            Self::H1(sender) => {
                let mut sender = sender.lock().await;
                sender.ready().await?;
                sender.send_request(request).await
            }
            Self::H2(sender) => sender.clone().send_request(request).await,
        }
    }
}

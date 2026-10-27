//! HTTP inside an intercepted TLS session: serve the client's requests over the
//! HTTP version its TLS leg negotiated, check that each one targets the CONNECT
//! destination, and send it upstream over the version that leg negotiated.
// cspell:words alpn keepalive
use std::{convert::Infallible, future::Future, io, pin::Pin, sync::Arc, time::Duration};

use http_body_util::Either;
use hyper::{
    Method, Request, Response, StatusCode, Version,
    body::Incoming,
    header::{HOST, HeaderValue, UPGRADE},
    service::service_fn,
};
use hyper_util::{
    rt::{TokioIo, TokioTimer},
    server::conn::auto,
};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::TcpStream,
    sync::{Mutex, Notify},
    time::{Instant, timeout_at},
};
use tokio_rustls::{client, server};

use crate::{
    authority,
    first_request::until_first_request,
    local::proxy_response,
    relayed::{ProxyResponse, prepare_request, prepare_response},
    session_executor::{INNER_MAX_STREAMS, SessionExecutor, SessionTasks},
};

// Bounds the head of each HTTP/1 request inside the TLS session.
const INNER_HEADER_TIMEOUT: Duration = Duration::from_secs(10);
// Closes a TLS session whose client never sends a request.
const FIRST_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

type Driver = Pin<Box<dyn Future<Output = Result<(), hyper::Error>> + Send>>;

/// Serve the client's decrypted requests until either side closes. The
/// upstream HTTP/2 handshake, if any, must finish by `setup_deadline`.
pub(crate) async fn serve<C: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
    client: server::TlsStream<C>,
    upstream: client::TlsStream<TcpStream>,
    setup_deadline: Instant,
    host: String,
    port: u16,
) -> io::Result<()> {
    let tasks = SessionTasks::new();
    let (sender, driver) = upstream_sender(upstream, setup_deadline, tasks.executor()).await?;
    let started = Arc::new(Notify::new());
    let destination = Destination { host, port, sender };
    let traffic = serve_inner(
        client,
        destination,
        driver,
        Arc::clone(&started),
        tasks.executor(),
    );
    let first_request_deadline = Instant::now() + FIRST_REQUEST_TIMEOUT;
    tokio::select! {
        result = until_first_request(&started, first_request_deadline, traffic) => {
            result.unwrap_or_else(|| Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "initial inner HTTP request timed out",
            )))
        }
        // The executor reports a session over its task bound.
        result = tasks.run() => result,
    }
}

/// Where a session's requests go: the CONNECT destination and the connection
/// to it.
#[derive(Clone)]
struct Destination {
    host: String,
    port: u16,
    sender: Sender,
}

/// The sending half of the upstream connection, in its negotiated version.
#[derive(Clone)]
enum Sender {
    // HTTP/1 carries one request at a time, so concurrent inner HTTP/2
    // streams wait here for the single upstream connection.
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

    async fn send(&self, request: Request<Incoming>) -> Result<Response<Incoming>, hyper::Error> {
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

/// Start an HTTP client on the upstream TLS stream, in the version its ALPN
/// chose. The returned driver runs the connection.
async fn upstream_sender(
    upstream: client::TlsStream<TcpStream>,
    setup_deadline: Instant,
    executor: SessionExecutor,
) -> io::Result<(Sender, Driver)> {
    if negotiated_version(upstream.get_ref().1.alpn_protocol())? == Version::HTTP_2 {
        let handshake = hyper::client::conn::http2::handshake(executor, TokioIo::new(upstream));
        let (sender, driver) = timeout_at(setup_deadline, handshake)
            .await
            .map_err(|_| {
                io::Error::new(io::ErrorKind::TimedOut, "upstream HTTP/2 setup timed out")
            })?
            .map_err(io::Error::other)?;
        Ok((Sender::H2(sender), Box::pin(driver)))
    } else {
        let (sender, driver) = hyper::client::conn::http1::handshake(TokioIo::new(upstream))
            .await
            .map_err(io::Error::other)?;
        Ok((Sender::H1(Arc::new(Mutex::new(sender))), Box::pin(driver)))
    }
}

/// Serve the client in the version its ALPN chose, until the client closes or
/// the upstream connection ends.
async fn serve_inner<C: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
    client: server::TlsStream<C>,
    destination: Destination,
    driver: Driver,
    started: Arc<Notify>,
    executor: SessionExecutor,
) -> io::Result<()> {
    let version = negotiated_version(client.get_ref().1.alpn_protocol())?;
    let service = service_fn(move |request| {
        started.notify_one();
        let destination = destination.clone();
        async move { Ok::<_, Infallible>(forward_inner_request(request, &destination).await) }
    });
    let mut builder = auto::Builder::new(executor);
    builder
        .http1()
        .timer(TokioTimer::new())
        .header_read_timeout(INNER_HEADER_TIMEOUT)
        .half_close(true);
    builder
        .http2()
        .max_concurrent_streams(INNER_MAX_STREAMS as u32);
    let builder = if version == Version::HTTP_2 {
        builder.http2_only()
    } else {
        builder.http1_only()
    };
    let downstream = builder.serve_connection(TokioIo::new(client), service);
    // Driver completion disables keepalive and drains active responses;
    // session cancellation drops all internal H2 futures as well as drivers.
    tokio::pin!(downstream);
    tokio::select! {
        result = &mut downstream => result.map_err(io::Error::other),
        _ = driver => {
            downstream.as_mut().graceful_shutdown();
            downstream.await.map_err(io::Error::other)
        },
    }
}

async fn forward_inner_request(
    mut request: Request<Incoming>,
    destination: &Destination,
) -> ProxyResponse {
    let Destination { host, port, sender } = destination;
    let client_version = request.version();
    let refused = || {
        proxy_response(
            StatusCode::BAD_REQUEST,
            "inner request must match CONNECT destination\n",
        )
    };
    if !targets_destination(&request, host, *port) {
        return refused();
    }
    if let Err((status, message)) = prepare_request(&mut request, sender.version()) {
        return proxy_response(status, message);
    }
    // After `prepare_request`, so a `Connection: host` token cannot strip it.
    if !address_upstream(&mut request, host, *port, sender.version()) {
        return refused();
    }
    let Ok(mut response) = sender.send(request).await else {
        return proxy_response(StatusCode::BAD_GATEWAY, "upstream request failed\n");
    };
    if response.status() == StatusCode::SWITCHING_PROTOCOLS {
        return proxy_response(StatusCode::BAD_GATEWAY, "upstream upgrade is unsupported\n");
    }
    if let Err(message) = prepare_response(&mut response) {
        return proxy_response(StatusCode::BAD_GATEWAY, message);
    }
    *response.version_mut() = client_version;
    response.map(Either::Right)
}

/// Whether `request` stays on the CONNECT destination, so a client cannot
/// reach another host through a tunnel Airlock decrypts.
fn targets_destination(request: &Request<Incoming>, host: &str, port: u16) -> bool {
    let names_destination =
        |authority: &str| authority::parse(authority, Some(443)) == Some((host.to_owned(), port));
    let uri = request.uri();
    let http2 = request.version() == Version::HTTP_2;
    // CONNECT and Upgrade would open another tunnel inside this one.
    let opens_tunnel =
        request.method() == Method::CONNECT || request.headers().contains_key(UPGRADE);
    // At most one Host header, naming the destination. HTTP/2 may omit it and
    // name the destination in `:authority` instead.
    let mut hosts = request.headers().get_all(HOST).iter();
    let host_matches = match hosts.next() {
        Some(value) => value.to_str().is_ok_and(names_destination),
        None => http2,
    } && hosts.next().is_none();
    // An absolute-form target must be `https` on the destination.
    let uri_matches = uri.scheme().is_none_or(|scheme| scheme.as_str() == "https")
        && uri
            .authority()
            .is_none_or(|authority| names_destination(authority.as_str()));
    // HTTP/2 requests always carry `:scheme` and `:authority`.
    let complete = !http2 || (uri.scheme().is_some() && uri.authority().is_some());
    !opens_tunnel && host_matches && uri_matches && complete && uri.path().starts_with('/')
}

/// Point `request` at the upstream: set Host, and use the target form the
/// upstream's version expects. False if either cannot be built.
fn address_upstream(
    request: &mut Request<Incoming>,
    host: &str,
    port: u16,
    version: Version,
) -> bool {
    let Some(path) = request.uri().path_and_query().map(|path| path.as_str()) else {
        return false;
    };
    let target = if version == Version::HTTP_2 {
        format!("https://{host}:{port}{path}").parse()
    } else {
        path.parse()
    };
    let (Ok(target), Ok(host)) = (target, HeaderValue::from_str(&format!("{host}:{port}"))) else {
        return false;
    };
    *request.uri_mut() = target;
    request.headers_mut().insert(HOST, host);
    true
}

/// The HTTP version a TLS leg's ALPN selected; no ALPN means HTTP/1.1.
fn negotiated_version(alpn: Option<&[u8]>) -> io::Result<Version> {
    match alpn {
        Some(b"h2") => Ok(Version::HTTP_2),
        Some(b"http/1.1") | None => Ok(Version::HTTP_11),
        _ => Err(io::Error::other("unsupported negotiated ALPN")),
    }
}

// cspell:words rsplit
use std::{
    convert::Infallible,
    future::Future,
    io,
    net::{IpAddr, Ipv6Addr, SocketAddr},
    time::Duration,
};

use http_body_util::Full;
use hyper::{
    Method, StatusCode, Uri,
    body::{Bytes, Incoming},
    server::conn::http1,
    service::service_fn,
    upgrade::OnUpgrade,
};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::{
    io::{AsyncRead, AsyncWrite, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::mpsc,
    task::JoinSet,
    time::timeout,
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const HEADER_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CONNECTIONS: usize = 128;
const SHUTDOWN_GRACE: Duration = Duration::from_secs(3);

pub async fn bind(listen: SocketAddr) -> io::Result<TcpListener> {
    if !listen.ip().is_loopback() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "listen address must be loopback",
        ));
    }

    TcpListener::bind(listen).await
}

pub async fn serve(listener: TcpListener, shutdown: impl Future<Output = ()>) -> io::Result<()> {
    let mut connections = JoinSet::new();
    tokio::pin!(shutdown);

    let result = loop {
        tokio::select! {
            biased;

            () = &mut shutdown => break Ok(()),
            _ = connections.join_next(), if !connections.is_empty() => {}
            accepted = listener.accept(), if connections.len() < MAX_CONNECTIONS => {
                match accepted {
                    Ok((socket, _)) => {
                        connections.spawn(connection(socket));
                    }
                    Err(error) => break Err(error),
                }
            }
        }
    };

    drop(listener);
    if timeout(SHUTDOWN_GRACE, async {
        while connections.join_next().await.is_some() {}
    })
    .await
    .is_err()
    {
        connections.abort_all();
        while connections.join_next().await.is_some() {}
    }

    result
}

async fn connection(socket: TcpStream) {
    let (sender, mut receiver) = mpsc::channel(1);
    let service = service_fn(move |request| handle(request, sender.clone()));

    let result = http1::Builder::new()
        .timer(TokioTimer::new())
        .header_read_timeout(HEADER_TIMEOUT)
        .serve_connection(TokioIo::new(socket), service)
        .with_upgrades()
        .await;

    if result.is_err() {
        return;
    }

    if let Some(pending) = receiver.recv().await
        && let Ok(upgraded) = pending.upgrade.await
    {
        relay(TokioIo::new(upgraded), pending.upstream).await;
    }
}

async fn handle(
    mut request: hyper::Request<Incoming>,
    sender: mpsc::Sender<PendingTunnel>,
) -> Result<hyper::Response<Full<Bytes>>, Infallible> {
    if *request.method() != Method::CONNECT {
        let mut response = response(StatusCode::METHOD_NOT_ALLOWED, "CONNECT required");
        response.headers_mut().insert(
            hyper::header::ALLOW,
            hyper::header::HeaderValue::from_static("CONNECT"),
        );
        return Ok(response);
    }

    let Some((host, port)) = ConnectTarget::parse(request.uri()) else {
        return Ok(response(
            StatusCode::BAD_REQUEST,
            "malformed CONNECT target",
        ));
    };

    let upstream = match timeout(CONNECT_TIMEOUT, TcpStream::connect((host.as_str(), port))).await {
        Ok(Ok(upstream)) => upstream,
        Ok(Err(_)) => {
            return Ok(response(
                StatusCode::BAD_GATEWAY,
                "upstream connection failed",
            ));
        }
        Err(_) => {
            return Ok(response(
                StatusCode::GATEWAY_TIMEOUT,
                "upstream connection timed out",
            ));
        }
    };

    let pending = PendingTunnel {
        upgrade: hyper::upgrade::on(&mut request),
        upstream,
    };
    if sender.send(pending).await.is_err() {
        return Ok(response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "tunnel connection closed",
        ));
    }

    Ok(response(StatusCode::OK, ""))
}

struct PendingTunnel {
    upgrade: OnUpgrade,
    upstream: TcpStream,
}

fn response(status: StatusCode, body: &'static str) -> hyper::Response<Full<Bytes>> {
    hyper::Response::builder()
        .status(status)
        .body(Full::new(Bytes::from_static(body.as_bytes())))
        .expect("static HTTP response is valid")
}

async fn relay<Client, Upstream>(mut client: Client, mut upstream: Upstream)
where
    Client: AsyncRead + AsyncWrite + Unpin,
    Upstream: AsyncRead + AsyncWrite + Unpin,
{
    let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await;
    let _ = client.shutdown().await;
    let _ = upstream.shutdown().await;
}

struct ConnectTarget;

impl ConnectTarget {
    fn parse(uri: &Uri) -> Option<(String, u16)> {
        if uri.scheme().is_some() || uri.path() != "" || uri.path_and_query().is_some() {
            return None;
        }

        let authority = uri.authority()?.as_str();
        parse_authority(authority)
    }
}

fn parse_authority(authority: &str) -> Option<(String, u16)> {
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let end = rest.find(']')?;
        let host = &rest[..end];
        let suffix = &rest[end + 1..];
        let port = suffix.strip_prefix(':')?;
        host.parse::<Ipv6Addr>().ok()?;
        (host, port)
    } else {
        let (host, port) = authority.rsplit_once(':')?;
        (host, port)
    };

    if port.is_empty() || !port.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let port = port.parse::<u16>().ok()?;
    if port == 0 || host.is_empty() || !valid_host(host) {
        return None;
    }

    Some((host.to_ascii_lowercase(), port))
}

fn valid_host(host: &str) -> bool {
    if host.parse::<IpAddr>().is_ok() {
        return true;
    }
    if host.len() > 253 {
        return false;
    }

    host.split('.').all(|label| {
        let length = label.len();
        length > 0
            && length <= 63
            && label
                .bytes()
                .next()
                .is_some_and(|byte| byte.is_ascii_alphanumeric())
            && label
                .bytes()
                .next_back()
                .is_some_and(|byte| byte.is_ascii_alphanumeric())
            && label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    })
}

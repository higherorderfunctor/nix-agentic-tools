//! HTTP inside an intercepted TLS session: serve the client's requests, check
//! that each one targets the CONNECT destination, and send it upstream.
// cspell:words keepalive
use std::{convert::Infallible, io, sync::Arc, time::Duration};

use http_body_util::Either;
use hyper::{
    Method, Request, StatusCode,
    body::Incoming,
    client::conn::http1::SendRequest,
    header::{HOST, HeaderValue, UPGRADE},
    service::service_fn,
};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::Mutex,
};

use crate::{
    authority,
    local::proxy_response,
    relayed::{ProxyResponse, prepare_request, prepare_response},
};

// Bounds the head of each request inside the TLS session.
const INNER_HEADER_TIMEOUT: Duration = Duration::from_secs(10);

/// Serve the client's decrypted requests until either side closes.
pub(crate) async fn serve(
    client: impl AsyncRead + AsyncWrite + Unpin + Send + 'static,
    upstream: impl AsyncRead + AsyncWrite + Unpin + Send + 'static,
    host: String,
    port: u16,
) -> io::Result<()> {
    let (sender, driver) = hyper::client::conn::http1::handshake(TokioIo::new(upstream))
        .await
        .map_err(io::Error::other)?;
    let sender = Arc::new(Mutex::new(sender));
    let service = service_fn(move |request| {
        let sender = Arc::clone(&sender);
        let host = host.clone();
        async move { Ok::<_, Infallible>(forward_inner_request(request, &host, port, &sender).await) }
    });
    let downstream = hyper::server::conn::http1::Builder::new()
        .timer(TokioTimer::new())
        .header_read_timeout(INNER_HEADER_TIMEOUT)
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

async fn forward_inner_request(
    mut request: Request<Incoming>,
    host: &str,
    port: u16,
    sender: &Mutex<SendRequest<Incoming>>,
) -> ProxyResponse {
    let refused = || {
        proxy_response(
            StatusCode::BAD_REQUEST,
            "inner request must match CONNECT destination\n",
        )
    };
    if !targets_destination(&request, host, port) {
        return refused();
    }
    if let Err((status, message)) = prepare_request(&mut request) {
        return proxy_response(status, message);
    }
    // After `prepare_request`, so a `Connection: host` token cannot strip it.
    if !address_upstream(&mut request, host, port) {
        return refused();
    }
    let result = async {
        let mut sender = sender.lock().await;
        sender.ready().await?;
        sender.send_request(request).await
    }
    .await;
    let Ok(mut response) = result else {
        return proxy_response(StatusCode::BAD_GATEWAY, "upstream request failed\n");
    };
    if response.status() == StatusCode::SWITCHING_PROTOCOLS {
        return proxy_response(StatusCode::BAD_GATEWAY, "upstream upgrade is unsupported\n");
    }
    if let Err(message) = prepare_response(&mut response) {
        return proxy_response(StatusCode::BAD_GATEWAY, message);
    }
    response.map(Either::Right)
}

/// Whether `request` stays on the CONNECT destination, so a client cannot
/// reach another host through a tunnel Airlock decrypts.
fn targets_destination(request: &Request<Incoming>, host: &str, port: u16) -> bool {
    let names_destination =
        |authority: &str| authority::parse(authority, Some(443)) == Some((host.to_owned(), port));
    let uri = request.uri();
    // CONNECT and Upgrade would open another tunnel inside this one.
    let opens_tunnel =
        request.method() == Method::CONNECT || request.headers().contains_key(UPGRADE);
    // Exactly one Host header, naming the destination.
    let mut hosts = request.headers().get_all(HOST).iter();
    let host_matches = hosts
        .next()
        .is_some_and(|value| value.to_str().is_ok_and(names_destination))
        && hosts.next().is_none();
    // An absolute-form target must be `https` on the destination.
    let uri_matches = uri.scheme().is_none_or(|scheme| scheme.as_str() == "https")
        && uri
            .authority()
            .is_none_or(|authority| names_destination(authority.as_str()));
    !opens_tunnel && host_matches && uri_matches && uri.path().starts_with('/')
}

/// Point `request` at the upstream: set Host and use the origin-form target
/// HTTP/1.1 expects. False if either cannot be built from the request.
fn address_upstream(request: &mut Request<Incoming>, host: &str, port: u16) -> bool {
    let Some(target) = request
        .uri()
        .path_and_query()
        .and_then(|path| path.as_str().parse().ok())
    else {
        return false;
    };
    let Ok(host) = HeaderValue::from_str(&format!("{host}:{port}")) else {
        return false;
    };
    *request.uri_mut() = target;
    request.headers_mut().insert(HOST, host);
    true
}

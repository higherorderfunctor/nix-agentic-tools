//! CONNECT tunnel steps both HTTP versions share: `prepare` checks the target
//! and connects upstream before the client gets any reply, and `relay` copies
//! bytes between the client stream and that upstream.
use std::{io, sync::Arc};

use hyper::{StatusCode, Uri, header::HeaderMap};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::TcpStream,
    time::{Instant, timeout_at},
};

use crate::{
    gateway::{Gateway, tls},
    http::authority,
    upstream::connect_upstream,
};

pub(crate) enum Prepared {
    Opaque(TcpStream),
    Intercept {
        gateway: Arc<Gateway>,
        client: String,
    },
}

/// Connect to the CONNECT target, so an unreachable or slow upstream becomes a
/// `502` or `504` rather than a `200` followed by a closed stream.
pub(crate) async fn prepare(
    target: &Uri,
    headers: &HeaderMap,
    gateway: Option<Arc<Gateway>>,
    deadline: Instant,
) -> Result<Prepared, (StatusCode, &'static str)> {
    let (host, port) =
        parse_target(target).ok_or((StatusCode::BAD_REQUEST, "malformed CONNECT target\n"))?;
    if let Some(gateway) = gateway
        && gateway.intercepts(&host, port)
    {
        let Some(client) = gateway.connect_client(headers).map(str::to_owned) else {
            return Err((
                StatusCode::PROXY_AUTHENTICATION_REQUIRED,
                "client token required\n",
            ));
        };
        return Ok(Prepared::Intercept { gateway, client });
    }
    match timeout_at(deadline, connect_upstream(host, port)).await {
        Ok(Ok(upstream)) => Ok(Prepared::Opaque(upstream)),
        Ok(Err(_)) => Err((StatusCode::BAD_GATEWAY, "upstream connection failed\n")),
        Err(_) => Err((
            StatusCode::GATEWAY_TIMEOUT,
            "upstream connection timed out\n",
        )),
    }
}

/// Copy bytes both ways until both sides have closed, so one side's
/// half-close still lets the other finish sending.
pub(crate) async fn relay(
    mut client: impl AsyncRead + AsyncWrite + Unpin + Send + 'static,
    prepared: Prepared,
) -> io::Result<()> {
    match prepared {
        Prepared::Opaque(mut upstream) => {
            tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
            Ok(())
        }
        Prepared::Intercept {
            gateway,
            client: identity,
        } => tls::serve(client, gateway, identity).await,
    }
}

fn parse_target(uri: &Uri) -> Option<(String, u16)> {
    // CONNECT takes a bare authority: refuse `http://host:443` and
    // `host:443/path`.
    if uri.scheme().is_some() || uri.path_and_query().is_some() {
        return None;
    }
    authority::parse(uri.authority()?.as_str())
}

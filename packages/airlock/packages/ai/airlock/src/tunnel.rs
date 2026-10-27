//! CONNECT tunnel steps both HTTP versions share: `prepare` checks the target
//! and connects upstream before the client gets any reply, and `relay` copies
//! bytes between the client stream and that upstream.
use std::io;

use hyper::{StatusCode, Uri};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::TcpStream,
    time::{Instant, timeout_at},
};

use crate::{http::authority, upstream::connect_upstream};

/// Connect to the CONNECT target, so an unreachable or slow upstream becomes a
/// `502` or `504` rather than a `200` followed by a closed stream.
pub(crate) async fn prepare(
    target: &Uri,
    deadline: Instant,
) -> Result<TcpStream, (StatusCode, &'static str)> {
    let (host, port) =
        parse_target(target).ok_or((StatusCode::BAD_REQUEST, "malformed CONNECT target\n"))?;
    match timeout_at(deadline, connect_upstream(host, port)).await {
        Ok(Ok(upstream)) => Ok(upstream),
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
    mut client: impl AsyncRead + AsyncWrite + Unpin,
    mut upstream: TcpStream,
) -> io::Result<()> {
    tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
    Ok(())
}

fn parse_target(uri: &Uri) -> Option<(String, u16)> {
    // CONNECT takes a bare authority: refuse `http://host:443` and
    // `host:443/path`.
    if uri.scheme().is_some() || uri.path_and_query().is_some() {
        return None;
    }
    authority::parse(uri.authority()?.as_str())
}

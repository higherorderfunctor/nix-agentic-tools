//! CONNECT tunnels. A tunnel moves through these steps, in order:
//!
//! 1. `open_tunnel` checks the target and connects upstream before the client
//!    gets any reply, so an unreachable or slow upstream becomes a `502` or
//!    `504` rather than a `200` followed by a closed socket.
//! 2. The server replies `200`, and hyper hands over the raw client socket
//!    through the upgrade future kept in `PendingTunnel`.
//! 3. `PendingTunnel::relay` copies bytes both ways until both sides have
//!    closed, so one side's half-close still lets the other finish sending.
use std::io;

use hyper::{Request, StatusCode, Uri, body::Incoming, upgrade::OnUpgrade};
use hyper_util::rt::TokioIo;
use tokio::{net::TcpStream, time::timeout};

use crate::{
    authority,
    upstream::{CONNECT_TIMEOUT, connect_upstream},
};

pub(crate) struct PendingTunnel {
    upgrade: OnUpgrade,
    upstream: TcpStream,
}

impl PendingTunnel {
    // The server's per-connection task awaits this future instead of spawning
    // it, so a live tunnel still counts against the connection limit and gets
    // the same shutdown grace, then abort, as any other connection.
    pub(crate) async fn relay(self) -> io::Result<()> {
        let upgraded = self.upgrade.await.map_err(io::Error::other)?;
        let mut client = TokioIo::new(upgraded);
        let mut upstream = self.upstream;
        tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
        Ok(())
    }
}

pub(crate) async fn open_tunnel(
    mut request: Request<Incoming>,
) -> Result<PendingTunnel, (StatusCode, &'static str)> {
    let (host, port) = parse_target(request.uri())
        .ok_or((StatusCode::BAD_REQUEST, "malformed CONNECT target\n"))?;
    let upstream = match timeout(CONNECT_TIMEOUT, connect_upstream(host, port)).await {
        Ok(Ok(upstream)) => upstream,
        Ok(Err(_)) => return Err((StatusCode::BAD_GATEWAY, "upstream connection failed\n")),
        Err(_) => {
            return Err((
                StatusCode::GATEWAY_TIMEOUT,
                "upstream connection timed out\n",
            ));
        }
    };
    Ok(PendingTunnel {
        upgrade: hyper::upgrade::on(&mut request),
        upstream,
    })
}

fn parse_target(uri: &Uri) -> Option<(String, u16)> {
    // CONNECT takes a bare authority: refuse `http://host:443` and
    // `host:443/path`.
    if uri.scheme().is_some() || uri.path_and_query().is_some() {
        return None;
    }
    authority::parse(uri.authority()?.as_str())
}

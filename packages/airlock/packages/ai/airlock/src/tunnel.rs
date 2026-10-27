//! CONNECT tunnels. A tunnel moves through these steps, in order:
//!
//! 1. `open_tunnel` checks the target and chooses an `Action` before the client
//!    gets any reply. An opaque tunnel connects upstream here, so an
//!    unreachable or slow upstream becomes a `502` or `504` rather than a
//!    `200` followed by a closed socket. A destination selected for TLS
//!    interception connects later, once the client's TLS hello names it.
//! 2. The server replies `200`, and hyper hands over the raw client socket
//!    through the upgrade future kept in `PendingTunnel`.
//! 3. `PendingTunnel::relay` runs the action. An opaque tunnel copies bytes
//!    both ways until both sides have closed, so one side's half-close still
//!    lets the other finish sending; an intercepted one is handed to `tls.rs`.
//!
//! HTTP/2 CONNECT streams share the first and last steps through `prepare`
//! and `Action::relay`; `http2.rs` carries the bytes in between.
use std::{io, sync::Arc};

use hyper::{Request, StatusCode, Uri, body::Incoming, upgrade::OnUpgrade};
use hyper_util::rt::TokioIo;
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::TcpStream,
    time::{Instant, timeout_at},
};

use crate::{authority, upstream::connect_upstream};

pub(crate) struct PendingTunnel {
    upgrade: OnUpgrade,
    action: Action,
}

impl PendingTunnel {
    // The server's per-connection task awaits this future instead of spawning
    // it, so a live tunnel still counts against the connection limit and gets
    // the same shutdown grace, then abort, as any other connection.
    pub(crate) async fn relay(self) -> io::Result<()> {
        let upgraded = self.upgrade.await.map_err(io::Error::other)?;
        self.action.relay(TokioIo::new(upgraded)).await
    }
}

pub(crate) async fn open_tunnel(
    mut request: Request<Incoming>,
    deadline: Instant,
    interception: Option<Arc<crate::tls::Interception>>,
) -> Result<PendingTunnel, (StatusCode, &'static str)> {
    let action = prepare(request.uri(), deadline, interception).await?;
    Ok(PendingTunnel {
        upgrade: hyper::upgrade::on(&mut request),
        action,
    })
}

pub(crate) enum Action {
    Opaque(TcpStream),
    Intercept(Arc<crate::tls::Interception>, String, u16),
}

impl Action {
    pub(crate) async fn relay(
        self,
        mut client: impl AsyncRead + AsyncWrite + Unpin + Send + 'static,
    ) -> io::Result<()> {
        match self {
            Self::Opaque(mut upstream) => {
                tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
                Ok(())
            }
            Self::Intercept(runtime, host, port) => runtime.relay(client, host, port).await,
        }
    }
}

pub(crate) async fn prepare(
    target: &Uri,
    deadline: Instant,
    interception: Option<Arc<crate::tls::Interception>>,
) -> Result<Action, (StatusCode, &'static str)> {
    let (host, port) =
        parse_target(target).ok_or((StatusCode::BAD_REQUEST, "malformed CONNECT target\n"))?;
    if let Some(runtime) = interception
        && runtime.selected(&host, port)
    {
        return Ok(Action::Intercept(runtime, host, port));
    }
    match timeout_at(deadline, connect_upstream(host, port)).await {
        Ok(Ok(upstream)) => Ok(Action::Opaque(upstream)),
        Ok(Err(_)) => Err((StatusCode::BAD_GATEWAY, "upstream connection failed\n")),
        Err(_) => Err((
            StatusCode::GATEWAY_TIMEOUT,
            "upstream connection timed out\n",
        )),
    }
}

fn parse_target(uri: &Uri) -> Option<(String, u16)> {
    // CONNECT takes a bare authority: refuse `http://host:443` and
    // `host:443/path`.
    if uri.scheme().is_some() || uri.path_and_query().is_some() {
        return None;
    }
    authority::parse(uri.authority()?.as_str(), None)
}

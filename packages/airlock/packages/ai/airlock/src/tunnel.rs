//! CONNECT tunnel steps both HTTP versions share: `prepare` checks the target
//! and chooses an `Action` before the client gets any reply, and
//! `Action::relay` carries the client's bytes after the `200`.
use std::{io, sync::Arc};

use hyper::{StatusCode, Uri};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::TcpStream,
    time::{Instant, timeout_at},
};

use crate::{authority, tls::Interceptor, upstream::connect_upstream};

pub(crate) enum Action {
    /// Copy bytes to an upstream that is already connected.
    Opaque(TcpStream),
    /// Terminate TLS for a selected destination. The upstream connects later,
    /// once the client's TLS hello names it.
    Intercept {
        interceptor: Arc<Interceptor>,
        host: String,
        port: u16,
    },
}

impl Action {
    pub(crate) async fn relay(
        self,
        mut client: impl AsyncRead + AsyncWrite + Unpin + Send + 'static,
    ) -> io::Result<()> {
        match self {
            // Copy until both sides have closed, so one side's half-close
            // still lets the other finish sending.
            Self::Opaque(mut upstream) => {
                tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
                Ok(())
            }
            Self::Intercept {
                interceptor,
                host,
                port,
            } => interceptor.relay(client, host, port).await,
        }
    }
}

/// Choose the tunnel's action. An opaque tunnel connects here, so an
/// unreachable or slow upstream becomes a `502` or `504` rather than a `200`
/// followed by a closed stream.
pub(crate) async fn prepare(
    target: &Uri,
    deadline: Instant,
    interceptor: Option<&Arc<Interceptor>>,
) -> Result<Action, (StatusCode, &'static str)> {
    let (host, port) =
        parse_target(target).ok_or((StatusCode::BAD_REQUEST, "malformed CONNECT target\n"))?;
    if let Some(interceptor) = interceptor
        && let Some(host) = interceptor.selected_name(&host, port)
    {
        return Ok(Action::Intercept {
            interceptor: Arc::clone(interceptor),
            host,
            port,
        });
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

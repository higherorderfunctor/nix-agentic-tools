// cspell:words rsplit
use std::{
    io,
    net::{IpAddr, Ipv6Addr},
    time::Duration,
};

use hyper::{Request, StatusCode, Uri, body::Incoming, upgrade::OnUpgrade};
use hyper_util::rt::TokioIo;
use tokio::{
    net::TcpStream,
    time::{Instant, timeout_at},
};

pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
pub(crate) struct PendingTunnel {
    upgrade: OnUpgrade,
    upstream: TcpStream,
}

impl PendingTunnel {
    // The server's connection task owns this future throughout the relay,
    // so its connection bound and shutdown grace include the whole tunnel.
    pub(crate) async fn relay(self) -> io::Result<()> {
        let upgraded = self.upgrade.await.map_err(io::Error::other)?;
        let mut client = TokioIo::new(upgraded);
        let mut upstream = self.upstream;
        tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
        Ok(())
    }
}

pub(crate) async fn connect(
    mut request: Request<Incoming>,
    deadline: Instant,
) -> Result<PendingTunnel, (StatusCode, &'static str)> {
    let upstream = open(request.uri(), deadline).await?;
    Ok(PendingTunnel {
        upgrade: hyper::upgrade::on(&mut request),
        upstream,
    })
}

pub(crate) async fn open(
    target: &Uri,
    deadline: Instant,
) -> Result<TcpStream, (StatusCode, &'static str)> {
    let (host, port) =
        parse_target(target).ok_or((StatusCode::BAD_REQUEST, "malformed CONNECT target\n"))?;
    match timeout_at(deadline, dial(host, port)).await {
        Ok(Ok(upstream)) => Ok(upstream),
        Ok(Err(_)) => Err((StatusCode::BAD_GATEWAY, "upstream connection failed\n")),
        Err(_) => Err((
            StatusCode::GATEWAY_TIMEOUT,
            "upstream connection timed out\n",
        )),
    }
}

async fn dial(host: String, port: u16) -> io::Result<TcpStream> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return TcpStream::connect((ip, port)).await;
    }
    let addresses = crate::resolver::lookup(host, port).await?;
    TcpStream::connect(addresses.as_slice()).await
}

fn parse_target(uri: &Uri) -> Option<(String, u16)> {
    if uri.scheme().is_some() || uri.path_and_query().is_some() {
        return None;
    }
    parse_authority(uri.authority()?.as_str(), None)
}

pub(crate) fn parse_authority(authority: &str, default_port: Option<u16>) -> Option<(String, u16)> {
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let end = rest.find(']')?;
        let host = &rest[..end];
        host.parse::<Ipv6Addr>().ok()?;
        let suffix = &rest[end + 1..];
        (
            host,
            if suffix.is_empty() {
                None
            } else {
                Some(suffix.strip_prefix(':')?)
            },
        )
    } else {
        let (host, port) = authority
            .rsplit_once(':')
            .map(|(host, port)| (host, Some(port)))
            .unwrap_or((authority, None));
        if host.contains(':') {
            return None;
        }
        (host, port)
    };
    let port = match port {
        Some(port) => {
            if port.is_empty() || !port.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            port.parse::<u16>().ok()?
        }
        None => default_port?,
    };
    if port == 0 || !valid_host(host) {
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
    // Accept absolute DNS names as well as ordinary dotted names.
    host.strip_suffix('.')
        .unwrap_or(host)
        .split('.')
        .all(|label| {
            let length = label.len();
            length > 0
                && length <= 63
                && label
                    .as_bytes()
                    .first()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && label
                    .as_bytes()
                    .last()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
}

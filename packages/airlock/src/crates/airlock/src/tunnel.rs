// cspell:words Addrs rsplit
use std::{
    io,
    net::{IpAddr, Ipv6Addr, ToSocketAddrs},
    sync::{Arc, LazyLock},
    time::Duration,
};

use hyper::{Request, StatusCode, Uri, body::Incoming, upgrade::OnUpgrade};
use hyper_util::rt::TokioIo;
use tokio::{
    net::TcpStream,
    sync::Semaphore,
    time::{Instant, timeout_at},
};

pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_RESOLUTIONS: usize = 16;

static RESOLVER_SLOTS: LazyLock<Arc<Semaphore>> =
    LazyLock::new(|| Arc::new(Semaphore::new(MAX_RESOLUTIONS)));

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
    let addresses = resolve(Arc::clone(&RESOLVER_SLOTS), move || {
        (host.as_str(), port)
            .to_socket_addrs()
            .map(Iterator::collect::<Vec<_>>)
    })
    .await?;
    TcpStream::connect(addresses.as_slice()).await
}

async fn resolve<T: Send + 'static>(
    slots: Arc<Semaphore>,
    lookup: impl FnOnce() -> io::Result<T> + Send + 'static,
) -> io::Result<T> {
    let permit = slots.acquire_owned().await.map_err(io::Error::other)?;
    tokio::task::spawn_blocking(move || {
        // A caller timing out drops its JoinHandle, not the blocking lookup.
        // Keep capacity until the actual job ends, even after cancellation.
        let _permit = permit;
        lookup()
    })
    .await
    .map_err(io::Error::other)?
}

fn parse_target(uri: &Uri) -> Option<(String, u16)> {
    if uri.scheme().is_some() || uri.path_and_query().is_some() {
        return None;
    }
    let authority = uri.authority()?.as_str();
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let end = rest.find(']')?;
        let host = &rest[..end];
        host.parse::<Ipv6Addr>().ok()?;
        (host, rest[end + 1..].strip_prefix(':')?)
    } else {
        let (host, port) = authority.rsplit_once(':')?;
        if host.contains(':') {
            return None;
        }
        (host, port)
    };
    if port.is_empty() || !port.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let port = port.parse::<u16>().ok()?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc,
    };
    use tokio::{sync::oneshot, time::timeout};

    #[tokio::test]
    async fn timed_out_lookups_retain_capacity_until_the_blocking_job_ends() {
        let slots = Arc::new(Semaphore::new(1));
        let (started, running) = oneshot::channel();
        let (release, stalled) = mpsc::channel();
        let first = timeout(
            Duration::from_millis(20),
            resolve(Arc::clone(&slots), move || {
                let _ = started.send(());
                stalled.recv().map_err(io::Error::other)?;
                Ok(())
            }),
        )
        .await;
        assert!(
            first.is_err(),
            "caller must time out while lookup is stalled"
        );
        timeout(Duration::from_secs(2), running)
            .await
            .unwrap()
            .unwrap();

        let executions = Arc::new(AtomicUsize::new(0));
        for _ in 0..3 {
            let executions = Arc::clone(&executions);
            let queued = timeout(
                Duration::from_millis(20),
                resolve(Arc::clone(&slots), move || {
                    executions.fetch_add(1, Ordering::SeqCst);
                    Ok(())
                }),
            )
            .await;
            assert!(
                queued.is_err(),
                "canceled caller must not release its live lookup's capacity"
            );
        }
        assert_eq!(
            executions.load(Ordering::SeqCst),
            0,
            "no additional blocking lookup may start"
        );

        release.send(()).unwrap();
        let next = Arc::clone(&executions);
        let recovered = timeout(
            Duration::from_secs(2),
            resolve(slots, move || {
                next.fetch_add(1, Ordering::SeqCst);
                Ok("resolved")
            }),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(recovered, "resolved");
        assert_eq!(executions.load(Ordering::SeqCst), 1);
    }
}

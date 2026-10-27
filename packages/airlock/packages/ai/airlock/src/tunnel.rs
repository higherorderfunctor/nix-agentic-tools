// cspell:words Addrs
//! CONNECT tunnels. A tunnel moves through these steps, in order:
//!
//! 1. `open_tunnel` checks the target and connects upstream before the client
//!    gets any reply, so an unreachable or slow upstream becomes a `502` or
//!    `504` rather than a `200` followed by a closed socket.
//! 2. The server replies `200`, and hyper hands over the raw client socket
//!    through the upgrade future kept in `PendingTunnel`.
//! 3. `PendingTunnel::relay` copies bytes both ways until both sides have
//!    closed, so one side's half-close still lets the other finish sending.
//!
//! HTTP/2 CONNECT streams share the first step through `open`, then relay in
//! `http2.rs`.
use std::{
    io,
    net::{IpAddr, ToSocketAddrs},
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

use crate::authority;

pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_RESOLUTIONS: usize = 16;

// A DNS lookup blocks a thread and cannot be cancelled. This caps how many
// lookups run or queue on the runtime's shared blocking pool, so a burst of
// CONNECTs to slow names cannot tie that pool up.
static RESOLVER_SLOTS: LazyLock<Arc<Semaphore>> =
    LazyLock::new(|| Arc::new(Semaphore::new(MAX_RESOLUTIONS)));

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
    match timeout_at(deadline, connect_upstream(host, port)).await {
        Ok(Ok(upstream)) => Ok(upstream),
        Ok(Err(_)) => Err((StatusCode::BAD_GATEWAY, "upstream connection failed\n")),
        Err(_) => Err((
            StatusCode::GATEWAY_TIMEOUT,
            "upstream connection timed out\n",
        )),
    }
}

async fn connect_upstream(host: String, port: u16) -> io::Result<TcpStream> {
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
        // Holding the permit inside the job keeps the slot taken until the
        // lookup really ends, so the cap counts running lookups, not callers.
        let _permit = permit;
        lookup()
    })
    .await
    .map_err(io::Error::other)?
}

fn parse_target(uri: &Uri) -> Option<(String, u16)> {
    // CONNECT takes a bare authority: refuse `http://host:443` and
    // `host:443/path`.
    if uri.scheme().is_some() || uri.path_and_query().is_some() {
        return None;
    }
    authority::parse(uri.authority()?.as_str())
}

// `resolve` is private, so the integration tests in tests/ cannot reach it.
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

// cspell:words Addrs
//! DNS lookups for upstream hosts. A lookup blocks a thread, so every lookup
//! runs on the blocking pool and waits for one of a fixed number of slots.
use std::{
    io,
    net::{SocketAddr, ToSocketAddrs},
    sync::{Arc, LazyLock},
};

use tokio::sync::Semaphore;

const MAX_RESOLUTIONS: usize = 16;
// A DNS lookup blocks a thread and cannot be cancelled. This caps how many
// lookups run or queue on the runtime's shared blocking pool, so a burst of
// CONNECTs to slow names cannot tie that pool up.
static RESOLVER_SLOTS: LazyLock<Arc<Semaphore>> =
    LazyLock::new(|| Arc::new(Semaphore::new(MAX_RESOLUTIONS)));

pub(crate) async fn lookup(host: String, port: u16) -> io::Result<Vec<SocketAddr>> {
    resolve(Arc::clone(&RESOLVER_SLOTS), move || {
        (host.as_str(), port)
            .to_socket_addrs()
            .map(Iterator::collect)
    })
    .await
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

// `resolve` is private, so the integration tests in tests/ cannot reach it.
#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::{
            atomic::{AtomicUsize, Ordering},
            mpsc,
        },
        time::Duration,
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

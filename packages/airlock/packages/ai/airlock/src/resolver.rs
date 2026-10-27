// cspell:words Addrs
use std::{
    future::Future,
    io,
    net::{SocketAddr, ToSocketAddrs},
    pin::Pin,
    sync::{Arc, LazyLock},
    task::{Context, Poll},
};

use hyper_util::client::legacy::connect::dns::Name;
use tokio::sync::Semaphore;
use tower_service::Service;

const MAX_RESOLUTIONS: usize = 16;
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

#[derive(Clone)]
pub(crate) struct Resolver;

impl Service<Name> for Resolver {
    type Response = std::vec::IntoIter<SocketAddr>;
    type Error = io::Error;
    type Future = Pin<Box<dyn Future<Output = io::Result<Self::Response>> + Send>>;

    fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, name: Name) -> Self::Future {
        Box::pin(async move {
            lookup(name.as_str().to_owned(), 0)
                .await
                .map(Vec::into_iter)
        })
    }
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

    #[tokio::test]
    async fn tunnel_lookup_and_http_resolver_share_the_same_capacity() {
        let capacity = Arc::clone(&RESOLVER_SLOTS)
            .acquire_many_owned(MAX_RESOLUTIONS as u32)
            .await
            .unwrap();
        assert!(
            timeout(
                std::time::Duration::from_millis(20),
                lookup("localhost".to_owned(), 0)
            )
            .await
            .is_err()
        );
        let mut resolver = Resolver;
        assert!(
            timeout(
                std::time::Duration::from_millis(20),
                resolver.call("localhost".parse().unwrap())
            )
            .await
            .is_err()
        );
        drop(capacity);
        assert!(!lookup("localhost".to_owned(), 0).await.unwrap().is_empty());
        assert!(
            resolver
                .call("localhost".parse().unwrap())
                .await
                .unwrap()
                .next()
                .is_some()
        );
    }
}

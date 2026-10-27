//! A bounded executor for one intercepted TLS session. hyper spawns its inner
//! HTTP/2 connection, stream and body futures here, so ending the session drops
//! them all.
use std::{future::Future, io, pin::Pin, sync::Arc};

use futures_util::{StreamExt, stream::FuturesUnordered};
use hyper::rt::Executor;
use tokio::sync::{Notify, Semaphore, mpsc};

type Task = Pin<Box<dyn Future<Output = ()> + Send>>;
/// Concurrent inner HTTP/2 streams one intercepted session accepts. It lives
/// here because the task bound below is derived from it.
pub(crate) const INNER_MAX_STREAMS: usize = 32;
// One socket driver plus stream, response and upload tasks per stream, rounded
// up for headroom: an early response can leave an upload task alive after its
// stream closes, so SETTINGS alone does not bound the total.
const MAX_TASKS: usize = (1 + 3 * INNER_MAX_STREAMS).next_power_of_two();

#[derive(Clone)]
pub(crate) struct SessionExecutor {
    queue: mpsc::Sender<Task>,
    slots: Arc<Semaphore>,
    overload: Arc<Notify>,
}

pub(crate) struct SessionTasks {
    executor: SessionExecutor,
    queue: mpsc::Receiver<Task>,
}

impl SessionTasks {
    pub(crate) fn new() -> Self {
        let (queue, receiver) = mpsc::channel(MAX_TASKS);
        Self {
            executor: SessionExecutor {
                queue,
                slots: Arc::new(Semaphore::new(MAX_TASKS)),
                overload: Arc::new(Notify::new()),
            },
            queue: receiver,
        }
    }

    pub(crate) fn executor(&self) -> SessionExecutor {
        self.executor.clone()
    }

    pub(crate) async fn run(mut self) -> io::Result<()> {
        let mut active = FuturesUnordered::new();
        loop {
            tokio::select! {
                biased;
                _ = self.executor.overload.notified() => return Err(io::Error::other("inner HTTP/2 task limit exceeded")),
                Some(task) = self.queue.recv() => active.push(task),
                Some(()) = active.next(), if !active.is_empty() => {},
            }
        }
    }
}

impl<F: Future<Output = ()> + Send + 'static> Executor<F> for SessionExecutor {
    fn execute(&self, future: F) {
        let Ok(slot) = Arc::clone(&self.slots).try_acquire_owned() else {
            self.overload.notify_one();
            return;
        };
        let task = Box::pin(async move {
            let _slot = slot;
            future.await;
        });
        if self.queue.try_send(task).is_err() {
            self.overload.notify_one();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::atomic::{AtomicUsize, Ordering},
        task::{Context, Poll},
    };
    struct Probe(Arc<AtomicUsize>);
    impl Drop for Probe {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
    impl Future for Probe {
        type Output = ();
        fn poll(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<()> {
            Poll::Pending
        }
    }
    #[tokio::test]
    async fn dropping_the_session_drops_active_and_queued_tasks() {
        let drops = Arc::new(AtomicUsize::new(0));
        let tasks = SessionTasks::new();
        let executor = tasks.executor();
        executor.execute(Probe(Arc::clone(&drops)));
        let mut run = Box::pin(tasks.run());
        std::future::poll_fn(|cx| {
            assert!(run.as_mut().poll(cx).is_pending());
            Poll::Ready(())
        })
        .await;
        executor.execute(Probe(Arc::clone(&drops)));
        drop(run);
        assert_eq!(drops.load(Ordering::SeqCst), 2);
        assert_eq!(executor.slots.available_permits(), MAX_TASKS);
    }
    #[tokio::test]
    async fn overload_refuses_the_extra_task_and_ends_only_this_session() {
        let drops = Arc::new(AtomicUsize::new(0));
        let tasks = SessionTasks::new();
        let executor = tasks.executor();
        for _ in 0..=MAX_TASKS {
            executor.execute(Probe(Arc::clone(&drops)));
        }
        assert_eq!(drops.load(Ordering::SeqCst), 1);
        assert_eq!(
            tasks.run().await.unwrap_err().to_string(),
            "inner HTTP/2 task limit exceeded"
        );
        assert_eq!(drops.load(Ordering::SeqCst), MAX_TASKS + 1);
        assert_eq!(executor.slots.available_permits(), MAX_TASKS);
    }
}

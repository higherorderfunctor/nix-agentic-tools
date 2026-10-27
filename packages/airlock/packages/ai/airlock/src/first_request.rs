//! The deadline by which a client must send its first request. It closes a
//! connection that opens and then sends nothing a server can act on.
use std::future::Future;

use tokio::{
    sync::Notify,
    time::{Instant, sleep_until},
};

/// Drive `connection` to completion, or give up at `deadline` if the service
/// has not signalled `started` by then. The deadline covers only the wait for
/// the first request; after that the connection runs on its own timeouts.
pub(crate) async fn until_first_request<F: Future>(
    started: &Notify,
    deadline: Instant,
    connection: F,
) -> Option<F::Output> {
    tokio::pin!(connection);
    tokio::select! {
        biased;
        () = started.notified() => Some(connection.await),
        result = &mut connection => Some(result),
        () = sleep_until(deadline) => None,
    }
}

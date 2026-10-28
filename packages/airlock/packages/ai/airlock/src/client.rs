//! The side a client connects to: protocol detection, the HTTP/1 and HTTP/2
//! servers, and the replies Airlock writes itself.
//! Client-facing HTTP servers share the first-request deadline below, which
//! closes a connection that opens and then sends nothing a server can act on.
pub(crate) mod http1;
pub(crate) mod http2;
pub(crate) mod protocol;
pub(crate) mod replies;

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

//! The listener: bind a loopback address, accept connections up to a limit,
//! hand each to the HTTP/1 or HTTP/2 driver its first bytes select, and drain
//! them on shutdown.
use std::{future::Future, io, net::SocketAddr, sync::Arc, time::Duration};

use tokio::{
    net::{TcpListener, TcpStream},
    signal::unix::{SignalKind, signal},
    task::JoinSet,
    time::{Instant, timeout, timeout_at},
};

use crate::{config::Config, startup::State};

const HEADER_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CONNECTIONS: usize = 128;
const PROCESS_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);
const SHUTDOWN_GRACE: Duration = Duration::from_secs(3);

/// Run the listener until SIGINT or SIGTERM, including bounded runtime teardown.
pub fn run(config: Config) -> io::Result<()> {
    let state = State::load(&config)?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let result = runtime.block_on(async {
        // Install handlers before announcing readiness so an immediate signal
        // takes the same draining path as one received later.
        let mut interrupt = signal(SignalKind::interrupt())?;
        let mut terminate = signal(SignalKind::terminate())?;
        let listener = bind(config.listen).await?;
        println!("airlock listening on {}", listener.local_addr()?);

        serve(listener, state, async {
            tokio::select! {
                _ = interrupt.recv() => {}
                _ = terminate.recv() => {}
            }
        })
        .await
    });
    // Blocking runtime work must not hold the process open indefinitely.
    runtime.shutdown_timeout(PROCESS_SHUTDOWN_TIMEOUT);
    result
}

/// Bind an IP loopback address; wildcard and external listeners are rejected.
pub async fn bind(listen: SocketAddr) -> io::Result<TcpListener> {
    if !listen.ip().is_loopback() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "listen address must be loopback",
        ));
    }
    TcpListener::bind(listen).await
}

/// Own all accepted connections and drain them for at most three seconds.
pub async fn serve(
    listener: TcpListener,
    state: State,
    shutdown: impl Future<Output = ()>,
) -> io::Result<()> {
    let state = Arc::new(state);
    let mut connections = JoinSet::new();
    tokio::pin!(shutdown);

    let result = loop {
        tokio::select! {
            biased;

            () = &mut shutdown => break Ok(()),
            completed = connections.join_next(), if !connections.is_empty() => {
                if let Some(Err(error)) = completed {
                    break Err(io::Error::other(error));
                }
            }
            accepted = listener.accept(), if connections.len() < MAX_CONNECTIONS => {
                match accepted {
                    Ok((socket, _)) => { connections.spawn(connection(socket, Arc::clone(&state))); }
                    Err(error) => break Err(error),
                }
            }
        }
    };

    drop(listener);
    if timeout(SHUTDOWN_GRACE, async {
        while connections.join_next().await.is_some() {}
    })
    .await
    .is_err()
    {
        connections.abort_all();
        while connections.join_next().await.is_some() {}
    }
    result
}

// Detection and the first request share one header deadline, so a client
// cannot hold a connection slot by sending its first bytes slowly.
async fn connection(socket: TcpStream, state: Arc<State>) {
    let deadline = Instant::now() + HEADER_TIMEOUT;
    let Ok(Ok((socket, http2))) =
        timeout_at(deadline, crate::client::protocol::detect(socket)).await
    else {
        return;
    };
    if http2 {
        crate::client::http2::serve(socket, deadline, state).await;
    } else {
        crate::client::http1::serve(socket, deadline, HEADER_TIMEOUT, state).await;
    }
}

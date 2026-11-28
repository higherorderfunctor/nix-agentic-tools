//! The listener: bind a loopback address, accept connections up to a limit,
//! hand each to the HTTP/1 or HTTP/2 driver its first bytes select, and drain
//! them on shutdown.
use std::{
    future::{Future, pending},
    io,
    net::SocketAddr,
    path::Path,
    sync::Arc,
    time::Duration,
};

use hyper::{server::conn::http1, service::service_fn};
use hyper_util::rt::{TokioIo, TokioTimer};

use tokio::{
    net::{TcpListener, TcpStream},
    signal::unix::{SignalKind, signal},
    task::JoinSet,
    time::{Instant, timeout, timeout_at},
};

use crate::gateway::Gateway;

const HEADER_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CONNECTIONS: usize = 128;
const PROCESS_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);
const SHUTDOWN_GRACE: Duration = Duration::from_secs(3);

/// Run the listener until SIGINT or SIGTERM, including bounded runtime teardown.
pub fn run(listen: SocketAddr) -> io::Result<()> {
    run_with_gateway(listen, None)
}

/// Start the experimental inference gateway alongside the proxy listener.
pub fn run_with_route_plan(listen: SocketAddr, path: &Path) -> io::Result<()> {
    let gateway = Gateway::load(path).map_err(io::Error::other)?;
    run_with_gateway(listen, Some(Arc::new(gateway)))
}

fn run_with_gateway(listen: SocketAddr, gateway: Option<Arc<Gateway>>) -> io::Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let result = runtime.block_on(async {
        // Install handlers before announcing readiness so an immediate signal
        // takes the same draining path as one received later.
        let mut interrupt = signal(SignalKind::interrupt())?;
        let mut terminate = signal(SignalKind::terminate())?;
        let listener = bind(listen).await?;
        let management = match gateway
            .as_ref()
            .and_then(|gateway| gateway.management_address())
        {
            Some(address) => Some(bind(address).await?),
            None => None,
        };
        if let Some(listener) = &management {
            println!("airlock management listening on {}", listener.local_addr()?);
        }
        println!("airlock listening on {}", listener.local_addr()?);

        serve_listeners(listener, management, gateway, async {
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
pub async fn serve(listener: TcpListener, shutdown: impl Future<Output = ()>) -> io::Result<()> {
    serve_listeners(listener, None, None, shutdown).await
}

async fn serve_listeners(
    listener: TcpListener,
    management: Option<TcpListener>,
    gateway: Option<Arc<Gateway>>,
    shutdown: impl Future<Output = ()>,
) -> io::Result<()> {
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
                    Ok((socket, _)) => { connections.spawn(connection(socket, gateway.clone())); }
                    Err(error) => break Err(error),
                }
            }
            accepted = accept_management(management.as_ref()), if connections.len() < MAX_CONNECTIONS => {
                match accepted {
                    Ok(socket) => {
                        let gateway = Arc::clone(gateway.as_ref().expect("management has a gateway"));
                        connections.spawn(management_connection(socket, gateway));
                    }
                    Err(error) => break Err(error),
                }
            }
        }
    };

    drop(listener);
    drop(management);
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

async fn accept_management(listener: Option<&TcpListener>) -> io::Result<TcpStream> {
    match listener {
        Some(listener) => listener.accept().await.map(|(socket, _)| socket),
        None => pending().await,
    }
}

async fn management_connection(socket: TcpStream, gateway: Arc<Gateway>) {
    let service = service_fn(move |request| std::future::ready(gateway.control(request)));
    let _ = http1::Builder::new()
        .timer(TokioTimer::new())
        .header_read_timeout(HEADER_TIMEOUT)
        .serve_connection(TokioIo::new(socket), service)
        .await;
}

// Detection and the first request share one header deadline, so a client
// cannot hold a connection slot by sending its first bytes slowly.
async fn connection(socket: TcpStream, gateway: Option<Arc<Gateway>>) {
    let deadline = Instant::now() + HEADER_TIMEOUT;
    let Ok(Ok((socket, http2))) =
        timeout_at(deadline, crate::client::protocol::detect(socket)).await
    else {
        return;
    };
    if http2 {
        crate::client::http2::serve(socket, deadline, gateway).await;
    } else {
        crate::client::http1::serve(socket, deadline, HEADER_TIMEOUT, gateway).await;
    }
}

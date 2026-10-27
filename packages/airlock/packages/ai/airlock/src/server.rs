use std::{convert::Infallible, future::Future, io, net::SocketAddr, time::Duration};

use http_body_util::Full;
use hyper::{
    Method, Request, Response, StatusCode,
    body::{Bytes, Incoming},
    server::conn::http1,
    service::service_fn,
};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::{
    net::{TcpListener, TcpStream},
    signal::unix::{SignalKind, signal},
    sync::mpsc,
    task::JoinSet,
    time::timeout,
};

use crate::tunnel::{self, PendingTunnel};

const HEADER_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CONNECTIONS: usize = 128;
const PROCESS_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);
const SHUTDOWN_GRACE: Duration = Duration::from_secs(3);

/// Run the listener until SIGINT or SIGTERM, including bounded runtime teardown.
pub fn run(listen: SocketAddr) -> io::Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let result = runtime.block_on(async {
        // Install handlers before announcing readiness so an immediate signal
        // takes the same draining path as one received later.
        let mut interrupt = signal(SignalKind::interrupt())?;
        let mut terminate = signal(SignalKind::terminate())?;
        let listener = bind(listen).await?;
        println!("airlock listening on {}", listener.local_addr()?);

        serve(listener, async {
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
                    Ok((socket, _)) => { connections.spawn(connection(socket)); }
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

async fn connection(socket: TcpStream) {
    let (sender, mut receiver) = mpsc::channel(1);
    let service = service_fn(move |request| handle(request, sender.clone()));
    // Hyper owns HTTP framing until CONNECT upgrades this socket. The same
    // task then owns the relay; no tunnel escapes the server's JoinSet.
    let result = http1::Builder::new()
        .timer(TokioTimer::new())
        .header_read_timeout(HEADER_TIMEOUT)
        .serve_connection(TokioIo::new(socket), service)
        .with_upgrades()
        .await;
    if result.is_ok()
        && let Some(pending) = receiver.recv().await
    {
        // Protocol and upstream errors affect only this client connection.
        let _ = pending.relay().await;
    }
}

async fn handle(
    request: Request<Incoming>,
    sender: mpsc::Sender<PendingTunnel>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    if request.method() == Method::CONNECT {
        let pending = match tunnel::connect(request).await {
            Ok(pending) => pending,
            Err((status, body)) => return Ok(response(status, body)),
        };
        if sender.send(pending).await.is_err() {
            return Ok(response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "tunnel connection closed\n",
            ));
        }
        return Ok(response(StatusCode::OK, ""));
    }
    let (status, body) = if request.uri().path() != "/health" {
        (StatusCode::NOT_FOUND, "not found\n")
    } else if request.method() != Method::GET {
        (StatusCode::METHOD_NOT_ALLOWED, "GET required\n")
    } else {
        (StatusCode::OK, "ok\n")
    };
    Ok(response(status, body))
}

fn response(status: StatusCode, body: &'static str) -> Response<Full<Bytes>> {
    let mut response = Response::new(Full::new(Bytes::from_static(body.as_bytes())));
    *response.status_mut() = status;
    if !body.is_empty() {
        response.headers_mut().insert(
            hyper::header::CONTENT_TYPE,
            hyper::header::HeaderValue::from_static("text/plain; charset=utf-8"),
        );
    }
    if status == StatusCode::METHOD_NOT_ALLOWED {
        response.headers_mut().insert(
            hyper::header::ALLOW,
            hyper::header::HeaderValue::from_static("GET"),
        );
    }
    response
}

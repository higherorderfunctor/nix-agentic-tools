use std::{
    convert::Infallible,
    future::Future,
    io,
    net::SocketAddr,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
    time::Duration,
};

use http_body_util::Full;
use hyper::{
    Method, Request, Response, StatusCode, Uri,
    body::{Bytes, Incoming},
    server::conn::http1,
    service::service_fn,
};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, ReadBuf},
    net::{TcpListener, TcpStream},
    signal::unix::{SignalKind, signal},
    sync::{Notify, mpsc},
    task::JoinSet,
    time::{Instant, sleep_until, timeout, timeout_at},
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

const H2_PREFACE: &[u8; 24] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

// Protocol detection consumes at most the h2 preface. Replay those bytes to
// the selected driver; neither driver observes a truncated request.
pub(crate) struct Prefixed {
    prefix: Bytes,
    socket: TcpStream,
}

impl Prefixed {
    async fn detect(mut socket: TcpStream) -> io::Result<(Self, bool)> {
        let mut bytes = [0; 24];
        let mut filled = 0;
        while filled < bytes.len() {
            let count = socket.read(&mut bytes[filled..]).await?;
            if count == 0 {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            filled += count;
            if bytes[..filled] != H2_PREFACE[..filled] {
                break;
            }
        }
        let http2 = filled == bytes.len() && bytes == *H2_PREFACE;
        Ok((
            Self {
                prefix: Bytes::copy_from_slice(&bytes[..filled]),
                socket,
            },
            http2,
        ))
    }
}

impl AsyncRead for Prefixed {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if !self.prefix.is_empty() {
            let count = self.prefix.len().min(buffer.remaining());
            buffer.put_slice(&self.prefix.split_to(count));
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut self.socket).poll_read(cx, buffer)
    }
}

impl AsyncWrite for Prefixed {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.socket).poll_write(cx, bytes)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_shutdown(cx)
    }
}

async fn connection(socket: TcpStream) {
    let deadline = Instant::now() + HEADER_TIMEOUT;
    let Ok(Ok((socket, http2))) = timeout_at(deadline, Prefixed::detect(socket)).await else {
        return;
    };
    if http2 {
        crate::http2::serve(socket, deadline).await;
        return;
    }
    let (sender, mut receiver) = mpsc::channel(1);
    let started = Arc::new(Notify::new());
    let observed = Arc::clone(&started);
    let service = service_fn(move |request| {
        observed.notify_one();
        handle(request, sender.clone())
    });
    let result = {
        let driver = http1::Builder::new()
            .timer(TokioTimer::new())
            .header_read_timeout(HEADER_TIMEOUT)
            .serve_connection(TokioIo::new(socket), service)
            .with_upgrades();
        tokio::pin!(driver);
        let result = tokio::select! {
            biased;
            _ = started.notified() => (&mut driver).await,
            result = &mut driver => result,
            _ = sleep_until(deadline) => return,
        };
        result
    };
    if result.is_ok()
        && let Some(pending) = receiver.recv().await
    {
        let _ = pending.relay().await;
    }
}

async fn handle(
    request: Request<Incoming>,
    sender: mpsc::Sender<PendingTunnel>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    if request.method() == Method::CONNECT {
        let deadline = Instant::now() + tunnel::CONNECT_TIMEOUT;
        let pending = match tunnel::connect(request, deadline).await {
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
    let (status, body) = route(request.method(), request.uri());
    Ok(response(status, body))
}

pub(crate) fn route(method: &Method, uri: &Uri) -> (StatusCode, &'static str) {
    if uri.path() != "/health" {
        (StatusCode::NOT_FOUND, "not found\n")
    } else if method != Method::GET {
        (StatusCode::METHOD_NOT_ALLOWED, "GET required\n")
    } else {
        (StatusCode::OK, "ok\n")
    }
}

pub(crate) fn response(status: StatusCode, body: &'static str) -> Response<Full<Bytes>> {
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

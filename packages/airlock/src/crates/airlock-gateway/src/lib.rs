use std::{
    collections::BTreeMap,
    convert::Infallible,
    future::Future,
    io,
    net::SocketAddr,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll},
    time::{Duration, Instant},
};

use airlock_core::{
    config::Config,
    error::SecretError,
    ids::ClientId,
    policy::{Decision, Policy},
    secret::Secret,
    target::ConnectTarget,
};
use base64::{Engine as _, prelude::BASE64_STANDARD};
use http_body_util::Full;
use hyper::{
    Method, Request, Response, StatusCode,
    body::{Bytes, Incoming},
    header::{PROXY_AUTHENTICATE, PROXY_AUTHORIZATION},
    server::conn::http1,
    service::service_fn,
    upgrade::OnUpgrade,
};
use hyper_util::rt::TokioIo;
use tokio::{
    io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf},
    net::{TcpListener, TcpStream},
    sync::{Notify, mpsc},
    task::JoinSet,
    time::timeout,
};
use tracing::instrument::WithSubscriber;
use zeroize::Zeroizing;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);

type Reply = Response<Full<Bytes>>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("gateway socket: {0}")]
    Io(#[from] io::Error),
    #[error(transparent)]
    Secrets(#[from] SecretErrors),
}

#[derive(Debug, thiserror::Error)]
pub struct SecretErrors(pub Vec<SecretError>);

impl std::fmt::Display for SecretErrors {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("could not load client tokens:")?;
        for error in &self.0 {
            write!(formatter, "\n{error}")?;
        }
        Ok(())
    }
}

pub struct Gateway {
    address: SocketAddr,
    listener: TcpListener,
    state: Arc<State>,
}

struct State {
    policy: Policy,
    tokens: BTreeMap<ClientId, Secret>,
}

impl Gateway {
    /// Loads every client token once and binds the configured loopback listener.
    ///
    /// # Errors
    /// Returns every token load error, or a socket bind error.
    pub async fn bind(config: Config) -> Result<Self, Error> {
        let mut errors = Vec::new();
        let mut tokens = BTreeMap::new();
        for (client, file) in config.client_token_files() {
            match file.load() {
                Ok(secret) => {
                    tokens.insert(client.clone(), secret);
                }
                Err(error) => errors.push(error),
            }
        }
        if !errors.is_empty() {
            return Err(SecretErrors(errors).into());
        }
        let listener = TcpListener::bind(config.listen()).await?;
        Ok(Self {
            address: listener.local_addr()?,
            listener,
            state: Arc::new(State {
                policy: Policy::from_config(&config),
                tokens,
            }),
        })
    }

    #[must_use]
    pub fn local_addr(&self) -> SocketAddr {
        self.address
    }

    /// Stops accepting on shutdown, then drains connections for at most five seconds.
    ///
    /// # Errors
    /// Returns a listener accept error after terminating its connections.
    pub async fn serve(self, shutdown: impl Future<Output = ()>) -> Result<(), Error> {
        let mut connections = JoinSet::new();
        tokio::pin!(shutdown);
        let result = loop {
            tokio::select! {
                biased;
                () = &mut shutdown => break Ok(()),
                accepted = self.listener.accept() => match accepted {
                    Ok((socket, _)) => {
                        connections.spawn(connection(socket, self.state.clone()).with_current_subscriber());
                    }
                    Err(error) => break Err(Error::Io(error)),
                },
                _ = connections.join_next(), if !connections.is_empty() => {}
            }
        };
        drop(self.listener);
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
}

struct PendingTunnel {
    audit: Audit,
    upgrade: OnUpgrade,
    upstream: TcpStream,
}

async fn connection(socket: TcpStream, state: Arc<State>) {
    // The HTTP connection owns the upgrade; the tunnel never runs in a detached task.
    let (sender, mut receiver) = mpsc::channel(1);
    let service = service_fn(move |request| handle(request, state.clone(), sender.clone()));
    let result = http1::Builder::new()
        .serve_connection(TokioIo::new(socket), service)
        .with_upgrades()
        .await;
    if let Ok(mut pending) = receiver.try_recv() {
        if result.is_err() {
            pending.audit.outcome = "upgrade_error";
            return;
        }
        match pending.upgrade.await {
            Ok(upgraded) => tunnel(TokioIo::new(upgraded), pending.upstream, pending.audit).await,
            Err(_) => pending.audit.outcome = "upgrade_error",
        }
    }
}

fn response(status: StatusCode, reason: impl Into<Bytes>) -> Reply {
    let mut response = Response::new(Full::new(reason.into()));
    *response.status_mut() = status;
    response
}

fn authenticate(request: &Request<Incoming>, state: &State) -> Option<ClientId> {
    let mut headers = request.headers().get_all(PROXY_AUTHORIZATION).iter();
    let header = headers.next()?.to_str().ok()?;
    if headers.next().is_some() {
        return None;
    }
    let (scheme, encoded) = header.split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("basic") {
        return None;
    }
    let decoded = Zeroizing::new(BASE64_STANDARD.decode(encoded).ok()?);
    let separator = decoded.iter().position(|byte| *byte == b':')?;
    let client = ClientId::try_from(std::str::from_utf8(&decoded[..separator]).ok()?).ok()?;
    state
        .tokens
        .get(&client)?
        .matches(&decoded[separator + 1..])
        .then_some(client)
}

async fn handle(
    mut request: Request<Incoming>,
    state: Arc<State>,
    sender: mpsc::Sender<PendingTunnel>,
) -> Result<Reply, Infallible> {
    if request.method() != Method::CONNECT {
        return Ok(response(StatusCode::METHOD_NOT_ALLOWED, "CONNECT required"));
    }
    let mut audit = Audit::new();
    let Some(client) = authenticate(&request, &state) else {
        audit.outcome = "authentication_required";
        let mut reply = response(
            StatusCode::PROXY_AUTHENTICATION_REQUIRED,
            "authentication required",
        );
        reply.headers_mut().insert(
            PROXY_AUTHENTICATE,
            hyper::header::HeaderValue::from_static("Basic realm=\"airlock\""),
        );
        return Ok(reply);
    };
    audit.client = Some(client.clone());
    let target = match ConnectTarget::try_from(request.uri().to_string().as_str()) {
        Ok(target) => target,
        Err(reason) => {
            audit.outcome = "invalid_target";
            return Ok(response(StatusCode::FORBIDDEN, reason.to_string()));
        }
    };
    audit.host = Some(target.host().clone());
    audit.port = target.port();
    match state.policy.decide(&client, target.host()) {
        Decision::Deny(reason) => {
            audit.outcome = "policy_denied";
            Ok(response(StatusCode::FORBIDDEN, format!("{reason:?}")))
        }
        Decision::Intercept { .. } => {
            // TLS interception belongs to M2.
            audit.decision = "intercept";
            audit.outcome = "not_implemented";
            Ok(response(
                StatusCode::NOT_IMPLEMENTED,
                "TLS interception requires M2",
            ))
        }
        Decision::Tunnel => {
            audit.decision = "tunnel";
            let upstream = match timeout(
                CONNECT_TIMEOUT,
                TcpStream::connect((target.host().as_ref(), target.port())),
            )
            .await
            {
                Ok(Ok(socket)) => socket,
                Ok(Err(_)) => {
                    audit.outcome = "connect_error";
                    return Ok(response(
                        StatusCode::BAD_GATEWAY,
                        "upstream connection failed",
                    ));
                }
                Err(_) => {
                    audit.outcome = "connect_timeout";
                    return Ok(response(
                        StatusCode::GATEWAY_TIMEOUT,
                        "upstream connection timed out",
                    ));
                }
            };
            let pending = PendingTunnel {
                audit,
                upgrade: hyper::upgrade::on(&mut request),
                upstream,
            };
            if sender.send(pending).await.is_err() {
                return Ok(response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "connection closed",
                ));
            }
            let mut reply = response(StatusCode::OK, Bytes::new());
            reply
                .extensions_mut()
                .insert(hyper::ext::ReasonPhrase::from_static(
                    b"Connection Established",
                ));
            Ok(reply)
        }
    }
}

struct Audit {
    client: Option<ClientId>,
    client_to_upstream: Arc<AtomicU64>,
    decision: &'static str,
    dispatch: tracing::Dispatch,
    host: Option<airlock_core::ids::HostName>,
    outcome: &'static str,
    port: u16,
    started: Instant,
    upstream_to_client: Arc<AtomicU64>,
}

impl Audit {
    fn new() -> Self {
        Self {
            client: None,
            client_to_upstream: Arc::default(),
            decision: "deny",
            dispatch: tracing::dispatcher::get_default(Clone::clone),
            host: None,
            outcome: "cancelled",
            port: 0,
            started: Instant::now(),
            upstream_to_client: Arc::default(),
        }
    }
}

impl Drop for Audit {
    fn drop(&mut self) {
        tracing::dispatcher::with_default(&self.dispatch, || {
            tracing::info!(
                client = self.client.as_ref().map_or("", AsRef::as_ref),
                host = self.host.as_ref().map_or("", AsRef::as_ref),
                port = self.port,
                decision = self.decision,
                client_to_upstream = self.client_to_upstream.load(Ordering::Relaxed),
                upstream_to_client = self.upstream_to_client.load(Ordering::Relaxed),
                duration_ms = self.started.elapsed().as_secs_f64() * 1000.0,
                outcome = self.outcome,
                "CONNECT closed"
            );
        });
    }
}

// Counts completed writes even when copy_bidirectional fails or its future is cancelled.
// EOF wakes the owner because copy_bidirectional alone keeps the other half open.
struct TunnelIo<T> {
    closed: Arc<Notify>,
    inner: T,
    written: Arc<AtomicU64>,
}

impl<T: AsyncRead + Unpin> AsyncRead for TunnelIo<T> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let before = buffer.filled().len();
        let has_room = buffer.remaining() > 0;
        let result = Pin::new(&mut self.inner).poll_read(cx, buffer);
        if has_room && matches!(result, Poll::Ready(Ok(()))) && before == buffer.filled().len() {
            self.closed.notify_one();
        }
        result
    }
}

impl<T: AsyncWrite + Unpin> AsyncWrite for TunnelIo<T> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &[u8],
    ) -> Poll<io::Result<usize>> {
        let result = Pin::new(&mut self.inner).poll_write(cx, buffer);
        if let Poll::Ready(Ok(bytes)) = result {
            self.written.fetch_add(bytes as u64, Ordering::Relaxed);
        }
        result
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

async fn tunnel(client: TokioIo<hyper::upgrade::Upgraded>, upstream: TcpStream, mut audit: Audit) {
    let closed = Arc::new(Notify::new());
    let mut client = TunnelIo {
        closed: closed.clone(),
        inner: client,
        written: audit.upstream_to_client.clone(),
    };
    let mut upstream = TunnelIo {
        closed: closed.clone(),
        inner: upstream,
        written: audit.client_to_upstream.clone(),
    };
    audit.outcome = tokio::select! {
        result = tokio::io::copy_bidirectional(&mut client, &mut upstream) => {
            if result.is_ok() { "closed" } else { "io_error" }
        }
        () = closed.notified() => "closed",
    };
    let _ = tokio::join!(client.shutdown(), upstream.shutdown());
}

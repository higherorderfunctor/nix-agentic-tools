mod ca;
mod intercept;
mod toolsearch;
mod usage;

use std::{
    collections::BTreeMap,
    convert::Infallible,
    future::Future,
    io,
    net::SocketAddr,
    path::Path,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll},
    time::{Duration, Instant},
};

use airlock_core::{
    config::{Auth, Config, UnsupportedExecution},
    error::SecretError,
    ids::{ClientId, CredentialId, GroupId},
    policy::{Decision, Policy},
    secret::Secret,
    storage::SqliteStorage,
    target::ConnectTarget,
};
use base64::{Engine as _, prelude::BASE64_STANDARD};
use http_body_util::{BodyExt, Full, combinators::UnsyncBoxBody};
use hyper::{
    Method, Request, Response, StatusCode,
    body::{Bytes, Incoming},
    header::{PROXY_AUTHENTICATE, PROXY_AUTHORIZATION},
    server::conn::http1,
    service::service_fn,
    upgrade::OnUpgrade,
};
use hyper_util::rt::TokioIo;
use rustls::RootCertStore;
use tokio::{
    io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf},
    net::{TcpListener, TcpStream},
    sync::{Notify, mpsc},
    task::JoinSet,
    time::timeout,
};
use tracing::instrument::WithSubscriber;
use zeroize::Zeroizing;

pub use crate::ca::{CaError, create_private_directory, private_directory};
use crate::intercept::Interceptor;
pub use crate::usage::RequestUsageSink;
use crate::usage::UsageTelemetry;

// A peer that stops reading can hold a closed relay open this long while close_notify flushes.
const CLOSE_GRACE: Duration = Duration::from_secs(1);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);

type Reply = Response<UnsyncBoxBody<Bytes, Box<dyn std::error::Error + Send + Sync>>>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Authority(#[from] CaError),
    #[error("gateway socket: {0}")]
    Io(#[from] io::Error),
    #[error("request usage telemetry worker failed during shutdown")]
    UsageTelemetryWorkerJoin,
    #[error("primary header observation worker failed during shutdown")]
    QuotaWorkerJoin,
    #[error("no upstream root certificates could be loaded (check SSL_CERT_FILE)")]
    NoUpstreamRoots,
    #[error("managed OAuth requires initialized storage")]
    ManagedStorageRequired,
    #[error(transparent)]
    Secrets(#[from] SecretErrors),
    #[error("TLS configuration: {0}")]
    Tls(#[from] rustls::Error),
    #[error(transparent)]
    UnsupportedExecution(#[from] UnsupportedExecution),
}

#[derive(Debug, thiserror::Error)]
pub struct SecretErrors(pub Vec<SecretError>);

impl std::fmt::Display for SecretErrors {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("could not load secrets:")?;
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
    usage_worker: Option<tokio::task::JoinHandle<()>>,
    quota_worker: Option<tokio::task::JoinHandle<()>>,
}

struct State {
    config: Arc<Config>,
    credentials: Arc<BTreeMap<CredentialId, Arc<LoadedCredential>>>,
    interceptor: Arc<Interceptor>,
    policy: Policy,
    tokens: BTreeMap<ClientId, Secret>,
    usage: UsageTelemetry,
}

#[derive(Clone, Copy)]
enum AuthKind {
    ApiKey,
    OauthBearer,
}

struct LoadedCredential {
    auth: AuthKind,
    secret: Secret,
}

impl Gateway {
    /// Loads every client token once, opens or creates the CA in `ca_directory`, and binds the
    /// configured loopback listener. Intercepted upstreams are verified against `upstream_roots`.
    ///
    /// # Errors
    /// Returns every token load error, a CA error, an empty root store, or a socket bind error.
    pub async fn bind(
        config: Config,
        ca_directory: &Path,
        upstream_roots: RootCertStore,
    ) -> Result<Self, Error> {
        Self::bind_with_storage(config, ca_directory, upstream_roots, None).await
    }

    /// Binds a gateway with initialized durable storage for managed OAuth.
    ///
    /// # Errors
    /// Returns a storage, configuration, secret, TLS, or socket error.
    pub async fn bind_with_storage(
        config: Config,
        ca_directory: &Path,
        upstream_roots: RootCertStore,
        storage: Option<Arc<SqliteStorage>>,
    ) -> Result<Self, Error> {
        Self::bind_with_storage_and_usage(config, ca_directory, upstream_roots, storage, None).await
    }

    /// Binds with a request-usage sink; telemetry is bounded and never delays response bodies.
    ///
    /// # Errors
    /// Returns the ordinary bind errors; telemetry is fail-visible rather than startup-critical.
    pub async fn bind_with_usage(
        config: Config,
        ca_directory: &Path,
        upstream_roots: RootCertStore,
        usage: Option<Arc<dyn RequestUsageSink>>,
    ) -> Result<Self, Error> {
        Self::bind_with_storage_and_usage(config, ca_directory, upstream_roots, None, usage).await
    }

    /// Binds with managed OAuth storage and a request-usage sink.
    ///
    /// # Errors
    /// Returns configuration, secret, TLS, or socket errors.
    pub async fn bind_with_storage_and_usage(
        config: Config,
        ca_directory: &Path,
        upstream_roots: RootCertStore,
        storage: Option<Arc<SqliteStorage>>,
        usage: Option<Arc<dyn RequestUsageSink>>,
    ) -> Result<Self, Error> {
        config.validate_executable()?;
        if config.has_active_managed_oauth() && storage.is_none() {
            return Err(Error::ManagedStorageRequired);
        }
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
        let mut credentials = BTreeMap::new();
        for (credential, auth) in config.granted_credentials() {
            let file = match auth {
                Auth::ApiKey { file } => (AuthKind::ApiKey, file),
                Auth::OauthBearer { file } => (AuthKind::OauthBearer, file),
                Auth::OauthManaged => continue, // rejected before secret loading
            };
            match file.1.load() {
                Ok(secret) => {
                    credentials.insert(
                        credential.clone(),
                        Arc::new(LoadedCredential {
                            auth: file.0,
                            secret,
                        }),
                    );
                }
                Err(error) => errors.push(error),
            }
        }
        if !errors.is_empty() {
            return Err(SecretErrors(errors).into());
        }
        let mut interceptor = Interceptor::new(ca_directory, upstream_roots, storage)?;
        let quota_worker = interceptor.take_quota_worker();
        let interceptor = Arc::new(interceptor);
        let listener = TcpListener::bind(config.listen()).await?;
        let policy = Policy::from_config(&config);
        let (usage, usage_worker) = usage.map_or_else(
            || (UsageTelemetry::disabled(), None),
            |sink| {
                let (usage, worker) = UsageTelemetry::new(sink);
                (usage, Some(worker))
            },
        );
        Ok(Self {
            address: listener.local_addr()?,
            listener,
            state: Arc::new(State {
                config: Arc::new(config),
                credentials: Arc::new(credentials),
                interceptor,
                policy,
                tokens,
                usage,
            }),
            usage_worker,
            quota_worker,
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
    pub async fn serve(mut self, shutdown: impl Future<Output = ()>) -> Result<(), Error> {
        let mut connections = JoinSet::new();
        tokio::pin!(shutdown);
        let result = loop {
            tokio::select! {
                biased;
                () = &mut shutdown => break Ok(()),
                accepted = self.listener.accept() => match accepted {
                    Ok((socket, _)) => {
                        connections.spawn(
                            connection(socket, Arc::clone(&self.state))
                                .with_current_subscriber(),
                        );
                    }
                    Err(error) => break Err(Error::Io(error)),
                },
                _ = connections.join_next(), if !connections.is_empty() => {}
            }
        };
        drop(self.listener);
        drop(self.state);
        if timeout(SHUTDOWN_GRACE, async {
            while connections.join_next().await.is_some() {}
        })
        .await
        .is_err()
        {
            connections.abort_all();
            while connections.join_next().await.is_some() {}
        }
        if let Some(worker) = self.usage_worker.take() {
            worker.await.map_err(|_| Error::UsageTelemetryWorkerJoin)?;
        }
        if let Some(worker) = self.quota_worker.take() {
            worker.await.map_err(|_| Error::QuotaWorkerJoin)?;
        }
        result
    }
}

struct PendingTunnel {
    audit: Audit,
    route: Route,
    upgrade: OnUpgrade,
}

struct InterceptRoute {
    group: GroupId,
    target: ConnectTarget,
}

enum Route {
    Intercept(InterceptRoute),
    Tunnel(TcpStream),
}

async fn connection(socket: TcpStream, state: Arc<State>) {
    // The HTTP connection owns the upgrade; the tunnel never runs in a detached task.
    let (sender, mut receiver) = mpsc::channel(1);
    let service_state = state.clone();
    let service = service_fn(move |request| handle(request, service_state.clone(), sender.clone()));
    let result = http1::Builder::new()
        .serve_connection(TokioIo::new(socket), service)
        .with_upgrades()
        .await;
    if let Ok(mut pending) = receiver.try_recv() {
        if result.is_err() {
            pending.audit.outcome = "upgrade_error";
            return;
        }
        match (pending.upgrade.await, pending.route) {
            (Ok(upgraded), Route::Intercept(route)) => {
                state
                    .interceptor
                    .run(
                        TokioIo::new(upgraded),
                        route.target,
                        route.group,
                        state.config.clone(),
                        state.credentials.clone(),
                        state.usage.clone(),
                        pending.audit,
                    )
                    .await;
            }
            (Ok(upgraded), Route::Tunnel(upstream)) => {
                relay(TokioIo::new(upgraded), upstream, &mut pending.audit).await;
            }
            (Err(_), _) => pending.audit.outcome = "upgrade_error",
        }
    }
}

fn response(status: StatusCode, reason: impl Into<Bytes>) -> Reply {
    let mut response = Response::new(
        Full::new(reason.into())
            .map_err(|never| match never {})
            .boxed_unsync(),
    );
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
        Decision::Intercept { group, .. } => {
            audit.decision = "intercept";
            let route = InterceptRoute {
                group: group.clone(),
                target,
            };
            Ok(establish(&mut request, &sender, audit, Route::Intercept(route)).await)
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
            Ok(establish(&mut request, &sender, audit, Route::Tunnel(upstream)).await)
        }
    }
}

/// Hands the upgrade to the owning connection and answers `200 Connection Established`.
async fn establish(
    request: &mut Request<Incoming>,
    sender: &mpsc::Sender<PendingTunnel>,
    audit: Audit,
    route: Route,
) -> Reply {
    let pending = PendingTunnel {
        audit,
        route,
        upgrade: hyper::upgrade::on(request),
    };
    if sender.send(pending).await.is_err() {
        return response(StatusCode::INTERNAL_SERVER_ERROR, "connection closed");
    }
    let mut reply = response(StatusCode::OK, Bytes::new());
    reply
        .extensions_mut()
        .insert(hyper::ext::ReasonPhrase::from_static(
            b"Connection Established",
        ));
    reply
}

struct Audit {
    alpn: Option<String>,
    client: Option<ClientId>,
    client_to_upstream: Arc<AtomicU64>,
    decision: &'static str,
    dispatch: tracing::Dispatch,
    host: Option<airlock_core::ids::HostName>,
    outcome: &'static str,
    requests: Arc<AtomicU64>,
    port: u16,
    sni: Option<String>,
    started: Instant,
    upstream_to_client: Arc<AtomicU64>,
}

impl Audit {
    fn new() -> Self {
        Self {
            alpn: None,
            client: None,
            client_to_upstream: Arc::default(),
            decision: "deny",
            dispatch: tracing::dispatcher::get_default(Clone::clone),
            host: None,
            outcome: "cancelled",
            port: 0,
            requests: Arc::default(),
            sni: None,
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
                requests = self.requests.load(Ordering::Relaxed),
                port = self.port,
                sni = self.sni.as_deref().unwrap_or_default(),
                alpn = self.alpn.as_deref().unwrap_or_default(),
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

/// Records bytes accepted by the peer-facing transport, even if the caller is later cancelled.
pub(crate) fn record_completed_write(
    result: Poll<io::Result<usize>>,
    written: &AtomicU64,
) -> Poll<io::Result<usize>> {
    if let Poll::Ready(Ok(bytes)) = result {
        written.fetch_add(bytes as u64, Ordering::Relaxed);
    }
    result
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
        record_completed_write(result, &self.written)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

/// Copies bytes both ways until either side ends, then shuts both down (`close_notify` for TLS).
///
/// Shutdown flushes buffered ciphertext first, so it is bounded; on expiry both streams drop.
async fn relay<C, U>(client: C, upstream: U, audit: &mut Audit)
where
    C: AsyncRead + AsyncWrite + Unpin,
    U: AsyncRead + AsyncWrite + Unpin,
{
    let closed = Arc::new(Notify::new());
    let client = TunnelIo {
        closed: closed.clone(),
        inner: client,
        written: audit.upstream_to_client.clone(),
    };
    let upstream = TunnelIo {
        closed: closed.clone(),
        inner: upstream,
        written: audit.client_to_upstream.clone(),
    };
    relay_streams(client, upstream, closed, audit).await;
}

/// Runs the transport-agnostic relay lifecycle for wrappers that already own accounting and EOF
/// wake-ups. Shutdown flushes buffered ciphertext first, so it is bounded; on expiry both drop.
pub(crate) async fn relay_streams<C, U>(
    mut client: C,
    mut upstream: U,
    closed: Arc<Notify>,
    audit: &mut Audit,
) where
    C: AsyncRead + AsyncWrite + Unpin,
    U: AsyncRead + AsyncWrite + Unpin,
{
    audit.outcome = tokio::select! {
        result = tokio::io::copy_bidirectional(&mut client, &mut upstream) => {
            if result.is_ok() { "closed" } else { "io_error" }
        }
        () = closed.notified() => "closed",
    };
    let _ = timeout(CLOSE_GRACE, async {
        tokio::join!(client.shutdown(), upstream.shutdown())
    })
    .await;
}

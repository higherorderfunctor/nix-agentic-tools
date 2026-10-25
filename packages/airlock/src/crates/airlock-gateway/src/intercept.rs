//! HTTP interception: terminate client TLS, open verified upstream TLS, swap credentials.

use std::{
    collections::BTreeMap,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll},
    time::{Duration, Instant},
};

use airlock_core::{
    config::Config,
    ids::{ClientId, CredentialId, GroupId, HostName},
    target::ConnectTarget,
};
use http_body_util::BodyExt;
use hyper::{
    Method, Request, Response, StatusCode,
    body::{Body, Bytes, Frame, Incoming, SizeHint},
    client::conn as client_conn,
    header::{
        ACCEPT_ENCODING, AUTHORIZATION, CONNECTION, CONTENT_ENCODING, CONTENT_LENGTH, CONTENT_TYPE,
        HeaderName, HeaderValue, InvalidHeaderValue, PROXY_AUTHENTICATE, PROXY_AUTHORIZATION, TE,
        TRAILER, TRANSFER_ENCODING, UPGRADE,
    },
    server::conn as server_conn,
    service::service_fn,
    upgrade::OnUpgrade,
};
use hyper_util::rt::{TokioExecutor, TokioIo};
use rustls::{
    ClientConfig, RootCertStore, ServerConfig, crypto::CryptoProvider, pki_types::ServerName,
    server::Acceptor, sign::SingleCertAndKey,
};
use serde::Deserialize;
use tokio::{
    io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf},
    net::TcpStream,
    sync::{Mutex as AsyncHttp1SenderMutex, Notify, mpsc},
    task::JoinHandle,
    time::timeout,
};
use tokio_rustls::{LazyConfigAcceptor, StartHandshake, TlsConnector, client, server};
use zeroize::Zeroizing;

use crate::{
    Audit, AuthKind, CONNECT_TIMEOUT, Error, LoadedCredential, Reply, ca::Authority,
    record_completed_write, relay_streams, toolsearch,
};

// A client gets this long to send its ClientHello, and later to finish its handshake.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const X_API_KEY: HeaderName = HeaderName::from_static("x-api-key");
// Anthropic's Messages API limits request bodies to 32 MiB.
const MODEL_BODY_LIMIT: usize = 32 << 20;
// Only Anthropic rate-limit fields identify the primary account; retry-after belongs to the
// selected provider's response and is never part of the cached snapshot.
const QUOTA_HEADER_PREFIX: &str = "anthropic-ratelimit-";
const QUOTA_HEADER_LIMIT: usize = 64;
const QUOTA_SNAPSHOT_LIMIT: usize = 16 << 10;

type QuotaCache = Arc<Mutex<BTreeMap<QuotaCacheKey, QuotaSnapshot>>>;

#[derive(Clone, Eq, Ord, PartialEq, PartialOrd)]
struct QuotaCacheKey {
    client: ClientId,
    credential: CredentialId,
    group: GroupId,
}

#[derive(Clone)]
struct QuotaSnapshot {
    headers: hyper::HeaderMap<HeaderValue>,
    observed: Instant,
}

impl QuotaSnapshot {
    fn replaces(&self, existing: &Self) -> bool {
        self.observed >= existing.observed
    }
}

#[derive(Clone)]
struct QuotaContext {
    cache: QuotaCache,
    client: ClientId,
    credential: CredentialId,
    group: GroupId,
    primary_credential: CredentialId,
    primary: bool,
}

type BodyError = Box<dyn std::error::Error + Send + Sync>;

enum RequestBody {
    Incoming(Incoming),
    Buffered {
        bytes: Zeroizing<Vec<u8>>,
        offset: usize,
    },
}

impl Body for RequestBody {
    type Data = Bytes;
    type Error = BodyError;

    fn poll_frame(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Self::Error>>> {
        match &mut *self {
            Self::Incoming(body) => std::pin::Pin::new(body)
                .poll_frame(cx)
                .map(|item| item.map(|result| result.map_err(Into::into))),
            Self::Buffered { bytes, offset } => {
                if *offset < bytes.len() {
                    let end = (*offset + (16 << 10)).min(bytes.len());
                    let frame = Frame::data(Bytes::copy_from_slice(&bytes[*offset..end]));
                    *offset = end;
                    Poll::Ready(Some(Ok(frame)))
                } else {
                    Poll::Ready(None)
                }
            }
        }
    }

    fn size_hint(&self) -> SizeHint {
        match self {
            Self::Incoming(body) => body.size_hint(),
            Self::Buffered { bytes, offset, .. } => {
                SizeHint::with_exact((bytes.len() - offset) as u64)
            }
        }
    }
}

#[derive(Deserialize)]
struct ModelSelector {
    model: Option<String>,
}

fn parse_model(bytes: &[u8]) -> Result<Option<String>, &'static str> {
    if bytes.iter().find(|byte| !byte.is_ascii_whitespace()) != Some(&b'{') {
        return Err("invalid_model_selector");
    }
    let selector: ModelSelector =
        serde_json::from_slice(bytes).map_err(|_| "invalid_model_selector")?;
    if selector.model.as_deref().is_some_and(invalid_model_id) {
        return Err("invalid_model_selector");
    }
    Ok(selector.model)
}

fn inspection_error_status(reason: &str) -> StatusCode {
    if reason == "request_too_large" {
        StatusCode::PAYLOAD_TOO_LARGE
    } else {
        StatusCode::BAD_REQUEST
    }
}

fn invalid_model_id(model: &str) -> bool {
    model.is_empty()
        || model.len() > 128
        || !model
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._:/".contains(&byte))
}

fn append_inference_chunk(
    bytes: &mut Zeroizing<Vec<u8>>,
    chunk: &[u8],
    fixed_capacity: bool,
) -> Result<(), &'static str> {
    if chunk.len() > MODEL_BODY_LIMIT - bytes.len() {
        return Err("request_too_large");
    }
    let needed = bytes.len() + chunk.len();
    if needed > bytes.capacity() {
        if fixed_capacity {
            return Err("request_body_error");
        }
        let capacity = MODEL_BODY_LIMIT.min((2 * bytes.len()).max(needed));
        let mut replacement = Zeroizing::new(Vec::with_capacity(capacity));
        replacement.extend_from_slice(bytes);
        *bytes = replacement;
    }
    bytes.extend_from_slice(chunk);
    Ok(())
}

async fn inference_body(
    mut body: Incoming,
    content_length: Option<u64>,
) -> Result<(RequestBody, Option<String>), &'static str> {
    let capacity = match content_length {
        Some(length) if length > MODEL_BODY_LIMIT as u64 => return Err("request_too_large"),
        Some(length) => usize::try_from(length).map_err(|_| "request_too_large")?,
        None => 0,
    };
    let mut bytes = Zeroizing::new(Vec::with_capacity(capacity));
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(|_| "request_body_error")?;
        match frame.into_data() {
            Ok(chunk) => {
                append_inference_chunk(&mut bytes, &chunk, content_length.is_some())?;
            }
            Err(frame) => {
                // Claude's Messages requests never carry trailers; reject rather than replay them.
                return Err(if frame.into_trailers().is_ok() {
                    "request_trailers_unsupported"
                } else {
                    "request_body_error"
                });
            }
        }
    }
    let model = parse_model(&bytes)?;
    Ok((RequestBody::Buffered { bytes, offset: 0 }, model))
}

async fn inspect_request(
    request: Request<Incoming>,
    inference: bool,
) -> Result<(Request<RequestBody>, Option<String>), &'static str> {
    let (parts, incoming) = request.into_parts();
    let (body, model) = if inference {
        let content_length = parts
            .headers
            .get(CONTENT_LENGTH)
            .map(|value| {
                value
                    .to_str()
                    .ok()
                    .and_then(|value| value.parse::<u64>().ok())
                    .ok_or("request_body_error")
            })
            .transpose()?;
        inference_body(incoming, content_length).await?
    } else {
        (RequestBody::Incoming(incoming), None)
    };
    Ok((Request::from_parts(parts, body), model))
}

pub(crate) struct Interceptor {
    authority: Authority,
    provider: Arc<CryptoProvider>,
    quota_cache: QuotaCache,
    upstream: Arc<ClientConfig>,
}

#[derive(Clone, Copy)]
enum HttpProtocol {
    Http1,
    Http2,
}

impl HttpProtocol {
    fn from_alpn(alpn: Option<&[u8]>) -> Self {
        if alpn == Some(b"h2") {
            Self::Http2
        } else {
            Self::Http1
        }
    }
}

#[derive(Clone)]
struct RequestAudit {
    client_to_upstream: Arc<AtomicU64>,
    dispatch: tracing::Dispatch,
    requests: Arc<std::sync::atomic::AtomicU64>,
}

impl RequestAudit {
    fn received(&self) {
        self.requests.fetch_add(1, Ordering::Relaxed);
    }
}

struct RequestCompletion {
    audit: RequestAudit,
    completed: bool,
    duration_started: std::time::Instant,
    method: Method,
    credential: Option<CredentialId>,
    model: Option<String>,
    outcome: Option<&'static str>,
    path: String,
}

impl RequestCompletion {
    fn new(audit: RequestAudit, method: Method, path: String) -> Self {
        audit.received();
        Self {
            audit,
            completed: false,
            duration_started: std::time::Instant::now(),
            method,
            credential: None,
            model: None,
            outcome: None,
            path,
        }
    }

    fn selected(&mut self, credential: CredentialId, model: Option<String>) {
        self.credential = Some(credential);
        self.model = model;
    }

    fn finish(mut self, status: StatusCode) {
        self.completed = true;
        tracing::dispatcher::with_default(&self.audit.dispatch, || {
            tracing::debug!(
                method = self.method.as_str(),
                credential = self.credential.as_ref().map_or("", AsRef::as_ref),
                model = self.model.as_deref().unwrap_or_default(),
                outcome = self.outcome.unwrap_or_default(),
                path = self.path.as_str(),
                status = status.as_u16(),
                duration_ms = self.duration_started.elapsed().as_secs_f64() * 1000.0,
                "request"
            );
        });
    }
}

impl Drop for RequestCompletion {
    fn drop(&mut self) {
        if self.completed {
            return;
        }
        tracing::dispatcher::with_default(&self.audit.dispatch, || {
            tracing::debug!(
                method = self.method.as_str(),
                credential = self.credential.as_ref().map_or("", AsRef::as_ref),
                model = self.model.as_deref().unwrap_or_default(),
                path = self.path.as_str(),
                cancelled = true,
                duration_ms = self.duration_started.elapsed().as_secs_f64() * 1000.0,
                "request"
            );
        });
    }
}

struct AbortOnDrop(JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

impl std::future::Future for AbortOnDrop {
    type Output = Result<(), tokio::task::JoinError>;

    fn poll(mut self: std::pin::Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        std::pin::Pin::new(&mut self.0).poll(cx)
    }
}

#[derive(Clone)]
struct SharedIo<T> {
    closed: Arc<Notify>,
    inner: Arc<Mutex<T>>,
    written: Arc<AtomicU64>,
}

struct IoShutdown<T> {
    inner: Arc<Mutex<T>>,
}

fn shared_io<T>(
    inner: T,
    written: Arc<AtomicU64>,
    closed: Arc<Notify>,
) -> (SharedIo<T>, IoShutdown<T>) {
    let inner = Arc::new(Mutex::new(inner));
    (
        SharedIo {
            closed,
            inner: inner.clone(),
            written,
        },
        IoShutdown { inner },
    )
}

fn lock_poisoned() -> std::io::Error {
    std::io::Error::other("connection I/O lock poisoned")
}

impl<T: AsyncRead + Unpin> AsyncRead for SharedIo<T> {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let Ok(mut inner) = self.inner.lock() else {
            return Poll::Ready(Err(lock_poisoned()));
        };
        let before = buffer.filled().len();
        let has_room = buffer.remaining() > 0;
        let result = std::pin::Pin::new(&mut *inner).poll_read(cx, buffer);
        if has_room && matches!(result, Poll::Ready(Ok(()))) && before == buffer.filled().len() {
            self.closed.notify_one();
        }
        result
    }
}

impl<T: AsyncWrite + Unpin> AsyncWrite for SharedIo<T> {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let Ok(mut inner) = self.inner.lock() else {
            return Poll::Ready(Err(lock_poisoned()));
        };
        let result = std::pin::Pin::new(&mut *inner).poll_write(cx, buffer);
        record_completed_write(result, &self.written)
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<std::io::Result<()>> {
        let Ok(mut inner) = self.inner.lock() else {
            return Poll::Ready(Err(lock_poisoned()));
        };
        std::pin::Pin::new(&mut *inner).poll_flush(cx)
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<std::io::Result<()>> {
        let Ok(mut inner) = self.inner.lock() else {
            return Poll::Ready(Err(lock_poisoned()));
        };
        std::pin::Pin::new(&mut *inner).poll_shutdown(cx)
    }
}

impl<T: AsyncWrite + Unpin> IoShutdown<T> {
    async fn close(self) {
        let Ok(inner) = Arc::try_unwrap(self.inner) else {
            return;
        };
        let mut inner = inner
            .into_inner()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _ = timeout(crate::CLOSE_GRACE, inner.shutdown()).await;
    }
}

#[derive(Clone)]
enum UpstreamSender {
    Http1(Arc<AsyncHttp1SenderMutex<client_conn::http1::SendRequest<RequestBody>>>),
    Http2(client_conn::http2::SendRequest<RequestBody>),
}

impl UpstreamSender {
    fn requires_absolute_uri(&self) -> bool {
        matches!(self, Self::Http2(_))
    }

    async fn send_request(
        self,
        request: Request<RequestBody>,
    ) -> Result<Response<Incoming>, hyper::Error> {
        match self {
            Self::Http1(sender) => {
                let mut sender = sender.lock().await;
                sender.ready().await?;
                sender.send_request(request).await
            }
            Self::Http2(mut sender) => {
                sender.ready().await?;
                sender.send_request(request).await
            }
        }
    }
}

async fn start_upstream(
    protocol: HttpProtocol,
    upstream_io: SharedIo<client::TlsStream<TcpStream>>,
) -> Option<(UpstreamSender, AbortOnDrop)> {
    match protocol {
        HttpProtocol::Http1 => {
            let (sender, connection) = client_conn::http1::handshake(TokioIo::new(upstream_io))
                .await
                .ok()?;
            Some((
                UpstreamSender::Http1(Arc::new(AsyncHttp1SenderMutex::new(sender))),
                AbortOnDrop(tokio::spawn(async move {
                    let _ = connection.with_upgrades().await;
                })),
            ))
        }
        HttpProtocol::Http2 => {
            let (sender, connection) =
                client_conn::http2::handshake(TokioExecutor::new(), TokioIo::new(upstream_io))
                    .await
                    .ok()?;
            Some((
                UpstreamSender::Http2(sender),
                AbortOnDrop(tokio::spawn(async move {
                    let _ = connection.await;
                })),
            ))
        }
    }
}

#[derive(Clone)]
struct ForwardRoute {
    config: Arc<Config>,
    credentials: Arc<BTreeMap<CredentialId, Arc<LoadedCredential>>>,
    group: GroupId,
    target: ConnectTarget,
}

#[derive(Clone)]
struct ForwardState {
    audit: RequestAudit,
    client: ClientId,
    interceptor: Arc<Interceptor>,
    quota_cache: QuotaCache,
    route: ForwardRoute,
    sender: UpstreamSender,
}

struct PendingUpgrade {
    client: OnUpgrade,
    upstream: OnUpgrade,
    task: Option<AbortOnDrop>,
    _sender: Option<UpstreamSender>,
}

struct LeasedBody {
    inner: ResponsePayload,
    _task: Option<AbortOnDrop>,
    _sender: Option<UpstreamSender>,
}

enum ResponsePayload {
    Passthrough(Incoming),
    Json {
        inner: Incoming,
        bytes: Zeroizing<Vec<u8>>,
        done: bool,
        trailers: Option<hyper::HeaderMap>,
    },
    Sse {
        inner: Incoming,
        bytes: Zeroizing<Vec<u8>>,
        done: bool,
        pending: Option<Bytes>,
        skip_lf: bool,
        trailers: Option<hyper::HeaderMap>,
    },
}

fn sse_event_end(bytes: &[u8]) -> Option<usize> {
    let mut line_start = 0;
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\r' || bytes[index] == b'\n' {
            let blank = index == line_start;
            let cr = bytes[index] == b'\r';
            index += 1;
            if cr && bytes.get(index) == Some(&b'\n') {
                index += 1;
            }
            if blank {
                return Some(index);
            }
            line_start = index;
        } else {
            index += 1;
        }
    }
    None
}

fn skip_optional_lf(chunk: Bytes, skip_lf: &mut bool) -> Bytes {
    if !std::mem::take(skip_lf) || chunk.first() != Some(&b'\n') {
        return chunk;
    }
    chunk.slice(1..)
}

fn take_sse_chunk(pending: &mut Option<Bytes>, skip_lf: &mut bool) -> Option<Bytes> {
    pending
        .take()
        .map(|chunk| skip_optional_lf(chunk, skip_lf))
        .filter(|chunk| !chunk.is_empty())
}

fn body_error(reason: &'static str) -> BodyError {
    std::io::Error::new(std::io::ErrorKind::InvalidData, reason).into()
}

fn transformed_event(event: &mut Zeroizing<Vec<u8>>) -> Result<Frame<Bytes>, BodyError> {
    toolsearch::event(event).map_err(body_error)?;
    Ok(Frame::data(Bytes::copy_from_slice(event)))
}

impl Body for LeasedBody {
    type Data = Bytes;
    type Error = BodyError;

    fn poll_frame(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Self::Error>>> {
        loop {
            match &mut self.inner {
                ResponsePayload::Passthrough(inner) => {
                    return std::pin::Pin::new(inner)
                        .poll_frame(cx)
                        .map(|item| item.map(|result| result.map_err(Into::into)));
                }
                ResponsePayload::Json {
                    inner,
                    bytes,
                    done,
                    trailers,
                } => {
                    if *done {
                        return Poll::Ready(
                            trailers.take().map(|value| Ok(Frame::trailers(value))),
                        );
                    }
                    match std::pin::Pin::new(inner).poll_frame(cx) {
                        Poll::Pending => return Poll::Pending,
                        Poll::Ready(Some(Ok(frame))) => match frame.into_data() {
                            Ok(chunk) => {
                                if append_inference_chunk(bytes, &chunk, false).is_err() {
                                    *done = true;
                                    return Poll::Ready(Some(Err(body_error(
                                        "toolsearch_response_too_large",
                                    ))));
                                }
                            }
                            Err(frame) => *trailers = frame.into_trailers().ok(),
                        },
                        Poll::Ready(Some(Err(error))) => {
                            return Poll::Ready(Some(Err(error.into())));
                        }
                        Poll::Ready(None) => {
                            *done = true;
                            if let Err(reason) = toolsearch::response(bytes) {
                                return Poll::Ready(Some(Err(body_error(reason))));
                            }
                            return Poll::Ready(Some(Ok(Frame::data(Bytes::copy_from_slice(
                                bytes,
                            )))));
                        }
                    }
                }
                ResponsePayload::Sse {
                    inner,
                    bytes,
                    done,
                    pending,
                    skip_lf,
                    trailers,
                } => {
                    if let Some(end) = sse_event_end(bytes) {
                        let mut event = Zeroizing::new(bytes[..end].to_vec());
                        *skip_lf = event.ends_with(b"\r") && end == bytes.len();
                        *bytes = Zeroizing::new(bytes[end..].to_vec());
                        return Poll::Ready(Some(transformed_event(&mut event)));
                    }
                    if *done {
                        if bytes.is_empty() {
                            return Poll::Ready(
                                trailers.take().map(|value| Ok(Frame::trailers(value))),
                            );
                        }
                        let mut event = Zeroizing::new(std::mem::take(&mut **bytes));
                        return Poll::Ready(Some(transformed_event(&mut event)));
                    }
                    if let Some(chunk) = take_sse_chunk(pending, skip_lf) {
                        let room = toolsearch::EVENT_LIMIT.saturating_sub(bytes.len());
                        if room == 0 {
                            *done = true;
                            return Poll::Ready(Some(Err(body_error(
                                "toolsearch_event_too_large",
                            ))));
                        }
                        let taken = room.min(chunk.len());
                        bytes.extend_from_slice(&chunk[..taken]);
                        if taken < chunk.len() {
                            *pending = Some(chunk.slice(taken..));
                        }
                        continue;
                    }
                    match std::pin::Pin::new(inner).poll_frame(cx) {
                        Poll::Pending => return Poll::Pending,
                        Poll::Ready(Some(Ok(frame))) => match frame.into_data() {
                            Ok(chunk) => *pending = Some(chunk),
                            Err(frame) => *trailers = frame.into_trailers().ok(),
                        },
                        Poll::Ready(Some(Err(error))) => {
                            return Poll::Ready(Some(Err(error.into())));
                        }
                        Poll::Ready(None) => *done = true,
                    }
                }
            }
        }
    }

    fn size_hint(&self) -> SizeHint {
        match &self.inner {
            ResponsePayload::Passthrough(inner) => inner.size_hint(),
            ResponsePayload::Json { .. } | ResponsePayload::Sse { .. } => SizeHint::default(),
        }
    }
}

impl Interceptor {
    pub(crate) fn new(ca_directory: &Path, upstream_roots: RootCertStore) -> Result<Self, Error> {
        if upstream_roots.is_empty() {
            return Err(Error::NoUpstreamRoots);
        }
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let upstream = ClientConfig::builder_with_provider(provider.clone())
            .with_safe_default_protocol_versions()?
            .with_root_certificates(upstream_roots)
            .with_no_client_auth();
        Ok(Self {
            authority: Authority::open(ca_directory, provider.clone())?,
            provider,
            quota_cache: Arc::new(Mutex::new(BTreeMap::new())),
            upstream: Arc::new(upstream),
        })
    }

    pub(crate) async fn run(
        self: &Arc<Self>,
        client: TokioIo<hyper::upgrade::Upgraded>,
        target: ConnectTarget,
        group: GroupId,
        config: Arc<Config>,
        credentials: Arc<BTreeMap<CredentialId, Arc<LoadedCredential>>>,
        mut audit: Audit,
    ) {
        // A timeout, a non-handshake first record and an unparseable hello all mean "not TLS".
        let Ok(Ok(start)) = timeout(
            HANDSHAKE_TIMEOUT,
            LazyConfigAcceptor::new(Acceptor::default(), client),
        )
        .await
        else {
            audit.outcome = "not_tls";
            return;
        };
        let hello = start.client_hello();
        let Some(sni) = hello.server_name().map(str::to_owned) else {
            audit.outcome = "sni_missing";
            return;
        };
        let offered: Vec<Vec<u8>> = hello
            .alpn()
            .into_iter()
            .flatten()
            .map(<[u8]>::to_vec)
            .collect();
        // Without this a client could CONNECT to one host and speak TLS to another under its leaf.
        let matches = HostName::try_from(sni.as_str()).is_ok_and(|host| host == *target.host());
        audit.sni = Some(sni);
        if !matches {
            audit.outcome = "sni_mismatch";
            return;
        }
        // Dropping `start` on any failure below closes the client before its handshake completes.
        let upstream = match self.connect(&target, offered).await {
            Ok(upstream) => upstream,
            Err(outcome) => {
                audit.outcome = outcome;
                return;
            }
        };
        let negotiated = upstream.get_ref().1.alpn_protocol().map(<[u8]>::to_vec);
        audit.alpn = negotiated
            .as_deref()
            .map(|protocol| String::from_utf8_lossy(protocol).into_owned());
        let Some(client_id) = audit.client.clone() else {
            audit.outcome = "authentication_required";
            return;
        };
        let route = ForwardRoute {
            config,
            credentials,
            group,
            target,
        };
        self.forward_connection(start, upstream, negotiated, route, audit, client_id)
            .await;
    }

    async fn forward_connection(
        self: &Arc<Self>,
        start: StartHandshake<TokioIo<hyper::upgrade::Upgraded>>,
        mut upstream: client::TlsStream<TcpStream>,
        negotiated: Option<Vec<u8>>,
        route: ForwardRoute,
        mut audit: Audit,
        client_id: ClientId,
    ) {
        let protocol = HttpProtocol::from_alpn(negotiated.as_deref());
        let Ok(tls_config) = self.server_config(route.target.host(), negotiated) else {
            audit.outcome = "leaf_error";
            let _ = timeout(crate::CLOSE_GRACE, upstream.shutdown()).await;
            return;
        };
        let Ok(Ok(client)) = timeout(HANDSHAKE_TIMEOUT, start.into_stream(tls_config)).await else {
            audit.outcome = "client_tls_error";
            let _ = timeout(crate::CLOSE_GRACE, upstream.shutdown()).await;
            return;
        };
        self.serve_forwarding(client, upstream, protocol, route, audit, client_id)
            .await;
    }

    async fn serve_forwarding(
        self: &Arc<Self>,
        client: server::TlsStream<TokioIo<hyper::upgrade::Upgraded>>,
        upstream: client::TlsStream<TcpStream>,
        protocol: HttpProtocol,
        route: ForwardRoute,
        mut audit: Audit,
        client_identity: ClientId,
    ) {
        let relay_closed = Arc::new(Notify::new());
        let (upstream_io, upstream_shutdown) = shared_io(
            upstream,
            audit.client_to_upstream.clone(),
            relay_closed.clone(),
        );
        let Some((sender, upstream_task)) = start_upstream(protocol, upstream_io).await else {
            audit.outcome = "upstream_error";
            return;
        };
        let (client_io, client_shutdown) = shared_io(
            client,
            audit.upstream_to_client.clone(),
            relay_closed.clone(),
        );

        let request_audit = RequestAudit {
            client_to_upstream: audit.client_to_upstream.clone(),
            dispatch: audit.dispatch.clone(),
            requests: audit.requests.clone(),
        };
        let (upgrade_sender, mut upgrade_receiver) = mpsc::channel(1);
        let forwarding = ForwardState {
            audit: request_audit,
            client: client_identity,
            interceptor: self.clone(),
            quota_cache: self.quota_cache.clone(),
            route,
            sender,
        };
        let service =
            service_fn(move |request| forward(request, forwarding.clone(), upgrade_sender.clone()));
        let server = async {
            match protocol {
                HttpProtocol::Http1 => {
                    server_conn::http1::Builder::new()
                        .serve_connection(TokioIo::new(client_io), service)
                        .with_upgrades()
                        .await
                }
                HttpProtocol::Http2 => {
                    server_conn::http2::Builder::new(TokioExecutor::new())
                        .serve_connection(TokioIo::new(client_io), service)
                        .await
                }
            }
        };
        let result = server.await;

        let mut normal_shutdown = Some((client_shutdown, upstream_shutdown));
        let mut relay_audited = false;
        let mut upgrade_failed = false;
        if let Ok(pending) = upgrade_receiver.try_recv() {
            let _selected_task = pending.task;
            match tokio::join!(pending.client, pending.upstream) {
                (Ok(client), Ok(upstream)) => {
                    drop(normal_shutdown.take());
                    relay_streams(
                        TokioIo::new(client),
                        TokioIo::new(upstream),
                        relay_closed,
                        &mut audit,
                    )
                    .await;
                    relay_audited = true;
                }
                (Err(_), _) | (_, Err(_)) => upgrade_failed = true,
            }
        }
        if upgrade_failed {
            audit.outcome = "upgrade_error";
        } else if !relay_audited {
            audit.outcome = if result.is_ok() { "closed" } else { "io_error" };
        }
        upstream_task.0.abort();
        let _ = upstream_task.await;
        if let Some((client_shutdown, upstream_shutdown)) = normal_shutdown {
            let _ = timeout(crate::CLOSE_GRACE, async {
                tokio::join!(client_shutdown.close(), upstream_shutdown.close())
            })
            .await;
        }
    }

    /// Opens verified TLS to the real host, offering exactly the client's ALPN list.
    async fn connect(
        &self,
        target: &ConnectTarget,
        alpn: Vec<Vec<u8>>,
    ) -> Result<client::TlsStream<TcpStream>, &'static str> {
        let name = ServerName::try_from(target.host().as_ref().to_owned())
            .map_err(|_| "upstream_tls_error")?;
        let mut config = (*self.upstream).clone();
        config.alpn_protocols = alpn;
        let connector = TlsConnector::from(Arc::new(config));
        timeout(CONNECT_TIMEOUT, async {
            let socket = TcpStream::connect((target.host().as_ref(), target.port()))
                .await
                .map_err(|_| "connect_error")?;
            connector
                .connect(name, socket)
                .await
                .map_err(|_| "upstream_tls_error")
        })
        .await
        .map_err(|_| "connect_timeout")?
    }

    /// Presents the host's leaf and offers only the protocol the upstream chose.
    fn server_config(
        &self,
        host: &HostName,
        alpn: Option<Vec<u8>>,
    ) -> Result<Arc<ServerConfig>, Error> {
        let mut config = ServerConfig::builder_with_provider(self.provider.clone())
            .with_safe_default_protocol_versions()?
            .with_no_client_auth()
            .with_cert_resolver(Arc::new(SingleCertAndKey::from(self.authority.leaf(host)?)));
        config.alpn_protocols = alpn.into_iter().collect();
        Ok(Arc::new(config))
    }
}

struct SelectedUpstream {
    target: ConnectTarget,
    prefix: String,
    use_original: bool,
    sender: UpstreamSender,
    task: Option<AbortOnDrop>,
}

async fn select_upstream(
    state: &ForwardState,
    endpoint: &str,
    primary: bool,
    inference: bool,
) -> Result<SelectedUpstream, &'static str> {
    let (target, prefix, use_original) = if inference {
        let uri = endpoint
            .parse::<hyper::Uri>()
            .map_err(|_| "invalid route endpoint")?;
        let authority = uri.authority().ok_or("invalid route endpoint")?;
        let target = ConnectTarget::try_from(
            format!(
                "{}:{}",
                authority.host(),
                authority.port_u16().unwrap_or(443)
            )
            .as_str(),
        )
        .map_err(|_| "invalid route endpoint")?;
        let prefix = uri.path().trim_end_matches('/').to_owned();
        if primary && target == state.route.target && prefix.is_empty() {
            (state.route.target.clone(), prefix, true)
        } else {
            (target, prefix, false)
        }
    } else {
        (state.route.target.clone(), String::new(), true)
    };
    let (sender, task) = if use_original {
        (state.sender.clone(), None)
    } else {
        let upstream = state
            .interceptor
            .connect(&target, vec![b"h2".to_vec(), b"http/1.1".to_vec()])
            .await
            .map_err(|_| "upstream connection failed")?;
        let protocol = HttpProtocol::from_alpn(upstream.get_ref().1.alpn_protocol());
        let (io, _shutdown) = shared_io(
            upstream,
            state.audit.client_to_upstream.clone(),
            Arc::new(Notify::new()),
        );
        let (sender, task) = start_upstream(protocol, io)
            .await
            .ok_or("upstream connection failed")?;
        (sender, Some(task))
    };
    Ok(SelectedUpstream {
        target,
        prefix,
        use_original,
        sender,
        task,
    })
}

fn prepare_request(
    mut request: Request<RequestBody>,
    selected: &SelectedUpstream,
    primary: bool,
) -> Result<Request<RequestBody>, &'static str> {
    *request.version_mut() = if selected.sender.requires_absolute_uri() {
        hyper::Version::HTTP_2
    } else {
        hyper::Version::HTTP_11
    };
    if !primary {
        request.headers_mut().remove(hyper::header::COOKIE);
    }
    if !selected.use_original {
        let authority = format!("{}:{}", selected.target.host(), selected.target.port());
        let host = HeaderValue::from_str(&authority).map_err(|_| "invalid route authority")?;
        request.headers_mut().insert(hyper::header::HOST, host);
    }
    if selected.sender.requires_absolute_uri() || !selected.use_original {
        let path_and_query = request
            .uri()
            .path_and_query()
            .map_or("/", |value| value.as_str());
        let path = format!("{}{path_and_query}", selected.prefix);
        let uri = if selected.sender.requires_absolute_uri() {
            format!(
                "https://{}:{}{path}",
                selected.target.host(),
                selected.target.port()
            )
        } else {
            path
        };
        *request.uri_mut() = uri.parse().map_err(|_| "invalid route URI")?;
    }
    Ok(request)
}

fn prepare_toolsearch_request(request: &mut Request<RequestBody>) -> Result<bool, &'static str> {
    let has_length = request.headers().contains_key(CONTENT_LENGTH);
    let mut new_length = None;
    let mut changed = false;
    if let RequestBody::Buffered { bytes, .. } = request.body_mut() {
        changed = toolsearch::request(bytes)?;
        if changed && has_length {
            new_length = HeaderValue::from_str(&bytes.len().to_string()).ok();
        }
    }
    if let Some(length) = new_length {
        request.headers_mut().insert(CONTENT_LENGTH, length);
    }
    if changed {
        request
            .headers_mut()
            .insert(ACCEPT_ENCODING, HeaderValue::from_static("identity"));
    }
    Ok(changed)
}

fn is_quota_header(name: &HeaderName) -> bool {
    name.as_str().starts_with(QUOTA_HEADER_PREFIX)
}

fn captured_quota_headers(
    headers: &hyper::HeaderMap<HeaderValue>,
) -> hyper::HeaderMap<HeaderValue> {
    let mut captured = hyper::HeaderMap::new();
    let mut values = 0;
    let mut bytes = 0;
    for (name, value) in headers.iter().filter(|(name, _)| is_quota_header(name)) {
        values += 1;
        bytes += name.as_str().len() + value.as_bytes().len();
        if values > QUOTA_HEADER_LIMIT || bytes > QUOTA_SNAPSHOT_LIMIT {
            return hyper::HeaderMap::new();
        }
        captured.append(name.clone(), value.clone());
    }
    captured
}

impl QuotaContext {
    fn key(&self, credential: &CredentialId) -> QuotaCacheKey {
        QuotaCacheKey {
            client: self.client.clone(),
            credential: credential.clone(),
            group: self.group.clone(),
        }
    }

    fn observe(&self, headers: &hyper::HeaderMap<HeaderValue>) {
        let key = self.key(&self.credential);
        let snapshot = QuotaSnapshot {
            headers: captured_quota_headers(headers),
            observed: Instant::now(),
        };
        let mut cache = self
            .cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if cache
            .get(&key)
            .is_none_or(|existing| snapshot.replaces(existing))
        {
            cache.insert(key, snapshot);
        }
    }

    fn apply(&self, status: StatusCode, headers: &mut hyper::HeaderMap<HeaderValue>) {
        self.observe(headers);
        if self.primary || !status.is_success() {
            return;
        }
        let quota_names = headers
            .keys()
            .filter(|name| is_quota_header(name))
            .cloned()
            .collect::<Vec<_>>();
        for name in quota_names {
            headers.remove(name);
        }
        let primary_key = self.key(&self.primary_credential);
        let snapshot = self
            .cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&primary_key)
            .map(|snapshot| snapshot.headers.clone())
            .unwrap_or_default();
        for (name, value) in &snapshot {
            headers.append(name.clone(), value.clone());
        }
    }
}

fn quota_context(
    state: &ForwardState,
    credential: &CredentialId,
    primary_credential: &CredentialId,
    primary: bool,
) -> QuotaContext {
    QuotaContext {
        cache: state.quota_cache.clone(),
        client: state.client.clone(),
        credential: credential.clone(),
        group: state.route.group.clone(),
        primary_credential: primary_credential.clone(),
        primary,
    }
}

async fn finish_response(
    mut response: Response<Incoming>,
    shim: bool,
    mut selected: SelectedUpstream,
    quota: QuotaContext,
    mut completion: RequestCompletion,
    client_upgrade: OnUpgrade,
    upgrades: mpsc::Sender<PendingUpgrade>,
) -> Reply {
    let status = response.status();
    if shim
        && status.is_success()
        && response
            .headers()
            .get(CONTENT_ENCODING)
            .is_some_and(|value| !value.as_bytes().eq_ignore_ascii_case(b"identity"))
    {
        completion.outcome = Some("toolsearch_compressed_response");
        completion.finish(StatusCode::BAD_GATEWAY);
        return crate::response(StatusCode::BAD_GATEWAY, "toolsearch_compressed_response");
    }
    let transform = shim && status.is_success();
    let sse = transform
        && response.headers().get(CONTENT_TYPE).is_some_and(|value| {
            value
                .as_bytes()
                .split(|byte| *byte == b';')
                .next()
                .is_some_and(|mime| mime.trim_ascii().eq_ignore_ascii_case(b"text/event-stream"))
        });
    if transform {
        response.headers_mut().remove(CONTENT_LENGTH);
    }
    strip_hop_by_hop(
        response.headers_mut(),
        status == StatusCode::SWITCHING_PROTOCOLS,
    );
    quota.apply(status, response.headers_mut());
    let mut selected_sender = (!selected.use_original).then_some(selected.sender.clone());
    if status == StatusCode::SWITCHING_PROTOCOLS {
        let upstream_upgrade = hyper::upgrade::on(&mut response);
        let pending = PendingUpgrade {
            client: client_upgrade,
            upstream: upstream_upgrade,
            task: selected.task.take(),
            _sender: selected_sender.take(),
        };
        if upgrades.send(pending).await.is_err() {
            return crate::response(StatusCode::INTERNAL_SERVER_ERROR, "connection closed");
        }
    }
    completion.finish(status);
    response.map(|body| {
        LeasedBody {
            inner: if sse {
                ResponsePayload::Sse {
                    inner: body,
                    bytes: Zeroizing::new(Vec::new()),
                    done: false,
                    pending: None,
                    skip_lf: false,
                    trailers: None,
                }
            } else if transform {
                ResponsePayload::Json {
                    inner: body,
                    bytes: Zeroizing::new(Vec::new()),
                    done: false,
                    trailers: None,
                }
            } else {
                ResponsePayload::Passthrough(body)
            },
            _task: selected.task,
            _sender: selected_sender,
        }
        .boxed_unsync()
    })
}

async fn forward(
    mut request: Request<Incoming>,
    state: ForwardState,
    upgrades: mpsc::Sender<PendingUpgrade>,
) -> Result<Reply, std::convert::Infallible> {
    let method = request.method().clone();
    let path = request.uri().path().to_owned();
    let mut completion = RequestCompletion::new(state.audit.clone(), method.clone(), path.clone());
    let client_upgrade = hyper::upgrade::on(&mut request);
    let upgrading = is_upgrade_request(request.headers());
    strip_hop_by_hop(request.headers_mut(), upgrading);
    let inference = method == Method::POST && path == "/v1/messages";
    let (mut request, model) = match inspect_request(request, inference).await {
        Ok(result) => result,
        Err(reason) => {
            let status = inspection_error_status(reason);
            completion.outcome = Some(reason);
            completion.finish(status);
            return Ok(crate::response(status, reason));
        }
    };
    let Some((credential_id, endpoint)) = state
        .route
        .config
        .route(&state.route.group, model.as_deref())
    else {
        completion.finish(StatusCode::FORBIDDEN);
        return Ok(crate::response(StatusCode::FORBIDDEN, "route unavailable"));
    };
    let credential_id = credential_id.clone();
    let has_model = model.is_some();
    completion.selected(credential_id.clone(), model);
    let Some(credential) = state.route.credentials.get(&credential_id) else {
        completion.finish(StatusCode::FORBIDDEN);
        return Ok(crate::response(
            StatusCode::FORBIDDEN,
            "credential unavailable",
        ));
    };
    let Some((primary_id, _)) = state.route.config.route(&state.route.group, None) else {
        completion.finish(StatusCode::FORBIDDEN);
        return Ok(crate::response(StatusCode::FORBIDDEN, "route unavailable"));
    };
    let primary = *primary_id == credential_id;
    let zai = inference
        && state
            .route
            .config
            .zai_anthropic(&state.route.group, &credential_id);
    let shim = if zai {
        match prepare_toolsearch_request(&mut request) {
            Ok(changed) => changed,
            Err(reason) => {
                completion.outcome = Some(reason);
                completion.finish(StatusCode::BAD_REQUEST);
                return Ok(crate::response(StatusCode::BAD_REQUEST, reason));
            }
        }
    } else {
        false
    };
    let Ok(selected) = select_upstream(&state, endpoint, primary, inference && has_model).await
    else {
        completion.finish(StatusCode::BAD_GATEWAY);
        return Ok(crate::response(
            StatusCode::BAD_GATEWAY,
            "upstream connection failed",
        ));
    };
    let Ok(request) = prepare_request(request, &selected, primary) else {
        completion.finish(StatusCode::BAD_GATEWAY);
        return Ok(crate::response(
            StatusCode::BAD_GATEWAY,
            "invalid upstream request",
        ));
    };
    let Ok(request) = swap_credential(request, credential) else {
        completion.finish(StatusCode::INTERNAL_SERVER_ERROR);
        return Ok(crate::response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "credential could not be encoded",
        ));
    };
    let Ok(response) = selected.sender.clone().send_request(request).await else {
        completion.finish(StatusCode::BAD_GATEWAY);
        return Ok(crate::response(
            StatusCode::BAD_GATEWAY,
            "upstream connection failed",
        ));
    };
    let quota = quota_context(&state, &credential_id, primary_id, primary);
    Ok(finish_response(
        response,
        shim,
        selected,
        quota,
        completion,
        client_upgrade,
        upgrades,
    )
    .await)
}

fn swap_credential<B>(
    mut request: Request<B>,
    credential: &LoadedCredential,
) -> Result<Request<B>, InvalidHeaderValue> {
    let headers = request.headers_mut();
    headers.remove(AUTHORIZATION);
    headers.remove(X_API_KEY);
    let value = credential_value(credential)?;
    headers.insert(
        match credential.auth {
            AuthKind::ApiKey => X_API_KEY,
            AuthKind::OauthBearer => AUTHORIZATION,
        },
        value,
    );
    Ok(request)
}

fn credential_value(credential: &LoadedCredential) -> Result<HeaderValue, InvalidHeaderValue> {
    let value = Zeroizing::new(match credential.auth {
        AuthKind::ApiKey => credential.secret.as_str().to_owned(),
        AuthKind::OauthBearer => format!("Bearer {}", credential.secret.as_str()),
    });
    HeaderValue::from_str(&value).map(|mut header| {
        header.set_sensitive(true);
        header
    })
}

fn is_upgrade_request(headers: &hyper::HeaderMap) -> bool {
    headers.contains_key(UPGRADE)
        && headers
            .get_all(CONNECTION)
            .iter()
            .filter_map(|value| value.to_str().ok())
            .flat_map(|value| value.split(','))
            .any(|token| token.trim().eq_ignore_ascii_case("upgrade"))
}

fn strip_hop_by_hop(headers: &mut hyper::HeaderMap, upgrading: bool) {
    let upgrade = upgrading.then(|| headers.get(UPGRADE).cloned()).flatten();
    let connection_named = headers
        .get_all(CONNECTION)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .map(str::trim)
        .filter(|token| !token.is_empty())
        .map(str::to_ascii_lowercase)
        .collect::<Vec<_>>();
    headers.remove(CONNECTION);
    for token in connection_named {
        headers.remove(token.as_str());
    }
    if let Some(upgrade) = upgrade {
        headers.insert(CONNECTION, HeaderValue::from_static("Upgrade"));
        headers.insert(UPGRADE, upgrade);
    }

    let trailer = headers
        .get_all(TE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .any(|value| {
            value
                .split(',')
                .map(str::trim)
                .any(|token| token == "trailers")
        });
    headers.remove(TE);
    if trailer {
        headers.insert(TE, HeaderValue::from_static("trailers"));
    }

    for header in [
        HeaderName::from_static("keep-alive"),
        PROXY_AUTHENTICATE,
        PROXY_AUTHORIZATION,
        TRAILER,
        TRANSFER_ENCODING,
    ] {
        headers.remove(header);
    }
    if !upgrading {
        headers.remove(UPGRADE);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use airlock_core::secret::SecretFile;

    #[test]
    fn every_sse_split_boundary_and_multiple_events_are_framed() {
        let first = b"event: content_block_start\r\ndata: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"name\":\"ToolSearch_\"}}\r\n\r\n";
        let second = b"event: keepalive\ndata: plain text\n\n";
        for split in 1..first.len() {
            let mut buffered = Vec::new();
            buffered.extend_from_slice(&first[..split]);
            if let Some(end) = sse_event_end(&buffered) {
                assert_eq!(end, split, "split {split}");
                assert_eq!(first[split], b'\n', "split {split}");
                let mut skip_lf = true;
                let suffix =
                    skip_optional_lf(Bytes::copy_from_slice(&first[split..]), &mut skip_lf);
                assert!(suffix.is_empty(), "split {split}");
                assert!(!skip_lf, "split {split}");
            }
            buffered.extend_from_slice(&first[split..]);
            buffered.extend_from_slice(second);
            let end = sse_event_end(&buffered).expect("first complete event");
            assert_eq!(end, first.len(), "split {split}");
            let mut event = Zeroizing::new(buffered[..end].to_vec());
            assert_eq!(toolsearch::event(&mut event), Ok(true));
            assert!(
                std::str::from_utf8(&event)
                    .expect("UTF-8")
                    .contains(r#""name":"ToolSearch""#)
            );
            assert_eq!(sse_event_end(&buffered[end..]), Some(second.len()));
        }
        assert_eq!(sse_event_end(b"data: {}\n\r\n"), Some(11));
        for first in [
            b"data: {}\r\r".as_slice(),
            b"data: {}\n\n".as_slice(),
            b"data: {}\r\n\r\n".as_slice(),
            b"data: {}\r\n\r".as_slice(),
        ] {
            assert_eq!(sse_event_end(first), Some(first.len()));
        }
        let mut skip_lf = true;
        assert_eq!(
            skip_optional_lf(Bytes::from_static(b"event: next\r\r"), &mut skip_lf),
            Bytes::from_static(b"event: next\r\r")
        );
        assert!(!skip_lf);
    }

    fn quota_context(
        cache: &QuotaCache,
        client: &str,
        credential: &str,
        group: &str,
        primary_credential: &str,
        primary: bool,
    ) -> QuotaContext {
        QuotaContext {
            cache: cache.clone(),
            client: ClientId::try_from(client).expect("client"),
            credential: CredentialId::try_from(credential).expect("credential"),
            group: GroupId::try_from(group).expect("group"),
            primary_credential: CredentialId::try_from(primary_credential).expect("primary"),
            primary,
        }
    }

    fn quota_headers(values: &[(&str, &str)]) -> hyper::HeaderMap<HeaderValue> {
        let mut headers = hyper::HeaderMap::new();
        for (name, value) in values {
            headers.insert(
                HeaderName::from_bytes(name.as_bytes()).expect("header name"),
                HeaderValue::from_str(value).expect("header value"),
            );
        }
        headers
    }

    #[test]
    fn quota_snapshot_order_uses_observation_instants() {
        let newer = Instant::now();
        let older = newer
            .checked_sub(Duration::from_nanos(1))
            .expect("older instant");
        let snapshot = |observed| QuotaSnapshot {
            headers: hyper::HeaderMap::new(),
            observed,
        };
        assert!(snapshot(newer).replaces(&snapshot(older)));
        assert!(!snapshot(older).replaces(&snapshot(newer)));
        assert!(snapshot(newer).replaces(&snapshot(newer)));
    }

    #[test]
    fn quota_snapshots_replace_atomically_and_enforce_value_and_byte_limits() {
        let cache: QuotaCache = Arc::new(Mutex::new(BTreeMap::new()));
        let primary = quota_context(&cache, "client", "claude", "group", "claude", true);
        primary.observe(&quota_headers(&[
            ("anthropic-ratelimit-unified-status", "allowed"),
            ("anthropic-ratelimit-unified-5h-utilization", "0.42"),
        ]));
        let first = primary
            .cache
            .lock()
            .expect("cache lock")
            .get(&primary.key(&primary.credential))
            .cloned()
            .expect("first snapshot");
        assert!(first.observed.elapsed() <= Duration::from_secs(1));

        primary.observe(&quota_headers(&[(
            "anthropic-ratelimit-unified-status",
            "limited",
        )]));
        let non_primary = quota_context(&cache, "client", "zai", "group", "claude", false);
        let mut headers = quota_headers(&[
            ("anthropic-ratelimit-unified-status", "rejected"),
            ("anthropic-ratelimit-unified-5h-utilization", "0.9"),
            ("retry-after", "9"),
            ("x-ordinary", "kept"),
        ]);
        non_primary.apply(StatusCode::OK, &mut headers);
        assert_eq!(headers["anthropic-ratelimit-unified-status"], "limited");
        assert!(
            headers
                .get("anthropic-ratelimit-unified-5h-utilization")
                .is_none()
        );
        assert_eq!(headers["retry-after"], "9");
        assert_eq!(headers["x-ordinary"], "kept");

        primary.observe(&hyper::HeaderMap::new());
        let snapshot = primary
            .cache
            .lock()
            .expect("cache lock")
            .get(&primary.key(&primary.credential))
            .cloned()
            .expect("empty snapshot retained for age");
        assert!(snapshot.headers.is_empty());

        let name = HeaderName::from_static("anthropic-ratelimit-unified-status");
        let at_byte_limit =
            HeaderValue::from_bytes(&vec![b'x'; QUOTA_SNAPSHOT_LIMIT - name.as_str().len()])
                .expect("exact-limit value");
        let mut boundary = hyper::HeaderMap::new();
        boundary.insert(name.clone(), at_byte_limit);
        primary.observe(&boundary);
        let snapshot = primary
            .cache
            .lock()
            .expect("cache lock")
            .get(&primary.key(&primary.credential))
            .cloned()
            .expect("exact-limit snapshot");
        assert_eq!(snapshot.headers.get(&name), boundary.get(&name));

        let over_byte_limit =
            HeaderValue::from_bytes(&vec![b'x'; QUOTA_SNAPSHOT_LIMIT - name.as_str().len() + 1])
                .expect("over-limit value");
        boundary.insert(name.clone(), over_byte_limit);
        primary.observe(&boundary);
        let snapshot = primary
            .cache
            .lock()
            .expect("cache lock")
            .get(&primary.key(&primary.credential))
            .cloned()
            .expect("byte-overflow snapshot replaces old state");
        assert!(snapshot.headers.is_empty());

        let mut duplicates = hyper::HeaderMap::new();
        for _ in 0..QUOTA_HEADER_LIMIT {
            duplicates.append(name.clone(), HeaderValue::from_static("x"));
        }
        assert_eq!(
            captured_quota_headers(&duplicates)
                .get_all(&name)
                .iter()
                .count(),
            QUOTA_HEADER_LIMIT
        );
        duplicates.append(name, HeaderValue::from_static("x"));
        primary.observe(&duplicates);
        let snapshot = primary
            .cache
            .lock()
            .expect("cache lock")
            .get(&primary.key(&primary.credential))
            .cloned()
            .expect("value-overflow snapshot replaces old state");
        assert!(snapshot.headers.is_empty());
    }

    #[test]
    fn quota_cache_is_isolated_by_client_group_and_credential() {
        let cache: QuotaCache = Arc::new(Mutex::new(BTreeMap::new()));
        let primary = quota_context(&cache, "client-a", "claude", "group-a", "claude", true);
        primary.observe(&quota_headers(&[(
            "anthropic-ratelimit-unified-status",
            "allowed",
        )]));
        let other_group = quota_context(&cache, "client-a", "zai", "group-b", "claude", false);
        let mut headers = quota_headers(&[
            ("anthropic-ratelimit-unified-status", "rejected"),
            ("retry-after", "9"),
        ]);
        other_group.apply(StatusCode::OK, &mut headers);
        assert_eq!(headers["retry-after"], "9");
        assert_eq!(headers.len(), 1);

        let other_client = quota_context(&cache, "client-b", "zai", "group-a", "claude", false);
        let mut headers = quota_headers(&[("anthropic-ratelimit-unified-status", "rejected")]);
        other_client.apply(StatusCode::OK, &mut headers);
        assert!(headers.is_empty());

        let non_primary = quota_context(&cache, "client-a", "zai", "group-a", "claude", false);
        non_primary.observe(&quota_headers(&[(
            "anthropic-ratelimit-unified-7d-utilization",
            "0.9",
        )]));
        let mut headers = quota_headers(&[
            ("anthropic-ratelimit-unified-status", "rejected"),
            ("retry-after", "9"),
        ]);
        non_primary.apply(StatusCode::OK, &mut headers);
        assert_eq!(headers["anthropic-ratelimit-unified-status"], "allowed");
        assert_eq!(headers["retry-after"], "9");
        assert_eq!(cache.lock().expect("cache lock").len(), 4);
    }

    #[test]
    fn concurrent_quota_observations_leave_one_complete_snapshot() {
        let cache: QuotaCache = Arc::new(Mutex::new(BTreeMap::new()));
        let observer = quota_context(&cache, "client", "claude", "group", "claude", true);
        let threads = [("snapshot-a", "11"), ("snapshot-b", "22")]
            .into_iter()
            .map(|(status, reset)| {
                let observer = observer.clone();
                std::thread::spawn(move || {
                    observer.observe(&quota_headers(&[
                        ("anthropic-ratelimit-unified-status", status),
                        ("anthropic-ratelimit-unified-reset", reset),
                    ]));
                })
            })
            .collect::<Vec<_>>();
        for thread in threads {
            thread.join().expect("quota observer");
        }
        let snapshot = observer
            .cache
            .lock()
            .expect("cache lock")
            .get(&observer.key(&observer.credential))
            .cloned()
            .expect("snapshot");
        let status = snapshot
            .headers
            .get("anthropic-ratelimit-unified-status")
            .expect("status");
        let reset = snapshot.headers["anthropic-ratelimit-unified-reset"].as_bytes();
        assert!(
            (status == "snapshot-a" && reset == b"11")
                || (status == "snapshot-b" && reset == b"22")
        );
    }

    #[test]
    fn exact_limit_json_in_uneven_chunks_keeps_bounded_capacity() {
        let mut body = br#"{"model":"glm-4.7","pad":""#.to_vec();
        body.resize(MODEL_BODY_LIMIT - 2, b'x');
        body.extend_from_slice(b"\"}");
        assert_eq!(body.len(), MODEL_BODY_LIMIT);

        for fixed_capacity in [false, true] {
            let mut retained = Zeroizing::new(Vec::with_capacity(if fixed_capacity {
                MODEL_BODY_LIMIT
            } else {
                0
            }));
            for chunk in body.chunks(1003) {
                append_inference_chunk(&mut retained, chunk, fixed_capacity)
                    .expect("exact limit fits");
                assert!(retained.capacity() <= MODEL_BODY_LIMIT);
            }
            assert_eq!(parse_model(&retained), Ok(Some("glm-4.7".to_owned())));
        }
    }

    fn credential(auth: AuthKind, path: &std::path::Path) -> Arc<LoadedCredential> {
        Arc::new(LoadedCredential {
            auth,
            secret: SecretFile::try_from(path.to_path_buf())
                .expect("secret path")
                .load()
                .expect("secret fixture"),
        })
    }

    #[test]
    fn swap_replaces_client_auth_and_leaves_other_headers() {
        let directory = tempfile::tempdir().expect("tempdir");
        let bearer = directory.path().join("bearer");
        std::fs::write(&bearer, "fake-REAL-bearer").expect("bearer");
        let api_key = directory.path().join("api-key");
        std::fs::write(&api_key, "fake-REAL-api-key").expect("api key");

        let request = Request::builder()
            .method(Method::POST)
            .uri("/v1/messages?query=fake-CLIENT-query")
            .header(AUTHORIZATION, "Bearer fake-CLIENT-bearer")
            .header(X_API_KEY, "fake-CLIENT-api-key")
            .header("anthropic-beta", "test")
            .body(http_body_util::Empty::<hyper::body::Bytes>::new())
            .expect("request");
        let swapped = swap_credential(request, &credential(AuthKind::OauthBearer, &bearer))
            .expect("oauth swap");
        assert_eq!(swapped.headers()[AUTHORIZATION], "Bearer fake-REAL-bearer");
        assert!(swapped.headers()[AUTHORIZATION].is_sensitive());
        assert!(swapped.headers().get(X_API_KEY).is_none());
        assert_eq!(swapped.headers()["anthropic-beta"], "test");

        let request = Request::builder()
            .method(Method::POST)
            .uri("/v1/messages")
            .header(AUTHORIZATION, "Bearer fake-CLIENT-bearer")
            .header(X_API_KEY, "fake-CLIENT-api-key")
            .body(http_body_util::Empty::<hyper::body::Bytes>::new())
            .expect("request");
        let swapped =
            swap_credential(request, &credential(AuthKind::ApiKey, &api_key)).expect("key swap");
        assert_eq!(swapped.headers()[X_API_KEY], "fake-REAL-api-key");
        assert!(swapped.headers()[X_API_KEY].is_sensitive());
        assert!(swapped.headers().get(AUTHORIZATION).is_none());
    }
}

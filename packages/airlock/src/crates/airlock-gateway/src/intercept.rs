//! HTTP interception: terminate client TLS, open verified upstream TLS, swap credentials.

use std::{
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll},
    time::Duration,
};

use airlock_core::{ids::HostName, target::ConnectTarget};
use http_body_util::Either;
use hyper::{
    Method, Request, Response, StatusCode,
    body::Incoming,
    client::conn as client_conn,
    header::{
        AUTHORIZATION, CONNECTION, HeaderName, HeaderValue, InvalidHeaderValue, PROXY_AUTHENTICATE,
        PROXY_AUTHORIZATION, TE, TRAILER, TRANSFER_ENCODING, UPGRADE,
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
    record_completed_write, relay_streams,
};

// A client gets this long to send its ClientHello, and later to finish its handshake.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const X_API_KEY: HeaderName = HeaderName::from_static("x-api-key");

pub(crate) struct Interceptor {
    authority: Authority,
    provider: Arc<CryptoProvider>,
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
            path,
        }
    }

    fn finish(mut self, status: StatusCode) {
        self.completed = true;
        tracing::dispatcher::with_default(&self.audit.dispatch, || {
            tracing::debug!(
                method = self.method.as_str(),
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
    Http1(Arc<AsyncHttp1SenderMutex<client_conn::http1::SendRequest<Incoming>>>),
    Http2(client_conn::http2::SendRequest<Incoming>),
}

impl UpstreamSender {
    fn requires_absolute_uri(&self) -> bool {
        matches!(self, Self::Http2(_))
    }

    async fn send_request(
        self,
        request: Request<Incoming>,
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
struct ForwardState {
    absolute_uri: bool,
    authority: String,
    audit: RequestAudit,
    credential: Arc<LoadedCredential>,
    sender: UpstreamSender,
}

struct PendingUpgrade {
    client: OnUpgrade,
    upstream: OnUpgrade,
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
            upstream: Arc::new(upstream),
        })
    }

    pub(crate) async fn run(
        &self,
        client: TokioIo<hyper::upgrade::Upgraded>,
        target: ConnectTarget,
        credential: Arc<LoadedCredential>,
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
        let offered = hello
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
        self.forward_connection(start, upstream, &target, negotiated, credential, audit)
            .await;
    }

    async fn forward_connection(
        &self,
        start: StartHandshake<TokioIo<hyper::upgrade::Upgraded>>,
        mut upstream: client::TlsStream<TcpStream>,
        target: &ConnectTarget,
        negotiated: Option<Vec<u8>>,
        credential: Arc<LoadedCredential>,
        mut audit: Audit,
    ) {
        let protocol = HttpProtocol::from_alpn(negotiated.as_deref());
        let Ok(config) = self.server_config(target.host(), negotiated) else {
            audit.outcome = "leaf_error";
            let _ = timeout(crate::CLOSE_GRACE, upstream.shutdown()).await;
            return;
        };
        let Ok(Ok(client)) = timeout(HANDSHAKE_TIMEOUT, start.into_stream(config)).await else {
            audit.outcome = "client_tls_error";
            let _ = timeout(crate::CLOSE_GRACE, upstream.shutdown()).await;
            return;
        };
        Self::serve_forwarding(client, upstream, target, protocol, credential, audit).await;
    }

    async fn serve_forwarding(
        client: server::TlsStream<TokioIo<hyper::upgrade::Upgraded>>,
        upstream: client::TlsStream<TcpStream>,
        target: &ConnectTarget,
        protocol: HttpProtocol,
        credential: Arc<LoadedCredential>,
        mut audit: Audit,
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

        let sender_requires_absolute_uri = sender.requires_absolute_uri();
        let request_audit = RequestAudit {
            dispatch: audit.dispatch.clone(),
            requests: audit.requests.clone(),
        };
        let (upgrade_sender, mut upgrade_receiver) = mpsc::channel(1);
        let forwarding = ForwardState {
            absolute_uri: sender_requires_absolute_uri,
            authority: format!("{}:{}", target.host(), target.port()),
            audit: request_audit,
            credential,
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

async fn forward(
    mut request: Request<Incoming>,
    state: ForwardState,
    upgrades: mpsc::Sender<PendingUpgrade>,
) -> Result<Reply, std::convert::Infallible> {
    let method = request.method().clone();
    let path = request.uri().path().to_owned();
    let completion = RequestCompletion::new(state.audit.clone(), method.clone(), path.clone());
    let client_upgrade = hyper::upgrade::on(&mut request);
    let upgrading = is_upgrade_request(request.headers());
    strip_hop_by_hop(request.headers_mut(), upgrading);
    if state.absolute_uri {
        let path_and_query = request
            .uri()
            .path_and_query()
            .map(|value| value.as_str().to_owned())
            .unwrap_or_default();
        let Ok(uri) = format!("https://{}{path_and_query}", state.authority).parse::<hyper::Uri>()
        else {
            completion.finish(StatusCode::INTERNAL_SERVER_ERROR);
            return Ok(crate::response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "invalid upstream URI",
            ));
        };
        *request.uri_mut() = uri;
    }
    let Ok(request) = swap_credential(request, &state.credential) else {
        completion.finish(StatusCode::INTERNAL_SERVER_ERROR);
        return Ok(crate::response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "credential could not be encoded",
        ));
    };
    let sender = state.sender.clone();
    let Ok(mut response) = sender.send_request(request).await else {
        completion.finish(StatusCode::BAD_GATEWAY);
        return Ok(crate::response(
            StatusCode::BAD_GATEWAY,
            "upstream connection failed",
        ));
    };
    let status = response.status();
    strip_hop_by_hop(
        response.headers_mut(),
        status == StatusCode::SWITCHING_PROTOCOLS,
    );
    if status == StatusCode::SWITCHING_PROTOCOLS {
        let upstream_upgrade = hyper::upgrade::on(&mut response);
        let pending = PendingUpgrade {
            client: client_upgrade,
            upstream: upstream_upgrade,
        };
        if upgrades.send(pending).await.is_err() {
            return Ok(crate::response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "connection closed",
            ));
        }
    }
    completion.finish(status);
    Ok(response.map(Either::Left))
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

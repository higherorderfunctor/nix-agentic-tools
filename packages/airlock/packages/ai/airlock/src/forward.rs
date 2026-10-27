// cspell:words dechunks keepalive
use std::{
    future::Future,
    io,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
    time::Duration,
};

use http_body_util::{Either, Full};
use hyper::{
    HeaderMap, Request, Response, StatusCode, Uri, Version,
    body::{Bytes, Incoming},
    header::{
        CONNECTION, CONTENT_LENGTH, HeaderName, HeaderValue, PROXY_AUTHENTICATE,
        PROXY_AUTHORIZATION, TE, TRAILER, TRANSFER_ENCODING, UPGRADE,
    },
};
use hyper_util::{
    client::legacy::{Client, connect::HttpConnector},
    rt::{TokioExecutor, TokioIo, TokioTimer},
};
use tokio::{net::TcpStream, sync::Mutex, time::timeout};
use tower_service::Service;

use crate::{resolver::Resolver, upstream::CONNECT_TIMEOUT};

const POOL_IDLE_TIMEOUT: Duration = Duration::from_secs(30);

pub(super) type ProxyResponse = Response<Either<Full<Bytes>, Incoming>>;
type Pool = Client<Connector, Incoming>;

#[derive(Clone)]
pub(super) struct Forwarder {
    current: Arc<Mutex<Option<(String, Pool)>>>,
}

impl Forwarder {
    pub(super) fn new() -> Self {
        Self {
            current: Arc::new(Mutex::new(None)),
        }
    }

    pub(super) async fn forward(&self, mut request: Request<Incoming>) -> ProxyResponse {
        let Some(target) = ForwardTarget::parse(request.uri()) else {
            return response(StatusCode::BAD_REQUEST, "malformed HTTP proxy target");
        };

        if request.version() != Version::HTTP_11 {
            return response(
                StatusCode::HTTP_VERSION_NOT_SUPPORTED,
                "HTTP/1.1 absolute-form requests are required",
            );
        }

        if !supported_transfer_encoding(request.headers()) {
            return response(
                StatusCode::BAD_REQUEST,
                "unsupported request transfer coding",
            );
        }
        let chunked = request.headers().contains_key(TRANSFER_ENCODING);

        if !strip_hop_by_hop(request.headers_mut()) {
            return response(StatusCode::BAD_REQUEST, "malformed Connection header");
        }

        // Incoming has decoded the chunks. Explicitly request fresh framing:
        // Hyper otherwise treats unknown-length GET and HEAD bodies as empty.
        if chunked {
            request
                .headers_mut()
                .insert(TRANSFER_ENCODING, HeaderValue::from_static("chunked"));
        }
        request
            .headers_mut()
            .insert(hyper::header::HOST, target.host);
        *request.uri_mut() = target.uri;

        let client = self.client_for(&target.authority).await;
        let mut upstream = match client.request(request).await {
            Ok(upstream) => upstream,
            Err(_) => {
                self.remove_current().await;
                return response(StatusCode::BAD_GATEWAY, "upstream request failed");
            }
        };

        if !supported_transfer_encoding(upstream.headers())
            || (upstream.headers().contains_key(TRANSFER_ENCODING)
                && upstream.headers().contains_key(CONTENT_LENGTH))
        {
            self.remove_current().await;
            return response(StatusCode::BAD_GATEWAY, "unsupported upstream framing");
        }

        if !strip_hop_by_hop(upstream.headers_mut()) {
            self.remove_current().await;
            return response(
                StatusCode::BAD_GATEWAY,
                "malformed upstream Connection header",
            );
        }

        upstream.map(Either::Right)
    }

    async fn client_for(&self, authority: &str) -> Pool {
        let mut current = self.current.lock().await;
        if let Some((current_authority, client)) = current.as_ref()
            && current_authority == authority
        {
            return client.clone();
        }

        let client = new_client();
        *current = Some((authority.to_owned(), client.clone()));
        client
    }

    async fn remove_current(&self) {
        self.current.lock().await.take();
    }
}

fn new_client() -> Pool {
    let mut connector = HttpConnector::new_with_resolver(Resolver);
    connector.set_connect_timeout(Some(CONNECT_TIMEOUT));
    connector.set_keepalive(Some(POOL_IDLE_TIMEOUT));

    let client: Pool = Client::builder(TokioExecutor::new())
        .pool_idle_timeout(POOL_IDLE_TIMEOUT)
        .pool_max_idle_per_host(1)
        .pool_timer(TokioTimer::new())
        .retry_canceled_requests(false)
        .build(Connector(connector));
    client
}

#[derive(Clone)]
struct Connector(HttpConnector<Resolver>);

impl Service<Uri> for Connector {
    type Response = TokioIo<TcpStream>;
    type Error = io::Error;
    type Future = Pin<Box<dyn Future<Output = io::Result<Self::Response>> + Send>>;

    fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, target: Uri) -> Self::Future {
        let connecting = self.0.call(target);
        Box::pin(async move {
            // HttpConnector's timeout covers TCP alone. Include DNS capacity
            // and lookup in this dial deadline, without timing the response.
            timeout(CONNECT_TIMEOUT, connecting)
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "upstream dial timed out"))?
                .map_err(io::Error::other)
        })
    }
}

struct ForwardTarget {
    authority: String,
    host: HeaderValue,
    uri: Uri,
}

impl ForwardTarget {
    fn parse(uri: &Uri) -> Option<Self> {
        if uri.scheme().map(|scheme| scheme.as_str()) != Some("http") {
            return None;
        }

        let authority = uri.authority()?;
        if authority.as_str().contains('@') {
            return None;
        }
        crate::authority::parse(authority.as_str(), Some(80))?;

        let path = uri.path_and_query()?;
        if path.path().is_empty() || !path.path().starts_with('/') {
            return None;
        }

        Some(Self {
            authority: authority.as_str().to_owned(),
            host: HeaderValue::from_str(authority.as_str()).ok()?,
            uri: uri.clone(),
        })
    }
}

fn supported_transfer_encoding(headers: &HeaderMap<HeaderValue>) -> bool {
    let mut values = headers.get_all(TRANSFER_ENCODING).iter();
    match values.next() {
        None => true,
        Some(value) => {
            // Hyper only dechunks: accepting another coding would lose its
            // metadata when the hop headers are stripped below.
            value
                .as_bytes()
                .trim_ascii()
                .eq_ignore_ascii_case(b"chunked")
                && values.next().is_none()
        }
    }
}

fn strip_hop_by_hop(headers: &mut HeaderMap<HeaderValue>) -> bool {
    let mut connection_named = Vec::new();
    for value in headers.get_all(CONNECTION) {
        for token in value.as_bytes().split(|byte| *byte == b',') {
            let token = token.trim_ascii();
            if token.is_empty() {
                continue;
            }
            let Ok(name) = HeaderName::from_bytes(token) else {
                return false;
            };
            connection_named.push(name);
        }
    }

    headers.remove(CONNECTION);
    for name in connection_named {
        headers.remove(name);
    }

    for name in [
        HeaderName::from_static("keep-alive"),
        HeaderName::from_static("proxy-connection"),
        PROXY_AUTHENTICATE,
        PROXY_AUTHORIZATION,
        TE,
        TRAILER,
        TRANSFER_ENCODING,
        UPGRADE,
    ] {
        headers.remove(name);
    }
    true
}

pub(super) fn response(status: StatusCode, body: &'static str) -> ProxyResponse {
    Response::builder()
        .status(status)
        .body(Either::Left(Full::new(Bytes::from_static(body.as_bytes()))))
        .expect("static HTTP response is valid")
}

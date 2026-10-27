//! Absolute-form `http://` requests on an HTTP/1.1 connection: check the
//! target, send the request upstream through a connection pool, and stream
//! the response back.
// cspell:words keepalive
use std::{
    future::Future,
    io,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
    time::Duration,
};

use http_body_util::Either;
use hyper::{Request, StatusCode, Uri, body::Incoming, header::HeaderValue};
use hyper_util::{
    client::legacy::{Client, connect::HttpConnector},
    rt::{TokioExecutor, TokioIo, TokioTimer},
};
use tokio::{net::TcpStream, sync::Mutex, time::timeout};
use tower_service::Service;

use crate::{
    client::replies::proxy_response,
    http::message::{ProxyResponse, prepare_request, prepare_response},
    upstream::{CONNECT_TIMEOUT, resolver::Resolver},
};

const POOL_IDLE_TIMEOUT: Duration = Duration::from_secs(30);

type Pool = Client<Connector, Incoming>;

/// One client connection's upstream pool. Pools are never shared between
/// client connections, and switching authority drops the previous pool.
#[derive(Clone)]
pub(crate) struct Forwarder {
    // The current authority and its pool. Each request's future holds a clone,
    // so access goes through a lock.
    current: Arc<Mutex<Option<(String, Pool)>>>,
}

impl Forwarder {
    pub(crate) fn new() -> Self {
        Self {
            current: Arc::new(Mutex::new(None)),
        }
    }

    pub(crate) async fn forward(&self, mut request: Request<Incoming>) -> ProxyResponse {
        let Some(target) = ForwardTarget::parse(request.uri()) else {
            return proxy_response(StatusCode::BAD_REQUEST, "malformed HTTP proxy target\n");
        };

        if let Err((status, message)) = prepare_request(&mut request) {
            return proxy_response(status, message);
        }
        request
            .headers_mut()
            .insert(hyper::header::HOST, target.host);

        let client = self.client_for(&target.authority).await;
        let mut upstream = match client.request(request).await {
            Ok(upstream) => upstream,
            Err(_) => {
                self.remove_current().await;
                return proxy_response(StatusCode::BAD_GATEWAY, "upstream request failed\n");
            }
        };

        if let Err(message) = prepare_response(&mut upstream) {
            self.remove_current().await;
            return proxy_response(StatusCode::BAD_GATEWAY, message);
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

    Client::builder(TokioExecutor::new())
        .pool_idle_timeout(POOL_IDLE_TIMEOUT)
        .pool_max_idle_per_host(1)
        .pool_timer(TokioTimer::new())
        .retry_canceled_requests(false)
        .build(Connector(connector))
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
            // and lookup in this connect deadline, without timing the response.
            timeout(CONNECT_TIMEOUT, connecting)
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "upstream connect timed out"))?
                .map_err(io::Error::other)
        })
    }
}

struct ForwardTarget {
    authority: String,
    host: HeaderValue,
}

impl ForwardTarget {
    fn parse(uri: &Uri) -> Option<Self> {
        if uri.scheme().map(|scheme| scheme.as_str()) != Some("http") {
            return None;
        }

        let authority = uri.authority()?;
        crate::http::authority::parse(authority.as_str(), Some(80))?;

        let path = uri.path_and_query()?;
        if !path.path().starts_with('/') {
            return None;
        }

        Some(Self {
            authority: authority.as_str().to_owned(),
            host: HeaderValue::from_str(authority.as_str()).ok()?,
        })
    }
}

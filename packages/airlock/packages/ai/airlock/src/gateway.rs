//! A route grant shared by the explicit endpoint and an authorized CONNECT tunnel.
mod config;
pub(crate) mod tls;
mod usage;

use std::{
    collections::BTreeMap, convert::Infallible, net::SocketAddr, path::Path, time::Duration,
};

use base64::{Engine, engine::general_purpose::STANDARD};
use http_body_util::{BodyExt, Full, Limited, combinators::UnsyncBoxBody};
use hyper::{
    Method, Request, Response, StatusCode, Uri,
    body::{Bytes, Incoming},
    header::{
        AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderName, HeaderValue, PROXY_AUTHORIZATION,
    },
};
use hyper_rustls::{HttpsConnector, HttpsConnectorBuilder};
use hyper_util::{
    client::legacy::{Client, connect::HttpConnector},
    rt::TokioExecutor,
};
use serde_json::Value;
use subtle::ConstantTimeEq;
use tokio::time::timeout;
use zeroize::Zeroizing;

use crate::client::replies;
use config::{Authentication, Plan, secret};
use usage::{Attempt, Ledger};

type HttpClient = Client<HttpsConnector<HttpConnector>, Full<Bytes>>;
pub(crate) type Reply = Response<UnsyncBoxBody<Bytes, hyper::Error>>;

const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

pub(crate) struct Gateway {
    clients: BTreeMap<String, HeaderValue>,
    routes: Vec<Route>,
    interception: Option<tls::Interception>,
    management: Option<(SocketAddr, HeaderValue)>,
    upstream: HttpClient,
    ledger: Ledger,
}

struct Route {
    client: String,
    path: String,
    model: String,
    primary: Destination,
    fallback: Option<Destination>,
}

struct Destination {
    uri: Uri,
    credential: (HeaderName, HeaderValue),
    pool: String,
    model: Option<String>,
    unwrap: Option<String>,
}

impl Gateway {
    pub fn load(path: &Path) -> Result<Self, String> {
        let plan = Plan::read(path)?;
        let mut clients = BTreeMap::new();
        for (name, path) in plan.clients {
            let token = secret(&path)?;
            if name.is_empty()
                || !name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"_-".contains(&byte))
                || clients.values().any(|other| other == &token)
            {
                return Err("clients must have simple names and distinct tokens".into());
            }
            clients.insert(name, token);
        }
        let mut routes = Vec::<Route>::new();
        for route in plan.routes {
            if !matches!(route.path.as_str(), "/v1/messages" | "/v1/passthrough")
                || route.model.is_empty()
                || !clients.contains_key(&route.client)
                || routes.iter().any(|other| {
                    other.client == route.client
                        && other.path == route.path
                        && other.model == route.model
                })
            {
                return Err("routes must name a client, supported path, and unique nonempty model for that grant".into());
            }
            let allow_unwrap = route.path == "/v1/passthrough";
            routes.push(Route {
                client: route.client,
                path: route.path,
                model: route.model,
                primary: Destination::load(route.primary, allow_unwrap)?,
                fallback: route
                    .fallback
                    .map(|target| Destination::load(target, allow_unwrap))
                    .transpose()?,
            });
        }
        if routes.is_empty() {
            return Err("at least one route is required".into());
        }
        let management = plan
            .management
            .map(|settings| {
                let management_token = secret(&settings.token_file)?;
                if clients.values().any(|token| token == &management_token) {
                    return Err("management must use its own token".to_owned());
                }
                Ok((settings.listen, management_token))
            })
            .transpose()?;
        let mut tcp = HttpConnector::new();
        tcp.enforce_http(false);
        tcp.set_connect_timeout(Some(REQUEST_TIMEOUT));
        let connector = HttpsConnectorBuilder::new()
            .with_webpki_roots()
            .https_or_http()
            .enable_http1()
            .wrap_connector(tcp);
        Ok(Self {
            clients,
            routes,
            interception: plan
                .intercept
                .map(|target| tls::Interception::load(&target, plan.ca_instance))
                .transpose()?,
            management,
            upstream: Client::builder(TokioExecutor::new()).build(connector),
            ledger: Ledger::default(),
        })
    }

    pub fn management_address(&self) -> Option<SocketAddr> {
        self.management.as_ref().map(|(address, _)| *address)
    }

    pub fn intercepts(&self, host: &str, port: u16) -> bool {
        self.interception
            .as_ref()
            .is_some_and(|target| target.matches(host, port))
    }

    pub fn connect_client(&self, headers: &HeaderMap) -> Option<&str> {
        let encoded = headers
            .get(PROXY_AUTHORIZATION)?
            .as_bytes()
            .strip_prefix(b"Basic ")?;
        let decoded = Zeroizing::new(STANDARD.decode(encoded).ok()?);
        let (name, token) = std::str::from_utf8(&decoded).ok()?.split_once(':')?;
        let (client, expected) = self.clients.get_key_value(name)?;
        let can_intercept = self
            .routes
            .iter()
            .any(|route| route.client == name && route.path == "/v1/messages");
        (can_intercept && bool::from(token.as_bytes().ct_eq(expected.as_bytes()))).then_some(client)
    }

    pub async fn explicit(&self, request: Request<Incoming>) -> Result<Reply, Infallible> {
        let Some((client, _)) = self
            .clients
            .iter()
            .find(|(_, token)| bearer(request.headers(), token))
        else {
            return reply(StatusCode::UNAUTHORIZED, "client token required\n");
        };
        self.forward(client, request).await
    }

    /// Both ingress paths have authenticated the client before calling here.
    pub async fn forward(
        &self,
        client: &str,
        request: Request<Incoming>,
    ) -> Result<Reply, Infallible> {
        let (head, body) = request.into_parts();
        let downstream_version = head.version;
        if head.method != Method::POST
            || head.uri.scheme().is_some()
            || head.uri.authority().is_some()
            || head.uri.query().is_some()
            || !matches!(head.uri.path(), "/v1/messages" | "/v1/passthrough")
        {
            return reply(StatusCode::NOT_FOUND, "unknown inference operation\n");
        }
        let Ok(Ok(collected)) = timeout(
            REQUEST_TIMEOUT,
            Limited::new(body, MAX_REQUEST_BYTES).collect(),
        )
        .await
        else {
            return reply(
                StatusCode::BAD_REQUEST,
                "invalid, oversized, or slow request body\n",
            );
        };
        let Ok(payload) = serde_json::from_slice::<Value>(&collected.to_bytes()) else {
            return reply(StatusCode::BAD_REQUEST, "expected JSON\n");
        };
        let Some(model) = payload.get("model").and_then(Value::as_str) else {
            return reply(StatusCode::BAD_REQUEST, "model required\n");
        };
        if head.uri.path() == "/v1/passthrough"
            && payload
                .get("stream")
                .is_some_and(|stream| stream != &Value::Bool(false))
        {
            return reply(StatusCode::BAD_REQUEST, "JSON passthrough cannot stream\n");
        }
        let Some(route) = self.routes.iter().find(|route| {
            route.client == client && route.path == head.uri.path() && route.model == model
        }) else {
            return reply(StatusCode::FORBIDDEN, "route is outside the client grant\n");
        };

        let primary = self
            .attempt(&route.primary, route, &head.headers, &payload)
            .await;
        let selected = match (primary, &route.fallback) {
            (Ok((response, attempt, _)), Some(fallback))
                if matches!(
                    response.status(),
                    StatusCode::TOO_MANY_REQUESTS | StatusCode::SERVICE_UNAVAILABLE
                ) =>
            {
                drop(attempt);
                drop(response);
                self.attempt(fallback, route, &head.headers, &payload).await
            }
            (result, _) => result,
        };
        let Ok((response, attempt, target)) = selected else {
            return reply(StatusCode::BAD_GATEWAY, "upstream unavailable\n");
        };
        let (mut head, body) = response.into_parts();
        head.version = downstream_version;
        if head.status.is_success()
            && let Some(pointer) = &target.unwrap
        {
            return unwrap_object(head.status, body, pointer, attempt).await;
        }
        let upstream_headers = std::mem::take(&mut head.headers);
        for name in [
            "content-type",
            "content-encoding",
            "content-length",
            "retry-after",
        ] {
            for value in upstream_headers.get_all(name) {
                head.headers.append(name, value.clone());
            }
        }
        let body = attempt.observe(&head.headers, body);
        Ok(Response::from_parts(head, body.boxed_unsync()))
    }

    async fn attempt<'a>(
        &self,
        target: &'a Destination,
        route: &Route,
        incoming: &HeaderMap,
        payload: &Value,
    ) -> Result<(Response<Incoming>, Attempt, &'a Destination), ()> {
        let mut payload = payload.clone();
        if let Some(model) = &target.model {
            payload["model"] = Value::String(model.clone());
        }
        // Forward the parsed object so the upstream sees the same model that
        // the grant checked, including when the input had duplicate keys.
        let bytes = Bytes::from(serde_json::to_vec(&payload).expect("serialize a JSON value"));
        let mut request = Request::new(Full::new(bytes));
        *request.uri_mut() = target.uri.clone();
        *request.method_mut() = Method::POST;
        for name in ["accept", "anthropic-version", "anthropic-beta"] {
            if let Some(value) = incoming.get(name) {
                request.headers_mut().insert(name, value.clone());
            }
        }
        request
            .headers_mut()
            .insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        request
            .headers_mut()
            .insert(target.credential.0.clone(), target.credential.1.clone());

        let mut attempt = self
            .ledger
            .attempt(&route.client, &route.model, &target.pool);
        match timeout(REQUEST_TIMEOUT, self.upstream.request(request)).await {
            Ok(Ok(response)) => {
                attempt.status = Some(response.status().as_u16());
                Ok((response, attempt, target))
            }
            _ => Err(()),
        }
    }

    pub fn control(&self, request: Request<Incoming>) -> Result<Reply, Infallible> {
        match (request.method(), request.uri().path()) {
            (&Method::GET, "/health") => reply(StatusCode::OK, "ok\n"),
            (&Method::GET, "/usage")
                if self
                    .management
                    .as_ref()
                    .is_some_and(|(_, token)| bearer(request.headers(), token)) =>
            {
                let mut response = Response::new(full(self.ledger.json()));
                response
                    .headers_mut()
                    .insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
                Ok(response)
            }
            (&Method::GET, "/usage") => {
                reply(StatusCode::UNAUTHORIZED, "management token required\n")
            }
            _ => reply(StatusCode::NOT_FOUND, "not found\n"),
        }
    }
}

impl Destination {
    fn load(destination: config::Destination, allow_unwrap: bool) -> Result<Self, String> {
        if destination.pool.is_empty() || destination.model.as_ref().is_some_and(String::is_empty) {
            return Err("upstream pool and optional model must be nonempty".into());
        }
        if destination
            .unwrap
            .as_ref()
            .is_some_and(|pointer| !allow_unwrap || !pointer.starts_with('/'))
        {
            return Err("unwrap must be a JSON pointer on a passthrough destination".into());
        }
        let key = secret(&destination.key_file)?;
        let credential = match destination.auth {
            Authentication::ApiKey => (HeaderName::from_static("x-api-key"), key),
            Authentication::Bearer => {
                let mut value = HeaderValue::from_str(&format!(
                    "Bearer {}",
                    key.to_str().expect("ASCII secret")
                ))
                .map_err(|error| error.to_string())?;
                value.set_sensitive(true);
                (AUTHORIZATION, value)
            }
        };
        Ok(Self {
            uri: config::destination_uri(&destination.uri)?,
            credential,
            pool: destination.pool,
            model: destination.model,
            unwrap: destination.unwrap,
        })
    }
}

async fn unwrap_object(
    status: StatusCode,
    body: Incoming,
    pointer: &str,
    attempt: Attempt,
) -> Result<Reply, Infallible> {
    let Ok(Ok(body)) = timeout(
        REQUEST_TIMEOUT,
        Limited::new(body, MAX_REQUEST_BYTES).collect(),
    )
    .await
    else {
        return reply(StatusCode::BAD_GATEWAY, "invalid upstream decision body\n");
    };
    let Ok(json) = serde_json::from_slice::<Value>(&body.to_bytes()) else {
        return reply(StatusCode::BAD_GATEWAY, "invalid upstream decision JSON\n");
    };
    let Some(result) = json.pointer(pointer).filter(|value| value.is_object()) else {
        return reply(
            StatusCode::BAD_GATEWAY,
            "missing upstream decision object\n",
        );
    };
    let bytes = serde_json::to_vec(result).expect("serialize a JSON value");
    attempt.complete_json(&bytes);
    let mut response = Response::new(full(Bytes::from(bytes)));
    *response.status_mut() = status;
    response
        .headers_mut()
        .insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    Ok(response)
}

fn bearer(headers: &HeaderMap, token: &HeaderValue) -> bool {
    headers
        .get(AUTHORIZATION)
        .and_then(|value| value.as_bytes().strip_prefix(b"Bearer "))
        .is_some_and(|given| bool::from(given.ct_eq(token.as_bytes())))
}

fn full(bytes: Bytes) -> UnsyncBoxBody<Bytes, hyper::Error> {
    Full::new(bytes)
        .map_err(|never| match never {})
        .boxed_unsync()
}

pub(crate) fn local(response: Response<Full<Bytes>>) -> Reply {
    response.map(|body| body.map_err(|never| match never {}).boxed_unsync())
}

pub(crate) fn reply(status: StatusCode, message: &'static str) -> Result<Reply, Infallible> {
    Ok(local(replies::response(status, message)))
}

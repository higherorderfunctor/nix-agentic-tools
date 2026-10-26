//! Authenticated loopback control API and protocol v1.

use std::{
    collections::{BTreeMap, BTreeSet},
    num::NonZeroU64,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use crate::report::{self, ResetDimension};
use airlock_core::{
    config::Config,
    ids::{ClientId, CredentialId, ProviderId},
    secret::Secret,
    storage::{
        ControlMetadata, ControlReader, ReadOnlyStorage, RequestOutcome, RequestRowQuery,
        RequestSeriesQuery, SnapshotQuery, SnapshotSource, SnapshotSurface, StorageError,
    },
};
use axum::{
    Json,
    extract::{RawQuery, State, WebSocketUpgrade},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    sync::{Mutex, Notify, mpsc, watch},
    task::JoinSet,
    time::{Instant, sleep_until},
};
use tower_http::{services::ServeDir, set_header::SetResponseHeaderLayer};

const MAX_SESSIONS: usize = 4;
const MAX_SUBSCRIPTIONS: usize = 8;
const MAX_FRAME_BYTES: usize = 1024 * 1024;
const MAX_UNACKED_FRAMES: usize = 16;
const MAX_UNACKED_BYTES: usize = 2 * 1024 * 1024;
const PING_INTERVAL: Duration = Duration::from_secs(15);
const PONG_TIMEOUT: Duration = Duration::from_secs(30);
const SEVEN_DAYS: i64 = 7 * 24 * 60 * 60;
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("control web root must be an existing directory")]
    InvalidWebRoot(PathBuf),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error(transparent)]
    Hyper(#[from] axum::Error),
    #[error(transparent)]
    Task(#[from] tokio::task::JoinError),
}

#[derive(Clone)]
struct ControlState {
    config: Arc<Config>,
    expected_authority: String,
    reader: Arc<Mutex<Option<ControlReader>>>,
    token: Arc<Secret>,
    web_root: PathBuf,
    active_sessions: Arc<Mutex<BTreeSet<String>>>,
    sessions_changed: Arc<Notify>,
    socket_tasks: Arc<std::sync::Mutex<JoinSet<()>>>,
    socket_task_error: Arc<std::sync::Mutex<Option<tokio::task::JoinError>>>,
    session_counter: Arc<AtomicU64>,
    shutdown: watch::Sender<bool>,
    #[cfg(test)]
    test_query_failures: Arc<Mutex<std::collections::VecDeque<&'static str>>>,
}

#[cfg(test)]
impl ControlState {
    async fn next_test_query_failure(&self) -> Option<&'static str> {
        self.test_query_failures.lock().await.pop_front()
    }
}

pub struct ControlServer {
    listener: tokio::net::TcpListener,
    state: ControlState,
}

impl ControlServer {
    pub async fn bind(
        config: Arc<Config>,
        state_dir: &Path,
        web_root: &Path,
        token: Arc<Secret>,
    ) -> Result<Self, Error> {
        let control = config.control().ok_or_else(|| {
            Error::InvalidWebRoot(PathBuf::from("control listener is not configured"))
        })?;
        let canonical_root = web_root
            .canonicalize()
            .map_err(|_| Error::InvalidWebRoot(web_root.to_path_buf()))?;
        if !canonical_root.is_dir() {
            return Err(Error::InvalidWebRoot(canonical_root));
        }
        let reader = ReadOnlyStorage::open(state_dir)
            .await?
            .into_control_reader();
        let listener = tokio::net::TcpListener::bind(control.listen()).await?;
        Ok(Self {
            listener,
            state: ControlState {
                config,
                expected_authority: control.listen().to_string(),
                reader: Arc::new(Mutex::new(Some(reader))),
                token,
                web_root: canonical_root,
                active_sessions: Arc::new(Mutex::new(BTreeSet::new())),
                sessions_changed: Arc::new(Notify::new()),
                socket_tasks: Arc::new(std::sync::Mutex::new(JoinSet::new())),
                socket_task_error: Arc::new(std::sync::Mutex::new(None)),
                session_counter: Arc::new(AtomicU64::new(1)),
                shutdown: watch::channel(false).0,
                #[cfg(test)]
                test_query_failures: Arc::new(Mutex::new(std::collections::VecDeque::new())),
            },
        })
    }

    #[cfg(test)]
    #[must_use]
    pub fn local_addr(&self) -> std::net::SocketAddr {
        self.listener.local_addr().unwrap_or_else(|_| {
            self.state
                .config
                .control()
                .map_or(std::net::SocketAddr::from(([127, 0, 0, 1], 0)), |control| {
                    control.listen()
                })
        })
    }

    pub async fn serve(
        self,
        shutdown: impl std::future::Future<Output = ()> + Send + 'static,
    ) -> Result<(), Error> {
        let state = self.state;
        let socket_shutdown = state.shutdown.clone();
        let shutdown = async move {
            shutdown.await;
            socket_shutdown.send_replace(true);
        };
        let result = axum::serve(self.listener, router(state.clone()))
            .with_graceful_shutdown(shutdown)
            .await;
        state.shutdown.send_replace(true);
        loop {
            let changed = state.sessions_changed.notified();
            if state.active_sessions.lock().await.is_empty() {
                break;
            }
            changed.await;
        }
        let mut tasks = {
            let mut registered = state
                .socket_tasks
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            std::mem::take(&mut *registered)
        };
        let mut task_error = state
            .socket_task_error
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        while let Some(result) = tasks.join_next().await {
            if let Err(error) = result {
                task_error.get_or_insert(error);
            }
        }
        if let Some(reader) = state.reader.lock().await.take() {
            reader.close().await?;
        }
        if let Some(error) = task_error {
            return Err(error.into());
        }
        result?;
        Ok(())
    }
}

fn router(state: ControlState) -> axum::Router {
    let index = state.web_root.join("index.html");
    let assets = state.web_root.join("assets");
    axum::Router::new()
        .route("/api/v1/usage", get(usage))
        .route("/api/v1/live", get(live))
        .route(
            "/",
            get(move || async move { static_file(index.clone()).await }),
        )
        .nest_service("/assets", ServeDir::new(assets))
        .fallback(missing)
        .layer(SetResponseHeaderLayer::overriding(
            header::CACHE_CONTROL,
            HeaderValue::from_static("no-store"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::CONTENT_SECURITY_POLICY,
            HeaderValue::from_static(
                "default-src 'none'; img-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            ),
        ))
        .with_state(state)
}

async fn missing() -> Response {
    ApiError::not_found().into_response()
}

async fn static_file(path: PathBuf) -> Response {
    match tokio::fs::read(&path).await {
        Ok(bytes) => {
            let mut response = bytes.into_response();
            response.headers_mut().insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("text/html; charset=utf-8"),
            );
            response
        }
        Err(_) => ApiError::not_found().into_response(),
    }
}

#[derive(Debug)]
struct ApiError {
    code: &'static str,
    retryable: bool,
    status: StatusCode,
}

impl ApiError {
    const fn new(code: &'static str, status: StatusCode, retryable: bool) -> Self {
        Self {
            code,
            retryable,
            status,
        }
    }
    const fn not_found() -> Self {
        Self::new("not_found", StatusCode::NOT_FOUND, false)
    }
    const fn unauthorized() -> Self {
        Self::new("unauthorized", StatusCode::UNAUTHORIZED, false)
    }
    const fn forbidden_host() -> Self {
        Self::new("forbidden_host", StatusCode::FORBIDDEN, false)
    }
    const fn forbidden_origin() -> Self {
        Self::new("forbidden_origin", StatusCode::FORBIDDEN, false)
    }
    const fn invalid_query() -> Self {
        Self::new("invalid_query", StatusCode::BAD_REQUEST, false)
    }
    const fn numeric_range_unsupported() -> Self {
        Self::new("numeric_range_unsupported", StatusCode::BAD_REQUEST, false)
    }

    fn storage(code: &'static str) -> Self {
        match code {
            "query_budget_exceeded" => {
                Self::new("storage_unavailable", StatusCode::SERVICE_UNAVAILABLE, true)
            }
            "storage_busy" | "storage_unavailable" => {
                Self::new(code, StatusCode::SERVICE_UNAVAILABLE, true)
            }
            "storage_corrupt" => Self::new(code, StatusCode::SERVICE_UNAVAILABLE, false),
            "range_too_large" => Self::new(code, StatusCode::UNPROCESSABLE_ENTITY, false),
            value => Self::new(value, StatusCode::SERVICE_UNAVAILABLE, false),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = json!({
            "api_version": 1,
            "error": {"code": self.code, "retryable": self.retryable}
        });
        (self.status, Json(body)).into_response()
    }
}

fn bearer_token(headers: &HeaderMap) -> Option<&[u8]> {
    headers
        .get(header::AUTHORIZATION)?
        .as_bytes()
        .strip_prefix(b"Bearer ")
}

fn authorized(state: &ControlState, headers: &HeaderMap) -> bool {
    bearer_token(headers).is_some_and(|candidate| state.token.matches(candidate))
}

async fn usage(
    State(state): State<ControlState>,
    RawQuery(query): RawQuery,
    headers: HeaderMap,
) -> Response {
    if !authorized(&state, &headers) {
        return ApiError::unauthorized().into_response();
    }
    let mut values = BTreeMap::new();
    if let Some(query) = query.as_deref().filter(|query| !query.is_empty()) {
        for pair in query.split('&') {
            let Some((key, value)) = pair.split_once('=') else {
                return ApiError::invalid_query().into_response();
            };
            if !matches!(key, "since_unix" | "bucket_seconds" | "history_limit")
                || values.insert(key, value).is_some()
            {
                return ApiError::invalid_query().into_response();
            }
        }
    }
    let parse = |key: &str, default: Option<i64>| -> Result<i64, ApiError> {
        values.get(key).map_or_else(
            || default.ok_or_else(ApiError::invalid_query),
            |value| {
                let wide = value
                    .parse::<i128>()
                    .map_err(|_| ApiError::invalid_query())?;
                if wide.unsigned_abs() > 9_007_199_254_740_991 {
                    return Err(ApiError::numeric_range_unsupported());
                }
                i64::try_from(wide).map_err(|_| ApiError::numeric_range_unsupported())
            },
        )
    };
    let now = now_unix();
    let parsed = (|| -> Result<report::Options, ApiError> {
        let bucket_seconds = u64::try_from(parse("bucket_seconds", Some(3600))?)
            .map_err(|_| ApiError::invalid_query())?;
        let history_limit = u64::try_from(parse("history_limit", Some(100))?)
            .map_err(|_| ApiError::invalid_query())?;
        Ok(report::Options {
            bucket_seconds: NonZeroU64::new(bucket_seconds).ok_or_else(ApiError::invalid_query)?,
            history_limit,
            since_unix: parse("since_unix", Some(now.saturating_sub(SEVEN_DAYS).max(1)))?,
        })
    })();
    let options = match parsed {
        Ok(options) if options.validate(now).is_ok() => options,
        Ok(_) => return ApiError::invalid_query().into_response(),
        Err(error) => return error.into_response(),
    };
    let mut guard = state.reader.lock().await;
    let Some(reader) = guard.as_mut() else {
        return ApiError::storage("storage_unavailable").into_response();
    };
    match report::build_control(&state.config, reader, &options, now).await {
        Ok(value) if safe_json_numbers(&value) => Json(value).into_response(),
        Ok(_) => ApiError::numeric_range_unsupported().into_response(),
        Err(error) => ApiError::storage(storage_code(&error)).into_response(),
    }
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| i64::try_from(value.as_secs()).unwrap_or(i64::MAX))
        .unwrap_or_default()
}

fn same_origin(state: &ControlState, headers: &HeaderMap) -> bool {
    let Some(origin) = headers
        .get(header::ORIGIN)
        .and_then(|value| value.to_str().ok())
    else {
        return false;
    };
    let Some(rest) = origin.strip_prefix("http://") else {
        return false;
    };
    rest == state.expected_authority
}

async fn live(
    State(state): State<ControlState>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    let host_ok = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|host| host == state.expected_authority);
    if !host_ok {
        return ApiError::forbidden_host().into_response();
    }
    if !same_origin(&state, &headers) {
        return ApiError::forbidden_origin().into_response();
    }
    if !headers
        .get(header::SEC_WEBSOCKET_PROTOCOL)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.split(',').any(|value| value.trim() == "airlock.v1"))
    {
        return ApiError::new("unsupported_version", StatusCode::CONFLICT, false).into_response();
    }
    let mut sessions = state.active_sessions.lock().await;
    if sessions.len() >= MAX_SESSIONS {
        return ApiError::new("resource_limit", StatusCode::TOO_MANY_REQUESTS, true)
            .into_response();
    }
    let session = opaque_id(&state, "s");
    sessions.insert(session.clone());
    drop(sessions);
    let failed_state = state.clone();
    let failed_session = session.clone();
    upgrade
        .protocols(["airlock.v1"])
        .max_frame_size(MAX_FRAME_BYTES)
        .max_message_size(MAX_FRAME_BYTES)
        .on_failed_upgrade(move |_| {
            spawn_socket_task(&failed_state.clone(), async move {
                failed_state
                    .active_sessions
                    .lock()
                    .await
                    .remove(&failed_session);
                failed_state.sessions_changed.notify_one();
            });
        })
        .on_upgrade(move |socket| async move {
            spawn_socket_task(&state.clone(), run_socket(state, session, socket));
        })
}

fn spawn_socket_task(
    state: &ControlState,
    task: impl std::future::Future<Output = ()> + Send + 'static,
) {
    let mut tasks = state
        .socket_tasks
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    while let Some(result) = tasks.try_join_next() {
        if let Err(error) = result {
            state
                .socket_task_error
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .get_or_insert(error);
        }
    }
    tasks.spawn(task);
}

fn opaque_id(state: &ControlState, prefix: &str) -> String {
    let count = state.session_counter.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or_default();
    format!("{prefix}-{count:08x}-{nanos:x}")
}

async fn wait_for_shutdown(receiver: &mut watch::Receiver<bool>) {
    let _ = receiver.wait_for(|stopped| *stopped).await;
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(untagged, deny_unknown_fields)]
enum Window {
    Fixed { since_unix: i64, until_unix: i64 },
    Rolling { last_seconds: i64 },
}

#[expect(
    clippy::option_option,
    reason = "explicit null selects unknown clients while omission selects all clients"
)]
fn present_nullable<'de, D>(deserializer: D) -> Result<Option<Option<String>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer).map(Some)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct UsageSeriesQuery {
    credential: String,
    limit: u64,
    provider: String,
    source: SnapshotSourceWire,
    surface: SnapshotSurfaceWire,
    window: Window,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[expect(
    clippy::option_option,
    reason = "wire filters distinguish omitted from explicit client null"
)]
#[serde(deny_unknown_fields)]
struct RequestsTableQuery {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    before: Option<String>,
    #[serde(
        default,
        deserialize_with = "present_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    client: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    credential: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    group: Option<String>,
    limit: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    outcome: Option<RequestOutcomeWire>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    provider: Option<String>,
    window: Window,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[expect(
    clippy::option_option,
    reason = "wire filters distinguish omitted from explicit client null"
)]
#[serde(deny_unknown_fields)]
struct RequestsSeriesQuery {
    bucket_seconds: u64,
    #[serde(
        default,
        deserialize_with = "present_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    client: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    credential: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    group: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    outcome: Option<RequestOutcomeWire>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    provider: Option<String>,
    window: Window,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct OverviewQuery {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    credential: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    provider: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct LogsTailQuery {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    after: Option<String>,
    limit: u64,
    stream: LogsStreamWire,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) enum SubscriptionKind {
    #[serde(rename = "logs.tail")]
    LogsTail,
    #[serde(rename = "requests.series")]
    RequestsSeries,
    #[serde(rename = "requests.table")]
    RequestsTable,
    #[serde(rename = "usage.overview")]
    UsageOverview,
    #[serde(rename = "usage.series")]
    UsageSeries,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(untagged)]
enum QueryBody {
    LogsTail(LogsTailQuery),
    RequestsSeries(RequestsSeriesQuery),
    RequestsTable(RequestsTableQuery),
    UsageOverview(OverviewQuery),
    UsageSeries(UsageSeriesQuery),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind")]
enum SubscriptionQuery {
    #[serde(rename = "logs.tail")]
    LogsTail { query: LogsTailQuery },
    #[serde(rename = "requests.series")]
    RequestsSeries { query: RequestsSeriesQuery },
    #[serde(rename = "requests.table")]
    RequestsTable { query: RequestsTableQuery },
    #[serde(rename = "usage.overview")]
    UsageOverview { query: OverviewQuery },
    #[serde(rename = "usage.series")]
    UsageSeries { query: UsageSeriesQuery },
}

impl SubscriptionQuery {
    fn new(kind: SubscriptionKind, body: QueryBody) -> Option<Self> {
        match (kind, body) {
            (SubscriptionKind::LogsTail, QueryBody::LogsTail(query)) => {
                Some(Self::LogsTail { query })
            }
            (SubscriptionKind::RequestsSeries, QueryBody::RequestsSeries(query)) => {
                Some(Self::RequestsSeries { query })
            }
            (SubscriptionKind::RequestsTable, QueryBody::RequestsTable(query)) => {
                Some(Self::RequestsTable { query })
            }
            (SubscriptionKind::UsageOverview, QueryBody::UsageOverview(query)) => {
                Some(Self::UsageOverview { query })
            }
            (SubscriptionKind::UsageSeries, QueryBody::UsageSeries(query)) => {
                Some(Self::UsageSeries { query })
            }
            _ => None,
        }
    }

    fn kind(&self) -> SubscriptionKind {
        match self {
            Self::LogsTail { .. } => SubscriptionKind::LogsTail,
            Self::RequestsSeries { .. } => SubscriptionKind::RequestsSeries,
            Self::RequestsTable { .. } => SubscriptionKind::RequestsTable,
            Self::UsageOverview { .. } => SubscriptionKind::UsageOverview,
            Self::UsageSeries { .. } => SubscriptionKind::UsageSeries,
        }
    }
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum LogsStreamWire {
    Audit,
    Requests,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
enum RequestOutcomeWire {
    #[serde(rename = "cancelled")]
    Cancelled,
    #[serde(rename = "completed")]
    Completed,
    #[serde(rename = "failed")]
    Failed,
    #[serde(rename = "rejected")]
    Rejected,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
enum SnapshotSourceWire {
    #[serde(rename = "out_of_band_fetch")]
    OutOfBandFetch,
    #[serde(rename = "response_headers")]
    ResponseHeaders,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
enum SnapshotSurfaceWire {
    #[serde(rename = "claude_subscription")]
    ClaudeSubscription,
    #[serde(rename = "codex_rate_limits")]
    CodexRateLimits,
    #[serde(rename = "console_balance")]
    ConsoleBalance,
    #[serde(rename = "response_headers")]
    ResponseHeaders,
    #[serde(rename = "zai_quota")]
    ZaiQuota,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
enum ClientFrame {
    Ack {
        v: u8,
        id: String,
        epoch: String,
        seq: u64,
    },
    Auth {
        v: u8,
        token: String,
    },
    Pong {
        v: u8,
        nonce: String,
    },
    Subscribe {
        v: u8,
        id: String,
        kind: SubscriptionKind,
        query: QueryBody,
    },
    Unsubscribe {
        v: u8,
        id: String,
    },
}

fn error_frame(id: Option<&str>, code: &str, retryable: bool) -> Value {
    json!({"v":1, "type":"error", "id":id, "code":code, "retryable":retryable})
}

fn gap_frame(id: &str, epoch: &str, after_seq: u64, code: &str, retryable: bool) -> Value {
    json!({"v":1,"type":"gap","id":id,"epoch":epoch,"after_seq":after_seq,"code":code,
        "retryable":retryable,"action":if retryable {"retry"} else {"resnapshot"}})
}

#[derive(Debug)]
enum Outbound {
    Close(Option<u16>),
    Text(Value),
}

fn close_message(code: Option<u16>) -> axum::extract::ws::Message {
    code.map_or(axum::extract::ws::Message::Close(None), |code| {
        axum::extract::ws::Message::Close(Some(axum::extract::ws::CloseFrame {
            code,
            reason: String::new().into(),
        }))
    })
}

#[derive(Debug, Default)]
struct FlowState {
    delivered: BTreeMap<(String, String), u64>,
    unacked: BTreeMap<(String, String), BTreeMap<u64, usize>>,
    total_bytes: usize,
}

#[derive(Debug, Default)]
struct Flow {
    state: Mutex<FlowState>,
    notify: Notify,
}

impl Flow {
    async fn acquire(&self, id: &str, epoch: &str, seq: u64, bytes: usize) -> Result<(), Value> {
        let started = Instant::now();
        loop {
            let notified = self.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let mut state = self.state.lock().await;
                let capacity = state.total_bytes + bytes;
                let key = (id.to_owned(), epoch.to_owned());
                let highest = state.delivered.get(&key).copied().unwrap_or(0);
                let outstanding: usize = state.unacked.values().map(BTreeMap::len).sum();
                if highest.checked_add(1) == Some(seq)
                    && outstanding < MAX_UNACKED_FRAMES
                    && capacity <= MAX_UNACKED_BYTES
                {
                    state
                        .unacked
                        .entry(key.clone())
                        .or_default()
                        .insert(seq, bytes);
                    state.delivered.insert(key, seq);
                    state.total_bytes += bytes;
                    return Ok(());
                }
            }
            tokio::select! {
                () = &mut notified => {}
                () = tokio::time::sleep_until(started + Duration::from_secs(10)) => {}
            }
            if started.elapsed() >= Duration::from_secs(10) {
                return Err(gap_frame(
                    id,
                    epoch,
                    seq.saturating_sub(1),
                    "slow_consumer",
                    false,
                ));
            }
        }
    }

    async fn ack(&self, id: &str, epoch: &str, seq: u64) -> Result<(), ()> {
        let mut state = self.state.lock().await;
        let key = (id.to_owned(), epoch.to_owned());
        let Some(highest) = state.delivered.get(&key).copied() else {
            return Err(());
        };
        if seq == 0 || seq > highest {
            return Err(());
        }
        let mut bytes = 0;
        if let Some(entry) = state.unacked.get_mut(&key) {
            entry.retain(|ack_seq, size| {
                if *ack_seq <= seq {
                    bytes += *size;
                    false
                } else {
                    true
                }
            });
            if entry.is_empty() {
                state.unacked.remove(&key);
            }
        }
        state.total_bytes = state.total_bytes.saturating_sub(bytes);
        drop(state);
        if bytes > 0 {
            self.notify.notify_waiters();
        }
        Ok(())
    }

    async fn discard(&self, id: &str) {
        let mut state = self.state.lock().await;
        let keys: Vec<(String, String)> = state
            .delivered
            .keys()
            .filter(|(subscription_id, _)| subscription_id == id)
            .cloned()
            .collect();
        for key in keys {
            if let Some(entry) = state.unacked.remove(&key) {
                let bytes: usize = entry.values().sum();
                state.total_bytes = state.total_bytes.saturating_sub(bytes);
            }
            state.delivered.remove(&key);
        }
        drop(state);
        self.notify.notify_waiters();
    }
}

async fn send_text(
    sender: &mpsc::Sender<Outbound>,
    frame: Value,
) -> Result<(), mpsc::error::SendError<Outbound>> {
    sender.send(Outbound::Text(frame)).await
}

fn close_subscription(sender: &mpsc::Sender<Outbound>, error: Value, close: &Notify) {
    let slow = error.get("code").and_then(Value::as_str) == Some("slow_consumer");
    let _ = sender.try_send(Outbound::Text(error)).is_ok();
    if slow {
        let _ = sender.try_send(Outbound::Close(Some(1013))).is_ok();
        close.notify_waiters();
    }
}

struct Connection {
    state: ControlState,
    sender: mpsc::Sender<Outbound>,
    flow: Arc<Flow>,
    close: Arc<Notify>,
    subscriptions: BTreeMap<String, tokio::task::JoinHandle<()>>,
    expected_ping: Option<String>,
}

async fn run_socket(state: ControlState, session: String, socket: axum::extract::ws::WebSocket) {
    run_socket_inner(state.clone(), socket).await;
    state.active_sessions.lock().await.remove(&session);
    state.sessions_changed.notify_one();
}

#[expect(
    clippy::too_many_lines,
    reason = "socket authentication, writer, and cleanup share one connection lifecycle"
)]
async fn run_socket_inner(state: ControlState, socket: axum::extract::ws::WebSocket) {
    let (mut sink, mut stream) = socket.split();
    let mut daemon_shutdown = state.shutdown.subscribe();
    let first = tokio::select! {
        biased;
        () = wait_for_shutdown(&mut daemon_shutdown) => return,
        first = tokio::time::timeout(Duration::from_secs(5), stream.next()) => first,
    };
    let Ok(Some(Ok(message))) = first else {
        let _ = sink.send(axum::extract::ws::Message::Close(None)).await;
        return;
    };
    let auth = decode_client_frame(message).and_then(|frame| match frame {
        ClientFrame::Auth { v: 1, token } => Ok(token),
        _ => Err("unauthorized"),
    });
    let token = match auth.and_then(|value| {
        if state.token.matches(value.as_bytes()) {
            Ok(value)
        } else {
            Err("unauthorized")
        }
    }) {
        Ok(value) => value,
        Err(code) => {
            if *daemon_shutdown.borrow() {
                return;
            }
            let _ = sink
                .send(axum::extract::ws::Message::Text(
                    error_frame(None, code, false).to_string().into(),
                ))
                .await;
            let _ = sink.send(axum::extract::ws::Message::Close(None)).await;
            return;
        }
    };
    drop(token);

    if *daemon_shutdown.borrow() {
        return;
    }

    let (sender, mut receiver) = mpsc::channel(MAX_UNACKED_FRAMES + MAX_SUBSCRIPTIONS);
    let flow = Arc::new(Flow::default());
    let socket_close = Arc::new(Notify::new());
    let hello = json!({
        "v":1,"type":"hello","server_time_unix":now_unix(),
        "capabilities":["requests.series","requests.table","usage.overview","usage.series"],
        "limits":{"max_subscriptions":MAX_SUBSCRIPTIONS,"max_frame_bytes":MAX_FRAME_BYTES,
            "max_unacked_frames":MAX_UNACKED_FRAMES}
    });
    if sender.send(Outbound::Text(hello)).await.is_err() {
        return;
    }
    let mut connection = Connection {
        state: state.clone(),
        sender: sender.clone(),
        flow: Arc::clone(&flow),
        close: Arc::clone(&socket_close),
        subscriptions: BTreeMap::new(),
        expected_ping: None,
    };
    let mut writer_shutdown = state.shutdown.subscribe();
    let mut writer = tokio::spawn(async move {
        loop {
            let outbound = tokio::select! {
                biased;
                () = wait_for_shutdown(&mut writer_shutdown) => break,
                outbound = receiver.recv() => outbound,
            };
            let Some(outbound) = outbound else { break };
            let mut is_close = matches!(outbound, Outbound::Close(_));
            let message = match outbound {
                Outbound::Close(code) => close_message(code),
                Outbound::Text(frame) => {
                    let encoded = frame.to_string();
                    if encoded.len() > MAX_FRAME_BYTES {
                        is_close = true;
                        axum::extract::ws::Message::Text(
                            error_frame(None, "resource_limit", false)
                                .to_string()
                                .into(),
                        )
                    } else {
                        axum::extract::ws::Message::Text(encoded.into())
                    }
                }
            };
            let write = tokio::select! {
                biased;
                () = wait_for_shutdown(&mut writer_shutdown) => break,
                write = tokio::time::timeout(WRITE_TIMEOUT, sink.send(message)) => write,
            };
            if write.is_err() || matches!(write, Ok(Err(_))) {
                break;
            }
            if is_close {
                break;
            }
        }
        let _ = sink.close().await;
    });

    let close = Arc::clone(&socket_close);
    let mut next_ping = Instant::now() + PING_INTERVAL;
    let mut ping_deadline = next_ping + PONG_TIMEOUT;
    loop {
        tokio::select! {
            biased;
            () = wait_for_shutdown(&mut daemon_shutdown) => break,
            message = stream.next() => {
                let Some(Ok(message)) = message else { break };
                if connection.handle_message(message).await.is_err() {
                    break;
                }
            }
            () = close.notified() => break,
            () = sleep_until(next_ping) => {
                if connection.expected_ping.is_none() {
                    let nonce = opaque_id(&state, "p");
                    connection.expected_ping = Some(nonce.clone());
                    ping_deadline = Instant::now() + PONG_TIMEOUT;
                    if sender.send(Outbound::Text(json!({
                        "v":1,"type":"ping","nonce":nonce,"server_time_unix":now_unix()
                    }))).await.is_err() {
                        break;
                    }
                }
                next_ping += PING_INTERVAL;
            }
            () = sleep_until(ping_deadline) => {
                if connection.expected_ping.is_some() {
                    break;
                }
                ping_deadline = next_ping + PONG_TIMEOUT;
            }
        }
    }

    for task in connection.subscriptions.values() {
        task.abort();
    }
    for task in connection.subscriptions.into_values() {
        let _ = task.await;
    }
    drop(sender);
    drop(connection.sender);
    if tokio::time::timeout(WRITE_TIMEOUT, &mut writer)
        .await
        .is_err()
    {
        writer.abort();
        let _ = writer.await;
    }
}

impl Connection {
    async fn handle_message(&mut self, message: axum::extract::ws::Message) -> Result<(), ()> {
        let decoded = match decode_client_frame(message) {
            Ok(frame) => frame,
            Err(code) => {
                let _ = send_text(&self.sender, error_frame(None, code, false)).await;
                return Err(());
            }
        };
        match decoded {
            ClientFrame::Auth { .. } => {
                let _ = send_text(&self.sender, error_frame(None, "invalid_frame", false)).await;
                Err(())
            }
            ClientFrame::Pong { nonce, .. } => {
                if self.expected_ping.as_deref() != Some(nonce.as_str()) {
                    let _ =
                        send_text(&self.sender, error_frame(None, "invalid_frame", false)).await;
                    return Err(());
                }
                self.expected_ping = None;
                Ok(())
            }
            ClientFrame::Ack { id, epoch, seq, .. } => {
                if self.flow.ack(&id, &epoch, seq).await.is_err() {
                    let _ = send_text(&self.sender, error_frame(Some(&id), "invalid_frame", false))
                        .await;
                    return Err(());
                }
                Ok(())
            }
            ClientFrame::Unsubscribe { id, .. } => {
                if let Some(task) = self.subscriptions.remove(&id) {
                    task.abort();
                    let _ = task.await;
                }
                self.flow.discard(&id).await;
                let _ = send_text(&self.sender, json!({"v":1,"type":"unsubscribed","id":id})).await;
                Ok(())
            }
            ClientFrame::Subscribe {
                id, kind, query, ..
            } => {
                if let Some(query) = SubscriptionQuery::new(kind, query) {
                    self.subscribe(id, query).await
                } else {
                    let _ = send_text(&self.sender, error_frame(Some(&id), "invalid_query", false))
                        .await;
                    Ok(())
                }
            }
        }
    }

    async fn subscribe(&mut self, id: String, query: SubscriptionQuery) -> Result<(), ()> {
        if self.subscriptions.contains_key(&id) {
            let _ = send_text(
                &self.sender,
                error_frame(Some(&id), "subscription_conflict", false),
            )
            .await;
            return Ok(());
        }
        if self.subscriptions.len() >= MAX_SUBSCRIPTIONS {
            let _ = send_text(&self.sender, error_frame(Some(&id), "resource_limit", true)).await;
            return Ok(());
        }
        if let SubscriptionQuery::LogsTail { .. } = query {
            let _ = send_text(
                &self.sender,
                error_frame(Some(&id), "unsupported_subscription", false),
            )
            .await;
            return Ok(());
        }
        if let Err(error) = validate_query(&query) {
            let _ = send_text(&self.sender, error_frame(Some(&id), error, false)).await;
            return Ok(());
        }
        let interval = match query {
            SubscriptionQuery::RequestsTable { .. } => 1_000,
            _ => 5_000,
        };
        let epoch = format!("e-{}", opaque_id(&self.state, id.as_str()));
        let _ = send_text(
            &self.sender,
            json!({
                "v":1,"type":"subscribed","id":id,"epoch":epoch,
                "interval_ms":interval
            }),
        )
        .await;
        let task = tokio::spawn(run_subscription(
            self.state.clone(),
            Arc::clone(&self.flow),
            self.sender.clone(),
            id.clone(),
            query,
            epoch,
            Arc::clone(&self.close),
            self.state.shutdown.subscribe(),
        ));
        self.subscriptions.insert(id, task);
        Ok(())
    }
}

fn decode_client_frame(message: axum::extract::ws::Message) -> Result<ClientFrame, &'static str> {
    let text = match message {
        axum::extract::ws::Message::Text(text) => text.as_str().to_owned(),
        _ => return Err("invalid_frame"),
    };
    if text.len() > MAX_FRAME_BYTES {
        return Err("invalid_frame");
    }
    let frame = serde_json::from_str::<ClientFrame>(&text).map_err(|_| "invalid_frame")?;
    let version = match &frame {
        ClientFrame::Ack { v, .. }
        | ClientFrame::Auth { v, .. }
        | ClientFrame::Pong { v, .. }
        | ClientFrame::Subscribe { v, .. }
        | ClientFrame::Unsubscribe { v, .. } => *v,
    };
    if version != 1 {
        return Err("unsupported_version");
    }
    let fields_valid = match &frame {
        ClientFrame::Ack { id, epoch, .. } => valid_subscription_id(id) && valid_wire_handle(epoch),
        ClientFrame::Auth { .. } => true,
        ClientFrame::Pong { nonce, .. } => valid_wire_handle(nonce),
        ClientFrame::Subscribe { id, .. } | ClientFrame::Unsubscribe { id, .. } => {
            valid_subscription_id(id)
        }
    };
    if fields_valid {
        Ok(frame)
    } else {
        Err("invalid_frame")
    }
}

fn valid_subscription_id(value: &str) -> bool {
    (1..=64).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

fn valid_wire_handle(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

fn validate_query(query: &SubscriptionQuery) -> Result<(), &'static str> {
    let window = |window: &Window| -> Result<(i64, i64), &'static str> {
        let (since, until) = match window {
            Window::Fixed {
                since_unix,
                until_unix,
            } => (*since_unix, *until_unix),
            Window::Rolling { last_seconds } => {
                if *last_seconds <= 0 {
                    return Err("invalid_query");
                }
                (0, *last_seconds)
            }
        };
        if matches!(window, &Window::Fixed { .. }) && (since <= 0 || until <= 0) {
            return Err("invalid_query");
        }
        if until <= since
            || until
                .checked_sub(since)
                .is_none_or(|range| range > SEVEN_DAYS)
        {
            return Err("range_too_large");
        }
        Ok((since, until))
    };
    match query {
        SubscriptionQuery::LogsTail { .. } => Err("unsupported_subscription"),
        SubscriptionQuery::RequestsSeries { query } => {
            window(&query.window)?;
            if !matches!(query.bucket_seconds, 60 | 300 | 3600) {
                return Err("invalid_query");
            }
            Ok(())
        }
        SubscriptionQuery::RequestsTable { query } => {
            window(&query.window)?;
            if query.limit == 0 || query.limit > 200 {
                return Err("invalid_query");
            }
            if let Some(before) = &query.before
                && parse_cursor(before, query).is_none()
            {
                return Err("invalid_query");
            }
            Ok(())
        }
        SubscriptionQuery::UsageOverview { .. } => Ok(()),
        SubscriptionQuery::UsageSeries { query } => {
            window(&query.window)?;
            if query.limit == 0 || query.limit > 1000 {
                return Err("invalid_query");
            }
            Ok(())
        }
    }
}

#[expect(
    clippy::option_option,
    reason = "cursor filters distinguish omitted from explicit client null"
)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct RequestCursor {
    #[serde(
        default,
        deserialize_with = "present_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    client: Option<Option<String>>,
    credential: Option<String>,
    cutoff_id: i64,
    group: Option<String>,
    model: Option<String>,
    occurred_at_unix: i64,
    outcome: Option<RequestOutcomeWire>,
    provider: Option<String>,
    row_id: i64,
    since_unix: i64,
    until_unix: i64,
    window: Window,
}

impl RequestCursor {
    fn first(
        query: &RequestsTableQuery,
        cursor: airlock_core::storage::RequestRowCursor,
        since_unix: i64,
        until_unix: i64,
    ) -> Self {
        Self {
            client: query.client.clone(),
            credential: query.credential.clone(),
            cutoff_id: cursor.cutoff_id,
            group: query.group.clone(),
            model: query.model.clone(),
            occurred_at_unix: cursor.occurred_at_unix,
            outcome: query.outcome,
            provider: query.provider.clone(),
            row_id: cursor.row_id,
            since_unix,
            until_unix,
            window: query.window.clone(),
        }
    }

    fn matches(&self, query: &RequestsTableQuery) -> bool {
        self.client == query.client
            && self.credential == query.credential
            && self.group == query.group
            && self.model == query.model
            && self.outcome == query.outcome
            && self.provider == query.provider
            && self.window == query.window
    }

    fn valid(&self) -> bool {
        self.cutoff_id > 0
            && self.row_id > 0
            && self.row_id <= self.cutoff_id
            && self.since_unix < self.until_unix
            && self
                .until_unix
                .checked_sub(self.since_unix)
                .is_some_and(|range| range <= SEVEN_DAYS)
            && self.occurred_at_unix >= self.since_unix
            && self.occurred_at_unix < self.until_unix
    }
}

fn parse_cursor(value: &str, query: &RequestsTableQuery) -> Option<RequestCursor> {
    if value.len() > 1024 {
        return None;
    }
    let bytes = URL_SAFE_NO_PAD.decode(value).ok()?;
    let cursor = serde_json::from_slice::<RequestCursor>(&bytes).ok()?;
    cursor
        .matches(query)
        .then_some(cursor)
        .filter(RequestCursor::valid)
}

fn cursor_string(cursor: &RequestCursor) -> Option<String> {
    let bytes = serde_json::to_vec(cursor).ok()?;
    Some(URL_SAFE_NO_PAD.encode(bytes))
}

fn resolve_window(window: &Window, now: i64) -> (i64, i64) {
    match window {
        Window::Fixed {
            since_unix,
            until_unix,
        } => (*since_unix, *until_unix),
        Window::Rolling { last_seconds } => (now.saturating_sub(*last_seconds), now),
    }
}

fn parse_id<'a, T>(value: Option<&'a str>) -> Result<Option<T>, &'static str>
where
    T: TryFrom<&'a str>,
{
    match value {
        None => Ok(None),
        Some(value) => T::try_from(value).map(Some).map_err(|_| "invalid_query"),
    }
}

#[expect(
    clippy::option_option,
    reason = "wire filters distinguish omitted from explicit client null"
)]
fn parse_client_filter(
    value: Option<&Option<String>>,
) -> Result<Option<Option<ClientId>>, &'static str> {
    match value {
        None => Ok(None),
        Some(None) => Ok(Some(None)),
        Some(Some(value)) => ClientId::try_from(value.as_str())
            .map(|client| Some(Some(client)))
            .map_err(|_| "invalid_query"),
    }
}

fn outcome_string(outcome: RequestOutcome) -> &'static str {
    match outcome {
        RequestOutcome::Cancelled => "cancelled",
        RequestOutcome::Completed => "completed",
        RequestOutcome::Failed => "failed",
        RequestOutcome::Rejected => "rejected",
    }
}

impl From<RequestOutcomeWire> for RequestOutcome {
    fn from(value: RequestOutcomeWire) -> Self {
        match value {
            RequestOutcomeWire::Cancelled => Self::Cancelled,
            RequestOutcomeWire::Completed => Self::Completed,
            RequestOutcomeWire::Failed => Self::Failed,
            RequestOutcomeWire::Rejected => Self::Rejected,
        }
    }
}

impl SnapshotSourceWire {
    const fn into_reader(self) -> SnapshotSource {
        match self {
            Self::OutOfBandFetch => airlock_core::storage::SnapshotSource::OutOfBandFetch,
            Self::ResponseHeaders => SnapshotSource::ResponseHeaders,
        }
    }
}

impl SnapshotSurfaceWire {
    const fn into_reader(self) -> SnapshotSurface {
        match self {
            Self::ClaudeSubscription => airlock_core::storage::SnapshotSurface::ClaudeSubscription,
            Self::CodexRateLimits => SnapshotSurface::CodexRateLimits,
            Self::ConsoleBalance => SnapshotSurface::ConsoleBalance,
            Self::ResponseHeaders => SnapshotSurface::ResponseHeaders,
            Self::ZaiQuota => SnapshotSurface::ZaiQuota,
        }
    }
}

#[allow(clippy::too_many_arguments)]
#[expect(
    clippy::too_many_lines,
    reason = "live evaluation and shutdown cancellation form one subscription loop"
)]
async fn run_subscription(
    state: ControlState,
    flow: Arc<Flow>,
    sender: mpsc::Sender<Outbound>,
    id: String,
    query: SubscriptionQuery,
    initial_epoch: String,
    close: Arc<Notify>,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut epoch = initial_epoch;
    let mut seq = 0;
    let mut previous: Option<ViewState> = None;
    let mut invalidated = None;
    loop {
        if *shutdown.borrow() {
            break;
        }
        let now = now_unix();
        let evaluate_future = async {
            #[cfg(test)]
            let injected = state.next_test_query_failure().await;
            #[cfg(not(test))]
            let injected: Option<&'static str> = None;
            if let Some(code) = injected {
                Err(code)
            } else {
                let mut guard = state.reader.lock().await;
                match guard.as_mut() {
                    Some(reader) => evaluate(&state.config, reader, &query, now).await,
                    None => Err("storage_unavailable"),
                }
            }
        };
        let result = tokio::select! {
            biased;
            () = wait_for_shutdown(&mut shutdown) => break,
            result = evaluate_future => result,
        };
        match result {
            Ok(view) => {
                if let Some(code) = invalidated.take() {
                    let mut transition = gap_frame(&id, &epoch, seq, code, true);
                    transition["action"] = json!("resnapshot");
                    if send_text(&sender, transition).await.is_err() {
                        break;
                    }
                    flow.discard(&id).await;
                    epoch = format!("e-{}", opaque_id(&state, id.as_str()));
                    seq = 0;
                    previous = None;
                }
                if previous.is_none() {
                    seq += 1;
                    let frame = data_frame("snapshot", &id, &epoch, seq, None, &view, None);
                    if let Err(error) = send_data(&flow, &sender, &id, &epoch, seq, frame).await {
                        if error["type"] == "error" {
                            flow.discard(&id).await;
                        }
                        close_subscription(&sender, error, &close);
                        break;
                    }
                    if let SubscriptionQuery::RequestsTable { query: table } = &query
                        && table.before.is_some()
                    {
                        break;
                    }
                } else if let Some(old) = previous.as_ref()
                    && (old.meta != view.meta || old.collections != view.collections)
                {
                    let (upserts, removes) = old.diff(&view);
                    seq += 1;
                    let frame = data_frame(
                        "delta",
                        &id,
                        &epoch,
                        seq,
                        Some(seq - 1),
                        &view,
                        Some((&upserts, &removes)),
                    );
                    if let Err(error) = send_data(&flow, &sender, &id, &epoch, seq, frame).await {
                        if error["type"] == "error" {
                            flow.discard(&id).await;
                        }
                        close_subscription(&sender, error, &close);
                        break;
                    }
                }
                previous = Some(view);
            }
            Err(code) => {
                let retryable = matches!(
                    code,
                    "storage_busy" | "storage_unavailable" | "query_budget_exceeded"
                );
                if retryable {
                    let _ = send_text(&sender, gap_frame(&id, &epoch, seq, code, true)).await;
                    invalidated = Some(code);
                } else {
                    let _ = send_text(&sender, error_frame(Some(&id), code, false)).await;
                    flow.discard(&id).await;
                    break;
                }
            }
        }
        let delay = match query {
            SubscriptionQuery::RequestsTable { .. } => 1_000,
            _ => 5_000,
        };
        tokio::select! {
            biased;
            () = wait_for_shutdown(&mut shutdown) => break,
            () = tokio::time::sleep(Duration::from_millis(delay)) => {}
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum ViewCollection {
    Credentials,
    Snapshots,
    ResetEvents,
    Requests,
    RequestUsage,
}

impl ViewCollection {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Credentials => "credentials",
            Self::Snapshots => "snapshots",
            Self::ResetEvents => "reset_events",
            Self::Requests => "requests",
            Self::RequestUsage => "request_usage",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum ViewKey {
    Credential {
        credential: String,
        provider: String,
    },
    Snapshot {
        id: String,
    },
    ResetEvent {
        current: String,
        dimension: ResetDimension,
        kind: String,
        pool: String,
        preceding: String,
    },
    Request {
        id: String,
    },
    RequestUsage {
        bucket_start_unix: i64,
        client: Option<String>,
        credential: String,
        group: String,
        model: String,
        outcome: String,
        provider: String,
    },
}

impl ViewKey {
    fn wire_key(&self) -> String {
        match self {
            Self::Credential {
                credential,
                provider,
            } => json!([provider, credential]).to_string(),
            Self::Snapshot { id } | Self::Request { id } => id.clone(),
            Self::ResetEvent {
                current,
                dimension,
                kind,
                pool,
                preceding,
            } => json!([
                preceding,
                current,
                match dimension {
                    ResetDimension::Quota => "quota",
                    ResetDimension::Credit => "credit",
                },
                pool,
                kind
            ])
            .to_string(),
            Self::RequestUsage {
                bucket_start_unix,
                client,
                credential,
                group,
                model,
                outcome,
                provider,
            } => json!([
                bucket_start_unix,
                client,
                group,
                provider,
                credential,
                model,
                outcome
            ])
            .to_string(),
        }
    }
}

type ViewDiff = (
    BTreeMap<ViewCollection, Vec<(ViewKey, Value)>>,
    BTreeMap<ViewCollection, Vec<ViewKey>>,
);
type ViewDelta<'a> = Option<(
    &'a BTreeMap<ViewCollection, Vec<(ViewKey, Value)>>,
    &'a BTreeMap<ViewCollection, Vec<ViewKey>>,
)>;

#[derive(Debug, Clone, PartialEq)]
struct ViewState {
    collections: BTreeMap<ViewCollection, BTreeMap<ViewKey, Value>>,
    meta: Value,
}

impl ViewState {
    fn empty(kind: SubscriptionKind) -> Self {
        let collections = match kind {
            SubscriptionKind::LogsTail => BTreeMap::new(),
            SubscriptionKind::UsageOverview => [(ViewCollection::Credentials, BTreeMap::new())]
                .into_iter()
                .collect(),
            SubscriptionKind::UsageSeries => [
                (ViewCollection::Snapshots, BTreeMap::new()),
                (ViewCollection::ResetEvents, BTreeMap::new()),
            ]
            .into_iter()
            .collect(),
            SubscriptionKind::RequestsTable => [(ViewCollection::Requests, BTreeMap::new())]
                .into_iter()
                .collect(),
            SubscriptionKind::RequestsSeries => [(ViewCollection::RequestUsage, BTreeMap::new())]
                .into_iter()
                .collect(),
        };
        Self {
            collections,
            meta: Value::Null,
        }
    }

    fn insert(&mut self, collection: ViewCollection, key: ViewKey, value: Value) {
        self.collections
            .entry(collection)
            .or_default()
            .insert(key, value);
    }

    fn diff(&self, next: &Self) -> ViewDiff {
        let mut upserts = next
            .collections
            .keys()
            .map(|collection| (*collection, Vec::<(ViewKey, Value)>::new()))
            .collect::<BTreeMap<_, _>>();
        let mut removes = next
            .collections
            .keys()
            .map(|collection| (*collection, Vec::<ViewKey>::new()))
            .collect::<BTreeMap<_, _>>();
        for (collection, old_rows) in &self.collections {
            let new_rows = next.collections.get(collection);
            let mut departed = Vec::new();
            for key in old_rows.keys() {
                if new_rows.is_none_or(|rows| !rows.contains_key(key)) {
                    departed.push(key.clone());
                }
            }
            removes.insert(*collection, departed);
        }
        for (collection, new_rows) in &next.collections {
            let old_rows = self.collections.get(collection);
            let changed = new_rows
                .iter()
                .filter(|(key, value)| old_rows.is_none_or(|rows| rows.get(key) != Some(value)))
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect::<Vec<_>>();
            upserts.insert(*collection, changed);
        }
        (upserts, removes)
    }
}

fn data_frame(
    kind: &str,
    id: &str,
    epoch: &str,
    seq: u64,
    prev_seq: Option<u64>,
    view: &ViewState,
    delta: ViewDelta<'_>,
) -> Value {
    if let Some((upserts, removes)) = delta {
        let mut wire_upserts = BTreeMap::new();
        for (collection, rows) in upserts {
            wire_upserts.insert(
                collection.as_str(),
                rows.iter()
                    .map(|(key, value)| json!({"key":key.wire_key(), "value":value}))
                    .collect::<Vec<_>>(),
            );
        }
        let mut wire_removes = BTreeMap::new();
        for (collection, keys) in removes {
            wire_removes.insert(
                collection.as_str(),
                keys.iter()
                    .map(|key| json!({"key":key.wire_key(), "reason":"left_window"}))
                    .collect::<Vec<_>>(),
            );
        }
        json!({"v":1,"type":"delta","id":id,"epoch":epoch,"seq":seq,"prev_seq":prev_seq,
            "upserts":wire_upserts,"removes":wire_removes,"meta":view.meta})
    } else {
        let mut collections = BTreeMap::new();
        for (collection, rows) in &view.collections {
            collections.insert(
                collection.as_str(),
                rows.iter()
                    .map(|(key, value)| json!({"key":key.wire_key(), "value":value}))
                    .collect::<Vec<_>>(),
            );
        }
        json!({"v":1,"type":kind,"id":id,"epoch":epoch,"seq":seq,
            "collections":collections,"meta":view.meta})
    }
}

async fn send_data(
    flow: &Flow,
    sender: &mpsc::Sender<Outbound>,
    id: &str,
    epoch: &str,
    seq: u64,
    frame: Value,
) -> Result<(), Value> {
    let bytes =
        serde_json::to_vec(&frame).map_err(|_| error_frame(Some(id), "range_too_large", false))?;
    if bytes.len() > MAX_FRAME_BYTES {
        return Err(error_frame(Some(id), "range_too_large", false));
    }
    if !safe_json_numbers(&frame) {
        return Err(error_frame(Some(id), "numeric_range_unsupported", false));
    }
    flow.acquire(id, epoch, seq, bytes.len()).await?;
    sender
        .send(Outbound::Text(frame))
        .await
        .map_err(|_| error_frame(Some(id), "storage_unavailable", true))
}

#[allow(clippy::too_many_arguments)]
fn meta_value(
    now: i64,
    window: Option<(i64, i64)>,
    oldest: Option<i64>,
    has_more: bool,
    next_before: Option<&str>,
    truncated: bool,
    metadata: ControlMetadata,
) -> Value {
    json!({
        "as_of_unix":now,
        "window":window.map(|(since, until)| json!({"since_unix":since,"until_unix":until})),
        "oldest_at_unix":oldest,
        "has_more":has_more,
        "next_before":next_before,
        "truncated":truncated,
        "known_gaps":report::known_gaps(),
        "request_loss_total":metadata.request_loss_total,
        "provider_snapshot_loss_total":metadata.provider_snapshot_loss_total,
        "reset_events_observed_only":true,
        "reset_events_complete_since_unix":null
    })
}

#[allow(clippy::type_complexity)]
#[expect(
    clippy::too_many_lines,
    reason = "each subscription kind lowers one coherent storage view and metadata tuple"
)]
async fn evaluate(
    config: &Config,
    reader: &mut ControlReader,
    query: &SubscriptionQuery,
    now: i64,
) -> Result<ViewState, &'static str> {
    let query_kind = query.kind();
    match query {
        SubscriptionQuery::UsageOverview { query } => {
            let mut requested = Vec::new();
            for credential in config.usage_credentials() {
                if query
                    .provider
                    .as_deref()
                    .is_some_and(|value| value != credential.provider.as_ref())
                    || query
                        .credential
                        .as_deref()
                        .is_some_and(|value| value != credential.id.as_ref())
                {
                    continue;
                }
                requested.push(airlock_core::storage::OverviewCredentialQuery {
                    credential: credential.id.clone(),
                    fetch_source: SnapshotSource::OutOfBandFetch,
                    fetch_surface: report::target_surface(credential.provider_kind),
                    header_surface: SnapshotSurface::ResponseHeaders,
                    provider: credential.provider.clone(),
                });
            }
            let page = reader
                .overview(requested)
                .await
                .map_err(|error| storage_code(&error))?;
            let by_id = page
                .credentials
                .into_iter()
                .map(|entry| (entry.credential.clone(), entry))
                .collect::<BTreeMap<_, _>>();
            let mut view = ViewState::empty(query_kind);
            for credential in config.usage_credentials() {
                if query
                    .provider
                    .as_deref()
                    .is_some_and(|value| value != credential.provider.as_ref())
                    || query
                        .credential
                        .as_deref()
                        .is_some_and(|value| value != credential.id.as_ref())
                {
                    continue;
                }
                if let Some(entry) = by_id.get(&credential.id) {
                    view.insert(
                        ViewCollection::Credentials,
                        ViewKey::Credential {
                            credential: credential.id.as_ref().to_owned(),
                            provider: credential.provider.as_ref().to_owned(),
                        },
                        report::credential_json(
                            &credential,
                            entry.latest_fetch.as_ref(),
                            entry.latest_header.as_ref(),
                            now,
                        ),
                    );
                }
            }
            view.meta = meta_value(now, None, None, false, None, false, page.metadata);
            Ok(view)
        }
        SubscriptionQuery::UsageSeries { query } => {
            let provider =
                ProviderId::try_from(query.provider.as_str()).map_err(|_| "invalid_query")?;
            let credential =
                CredentialId::try_from(query.credential.as_str()).map_err(|_| "invalid_query")?;
            let (since, until) = resolve_window(&query.window, now);
            let page = reader
                .identified_snapshot_page(
                    SnapshotQuery {
                        limit: NonZeroU64::new(query.limit).ok_or("invalid_query")?,
                        provider,
                        since_unix: since,
                    },
                    until,
                    credential,
                    query.source.into_reader(),
                    query.surface.into_reader(),
                )
                .await
                .map_err(|error| storage_code(&error))?;
            let mut all = Vec::new();
            if let Some(predecessor) = page.predecessor.as_ref() {
                all.push(predecessor.clone());
            }
            all.extend(page.snapshots.clone());
            let reset_events = report::identified_reset_events(&all);
            let mut view = ViewState::empty(query_kind);
            for snapshot in &page.snapshots {
                view.insert(
                    ViewCollection::Snapshots,
                    ViewKey::Snapshot {
                        id: snapshot.id.to_string(),
                    },
                    report::snapshot_json(&snapshot.snapshot, now),
                );
            }
            for event in reset_events {
                if page
                    .snapshots
                    .iter()
                    .any(|snapshot| snapshot.id == event.current_snapshot_id)
                {
                    let kind = event
                        .value
                        .get("kind")
                        .and_then(Value::as_str)
                        .ok_or("storage_corrupt")?;
                    view.insert(
                        ViewCollection::ResetEvents,
                        ViewKey::ResetEvent {
                            current: event.current_snapshot_id.to_string(),
                            dimension: event.dimension,
                            kind: kind.to_owned(),
                            pool: event.pool.clone(),
                            preceding: event.preceding_snapshot_id.to_string(),
                        },
                        event.value,
                    );
                }
            }
            let oldest = page
                .snapshots
                .first()
                .map(|snapshot| snapshot.snapshot.fetched_at_unix);
            let metadata = page.metadata;
            let truncated = page.truncated;
            view.meta = meta_value(
                now,
                Some((since, until)),
                oldest,
                truncated,
                None,
                truncated,
                metadata,
            );
            Ok(view)
        }
        SubscriptionQuery::RequestsTable { query } => {
            let cursor = query
                .before
                .as_deref()
                .and_then(|before| parse_cursor(before, query));
            let (since, until, as_of) = cursor.as_ref().map_or_else(
                || {
                    let (since, until) = resolve_window(&query.window, now);
                    (since, until, now)
                },
                |cursor| (cursor.since_unix, cursor.until_unix, cursor.until_unix),
            );
            let page = reader
                .request_row_page(RequestRowQuery {
                    before: cursor
                        .clone()
                        .map(|cursor| airlock_core::storage::RequestRowCursor {
                            cutoff_id: cursor.cutoff_id,
                            occurred_at_unix: cursor.occurred_at_unix,
                            row_id: cursor.row_id,
                        }),
                    client: parse_client_filter(query.client.as_ref())?,
                    credential: parse_id(query.credential.as_deref())?,
                    group: parse_id(query.group.as_deref())?,
                    limit: query.limit,
                    model: query.model.clone(),
                    outcome: query.outcome.map(Into::into),
                    provider: parse_id(query.provider.as_deref())?,
                    since_unix: since,
                    until_unix: until,
                })
                .await
                .map_err(|error| storage_code(&error))?;
            let mut view = ViewState::empty(query_kind);
            for row in &page.rows {
                view.insert(
                    ViewCollection::Requests,
                    ViewKey::Request {
                        id: row.id.to_string(),
                    },
                    request_row_json(row),
                );
            }
            let oldest = page.rows.iter().map(|row| row.occurred_at_unix).min();
            let next = page
                .next_before
                .map(|storage_cursor| {
                    cursor.map_or_else(
                        || RequestCursor::first(query, storage_cursor, since, until),
                        |mut frozen| {
                            frozen.cutoff_id = frozen.cutoff_id.max(storage_cursor.cutoff_id);
                            frozen.occurred_at_unix = storage_cursor.occurred_at_unix;
                            frozen.row_id = storage_cursor.row_id;
                            frozen
                        },
                    )
                })
                .as_ref()
                .and_then(cursor_string);
            let metadata = page.metadata;
            let has_more = page.has_more;
            view.meta = meta_value(
                as_of,
                Some((since, until)),
                oldest,
                has_more,
                next.as_deref(),
                false,
                metadata,
            );
            Ok(view)
        }
        SubscriptionQuery::RequestsSeries { query } => {
            let (since, until) = resolve_window(&query.window, now);
            let page = reader
                .request_series(RequestSeriesQuery {
                    bucket_seconds: NonZeroU64::new(query.bucket_seconds).ok_or("invalid_query")?,
                    client: parse_client_filter(query.client.as_ref())?,
                    credential: parse_id(query.credential.as_deref())?,
                    group: parse_id(query.group.as_deref())?,
                    model: query.model.clone(),
                    outcome: query.outcome.map(Into::into),
                    provider: parse_id(query.provider.as_deref())?,
                    since_unix: since,
                    until_unix: until,
                })
                .await
                .map_err(|error| storage_code(&error))?;
            let mut view = ViewState::empty(query_kind);
            for aggregate in &page.aggregates {
                view.insert(
                    ViewCollection::RequestUsage,
                    ViewKey::RequestUsage {
                        bucket_start_unix: aggregate.aggregate.bucket_start_unix,
                        client: aggregate
                            .aggregate
                            .client
                            .as_ref()
                            .map(|client| client.as_ref().to_owned()),
                        credential: aggregate.aggregate.credential.as_ref().to_owned(),
                        group: aggregate.group.as_ref().to_owned(),
                        model: aggregate.aggregate.model.clone(),
                        outcome: outcome_string(aggregate.aggregate.outcome).to_owned(),
                        provider: aggregate.aggregate.provider.as_ref().to_owned(),
                    },
                    report::aggregate_json(aggregate.group.as_ref(), &aggregate.aggregate),
                );
            }
            let oldest = page
                .aggregates
                .iter()
                .map(|row| row.aggregate.bucket_start_unix)
                .min();
            let metadata = page.metadata;
            view.meta = meta_value(
                now,
                Some((since, until)),
                oldest,
                false,
                None,
                false,
                metadata,
            );
            Ok(view)
        }
        SubscriptionQuery::LogsTail { .. } => Err("unsupported_subscription"),
    }
}

fn request_row_json(row: &airlock_core::storage::RequestRow) -> Value {
    json!({
        "id":row.id.to_string(),"occurred_at_unix":row.occurred_at_unix,
        "client":row.client.as_ref().map(AsRef::as_ref),"group":row.group.as_ref(),
        "credential":row.credential.as_ref(),"provider":row.provider.as_ref(),
        "model":row.model,"outcome":match row.outcome {
            RequestOutcome::Cancelled => "cancelled", RequestOutcome::Completed => "completed",
            RequestOutcome::Failed => "failed", RequestOutcome::Rejected => "rejected",
        },"status_code":row.status_code,"latency_ms":row.latency_ms,
        "request_bytes":row.request_bytes,"response_bytes":row.response_bytes,
        "input_tokens":row.input_tokens,"output_tokens":row.output_tokens,
        "cache_read_tokens":row.cache_read_tokens,"cache_write_tokens":row.cache_write_tokens,
        "usage_complete":row.usage_complete
    })
}

fn storage_code(error: &StorageError) -> &'static str {
    match error {
        StorageError::QueryBudgetExceeded => "query_budget_exceeded",
        StorageError::Database(sqlx::Error::Database(database)) => {
            match database
                .code()
                .and_then(|code| code.parse::<i32>().ok())
                .map(|code| code & 0xff)
            {
                Some(5 | 6) => "storage_busy",
                Some(11 | 26) => "storage_corrupt",
                _ => "storage_unavailable",
            }
        }
        StorageError::Integrity { .. } | StorageError::StoredId { .. } => "storage_corrupt",
        StorageError::Input { .. } => "invalid_query",
        StorageError::SnapshotRangeIncomplete | StorageError::UsageRangeIncomplete => {
            "range_too_large"
        }
        _ => "storage_unavailable",
    }
}

fn safe_json_numbers(value: &Value) -> bool {
    match value {
        Value::Number(number) => {
            number
                .as_i64()
                .is_none_or(|number| number.unsigned_abs() <= 9_007_199_254_740_991)
                && number
                    .as_u64()
                    .is_none_or(|number| number <= 9_007_199_254_740_991)
        }
        Value::Array(values) => values.iter().all(safe_json_numbers),
        Value::Object(values) => values.values().all(safe_json_numbers),
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ClientFrame, ControlServer, ControlState, Flow, MAX_UNACKED_BYTES, MAX_UNACKED_FRAMES,
        Outbound, QueryBody, RequestCursor, RequestsTableQuery, SubscriptionKind,
        SubscriptionQuery, Window, close_subscription, cursor_string, decode_client_frame,
        gap_frame, now_unix, router,
    };
    use airlock_core::config::{Config, RawConfig};
    use airlock_core::storage::SqliteStorage;
    use axum::{
        body::Bytes,
        extract::ws::Message,
        http::{Request, StatusCode, header},
    };
    use futures_util::{SinkExt, StreamExt};
    use http_body_util::BodyExt;
    use serde_json::Value;
    use sqlx::Connection;
    use std::{os::unix::fs::PermissionsExt, sync::Arc, time::Duration};
    use tokio::sync::{Notify, mpsc, watch};
    use tower::ServiceExt;

    const CLIENT_TRANSCRIPT: &str =
        include_str!("../../../../web-fixtures/protocol-v1-client-transcript.json");

    fn decode(value: &Value) -> ClientFrame {
        decode_client_frame(Message::Text(value.to_string().into())).expect("client fixture frame")
    }

    #[test]
    fn decodes_frozen_client_transcript_with_sibling_kind_and_query() {
        let frames = serde_json::from_str::<Vec<Value>>(CLIENT_TRANSCRIPT).expect("fixture JSON");
        let mut subscriptions = 0;
        for frame in &frames {
            match decode(frame) {
                ClientFrame::Auth { .. }
                | ClientFrame::Ack { .. }
                | ClientFrame::Unsubscribe { .. }
                | ClientFrame::Pong { .. } => {}
                ClientFrame::Subscribe { .. } => subscriptions += 1,
            }
        }
        assert_eq!(subscriptions, 3);
    }

    #[test]
    fn rejects_unknown_fields_and_mismatched_kind_query_shapes() {
        let unknown = serde_json::json!({
            "v": 1,
            "type": "subscribe",
            "id": "quota",
            "kind": "usage.series",
            "query": {
                "provider": "claude",
                "credential": "claude",
                "source": "out_of_band_fetch",
                "surface": "claude_subscription",
                "window": {"last_seconds": 86400},
                "limit": 1000,
                "unexpected": true
            }
        });
        assert!(decode_client_frame(Message::Text(unknown.to_string().into())).is_err());

        let mismatch = serde_json::json!({
            "v": 1,
            "type": "subscribe",
            "id": "quota",
            "kind": "usage.series",
            "query": {
                "provider": "claude",
                "credential": "claude",
                "source": "out_of_band_fetch",
                "surface": "claude_subscription",
                "window": {"last_seconds": 86400},
                "limit": 1000
            },
        });
        let ClientFrame::Subscribe {
            kind,
            query: QueryBody::UsageSeries(_),
            v: 1,
            ..
        } = decode(&mismatch)
        else {
            panic!("usage-series body must decode");
        };
        assert_eq!(kind, SubscriptionKind::UsageSeries);
        let overview = QueryBody::UsageOverview(super::OverviewQuery {
            credential: None,
            provider: None,
        });
        assert!(SubscriptionQuery::new(kind, overview).is_none());
    }

    async fn control_server_fixture() -> (ControlServer, tempfile::TempDir, tempfile::TempDir) {
        let directory = tempfile::tempdir().expect("test state");
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
            .expect("private state directory");
        let web = tempfile::tempdir().expect("web root");
        std::fs::create_dir(web.path().join("assets")).expect("assets directory");
        std::fs::write(
            web.path().join("index.html"),
            b"<!doctype html><p>airlock</p>",
        )
        .expect("index");
        std::fs::write(
            web.path().join("assets/app.js"),
            b"globalThis.checked = true;",
        )
        .expect("asset");
        let reserved = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("reserve control port");
        let control_port = reserved.local_addr().expect("reserved address").port();
        drop(reserved);
        let token_path = directory.path().join("control-token");
        std::fs::write(&token_path, b"fake-control-token").expect("write control token");
        std::fs::write(directory.path().join("client-token"), b"fake-proxy-token")
            .expect("write proxy token");
        let config_value = serde_json::json!({
            "clients": {
                "harness": {
                    "grants": ["anthropic"],
                    "token_file": directory.path().join("client-token")
                }
            },
            "control": {
                "listen": format!("127.0.0.1:{control_port}"),
                "read_token_file": token_path
            },
            "credentials": {
                "claude": {
                    "auth": {"file": directory.path().join("claude-token"), "type": "oauth_bearer"},
                    "provider": "claude"
                }
            },
            "groups": {
                "anthropic": {
                    "intercept": ["api.anthropic.com"],
                    "members": {"claude": {"models": []}},
                    "primary": "claude",
                    "protocol": "anthropic"
                }
            },
            "listen": "127.0.0.1:9",
            "providers": {"claude": {"preset": "claude"}},
            "state_dir": directory.path(),
            "unknown_hosts": "tunnel"
        });
        let raw = serde_json::from_value::<RawConfig>(config_value).expect("raw config");
        let config = Arc::new(Config::try_from(raw).expect("valid config"));
        let storage = SqliteStorage::open(directory.path(), config.storage_identities(1))
            .await
            .expect("storage");
        storage.close().await.expect("close storage");
        let token = config
            .control()
            .expect("control config")
            .read_token_file()
            .load()
            .expect("control token");
        let server = ControlServer::bind(
            Arc::clone(&config),
            directory.path(),
            web.path(),
            Arc::new(token),
        )
        .await
        .expect("control server");
        (server, directory, web)
    }

    #[tokio::test]
    async fn loopback_socket_authenticates_snapshots_acks_and_unsubscribes() {
        use tokio_tungstenite::tungstenite::client::IntoClientRequest;

        let (server, _directory, _web) = control_server_fixture().await;
        let authority = server.local_addr().to_string();
        let (shutdown, mut shutdown_received) = watch::channel(());
        let serve = tokio::spawn(server.serve(async move {
            let _ = shutdown_received.changed().await;
        }));

        let mut request = format!("ws://{authority}/api/v1/live")
            .into_client_request()
            .expect("websocket request");
        request
            .headers_mut()
            .insert("Host", authority.parse().expect("host header"));
        request.headers_mut().insert(
            "Origin",
            format!("http://{authority}")
                .parse()
                .expect("origin header"),
        );
        request.headers_mut().insert(
            "Sec-WebSocket-Protocol",
            "airlock.v1".parse().expect("protocol header"),
        );
        let (mut socket, _) = tokio_tungstenite::connect_async(request)
            .await
            .expect("websocket upgrade");
        socket
            .send(tokio_tungstenite::tungstenite::Message::Text(
                serde_json::json!({
                    "v":1, "type":"auth", "token":"fake-control-token"
                })
                .to_string()
                .into(),
            ))
            .await
            .expect("send auth");
        let hello = tokio::time::timeout(std::time::Duration::from_secs(2), socket.next())
            .await
            .expect("hello deadline")
            .expect("hello stream")
            .expect("hello websocket")
            .into_text()
            .expect("hello text");
        let hello = serde_json::from_str::<serde_json::Value>(hello.as_ref()).expect("hello json");
        assert_eq!(hello["type"], "hello");
        socket
            .send(tokio_tungstenite::tungstenite::Message::Text(
                serde_json::json!({
                    "v":1,
                    "type":"subscribe",
                    "id":"overview",
                    "kind":"usage.overview",
                    "query": {}
                })
                .to_string()
                .into(),
            ))
            .await
            .expect("send subscribe");
        let subscribed = websocket_json(&mut socket).await;
        assert_eq!(subscribed["type"], "subscribed");
        assert_eq!(subscribed["id"], "overview");
        let epoch = subscribed["epoch"].as_str().expect("epoch").to_owned();
        let snapshot = websocket_json(&mut socket).await;
        assert_eq!(snapshot["type"], "snapshot");
        assert_eq!(snapshot["seq"], 1);

        socket
            .send(tokio_tungstenite::tungstenite::Message::Text(
                serde_json::json!({
                    "v":1, "type":"ack", "id":"overview", "epoch":epoch, "seq":1
                })
                .to_string()
                .into(),
            ))
            .await
            .expect("send ack");
        socket
            .send(tokio_tungstenite::tungstenite::Message::Text(
                serde_json::json!({"v":1, "type":"unsubscribe", "id":"overview"})
                    .to_string()
                    .into(),
            ))
            .await
            .expect("send unsubscribe");
        let unsubscribed = websocket_json(&mut socket).await;
        assert_eq!(unsubscribed["type"], "unsubscribed");

        drop(socket);
        shutdown.send(()).expect("shutdown server");
        serve
            .await
            .expect("serve task")
            .expect("serve clean shutdown");
    }

    async fn response_parts(
        response: axum::response::Response,
    ) -> (StatusCode, header::HeaderMap, Bytes) {
        let status = response.status();
        let headers = response.headers().clone();
        let bytes = response
            .into_body()
            .collect()
            .await
            .expect("response body")
            .to_bytes();
        (status, headers, bytes)
    }

    #[tokio::test]
    async fn http_usage_requires_dedicated_bearer_and_strict_safe_queries() {
        let (server, _directory, _web) = control_server_fixture().await;
        let app = router(server.state);

        let missing_token = app
            .clone()
            .oneshot(
                Request::get("/api/v1/usage")
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .expect("missing token response");
        let (status, headers, bytes) = response_parts(missing_token).await;
        let body: serde_json::Value = serde_json::from_slice(&bytes).expect("error JSON");
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body["error"]["code"], "unauthorized");
        assert_eq!(headers[header::CACHE_CONTROL], "no-store");

        let proxy_token = Request::get("/api/v1/usage")
            .header(header::AUTHORIZATION, "Bearer fake-proxy-token")
            .body(axum::body::Body::empty())
            .unwrap();
        let (status, _, _) = response_parts(
            app.clone()
                .oneshot(proxy_token)
                .await
                .expect("proxy rejection"),
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);

        let duplicate = Request::get("/api/v1/usage?since_unix=2&since_unix=3")
            .header(header::AUTHORIZATION, "Bearer fake-control-token")
            .body(axum::body::Body::empty())
            .unwrap();
        let (status, _, bytes) = response_parts(
            app.clone()
                .oneshot(duplicate)
                .await
                .expect("duplicate response"),
        )
        .await;
        let body: serde_json::Value = serde_json::from_slice(&bytes).expect("error JSON");
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"]["code"], "invalid_query");

        let unsafe_integer = Request::get("/api/v1/usage?since_unix=9999999999999999999")
            .header(header::AUTHORIZATION, "Bearer fake-control-token")
            .body(axum::body::Body::empty())
            .unwrap();
        let (status, _, bytes) = response_parts(
            app.clone()
                .oneshot(unsafe_integer)
                .await
                .expect("range response"),
        )
        .await;
        let body: serde_json::Value = serde_json::from_slice(&bytes).expect("error JSON");
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"]["code"], "numeric_range_unsupported");

        for uri in ["/api/v1/usage", "/api/v1/usage?"] {
            let request = Request::get(uri)
                .header(header::AUTHORIZATION, "Bearer fake-control-token")
                .body(axum::body::Body::empty())
                .unwrap();
            let (status, _, bytes) =
                response_parts(app.clone().oneshot(request).await.expect("default report")).await;
            assert_eq!(
                status,
                StatusCode::OK,
                "{uri}: {}",
                String::from_utf8_lossy(&bytes)
            );
        }

        let valid =
            Request::get("/api/v1/usage?since_unix=1&bucket_seconds=3600&history_limit=100")
                .header(header::AUTHORIZATION, "Bearer fake-control-token")
                .body(axum::body::Body::empty())
                .unwrap();
        let (status, headers, _) =
            response_parts(app.oneshot(valid).await.expect("valid response")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(headers[header::CACHE_CONTROL], "no-store");
    }

    #[tokio::test]
    async fn http_usage_rejects_unsafe_persisted_count() {
        let (server, directory, _web) = control_server_fixture().await;
        let path = directory.path().join("airlock.sqlite3");
        let mut connection =
            sqlx::SqliteConnection::connect(&format!("sqlite://{}", path.display()))
                .await
                .expect("test database");
        sqlx::query(
            "INSERT INTO request_events (occurred_at_unix, group_id, credential_id, model_id, outcome, status_code, request_bytes, response_bytes, latency_ms, input_tokens, output_tokens, usage_complete, dropped_events) VALUES (?, 'anthropic', 'claude', 'claude-sonnet-5', 'completed', 200, 9007199254740992, 0, 1, 0, 0, 1, 0)",
        )
        .bind(super::now_unix() - 1)
        .execute(&mut connection)
        .await
        .expect("persist unsafe count");
        connection.close().await.expect("close test writer");

        let request = Request::get("/api/v1/usage")
            .header(header::AUTHORIZATION, "Bearer fake-control-token")
            .body(axum::body::Body::empty())
            .unwrap();
        let (status, _, bytes) = response_parts(
            router(server.state)
                .oneshot(request)
                .await
                .expect("usage response"),
        )
        .await;
        let body: Value = serde_json::from_slice(&bytes).expect("error JSON");
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"]["code"], "numeric_range_unsupported");
    }

    #[tokio::test]
    async fn static_routes_have_explicit_types_and_no_directory_or_traversal_fallback() {
        let (server, _directory, _web) = control_server_fixture().await;
        let app = router(server.state);

        let index = app
            .clone()
            .oneshot(Request::get("/").body(axum::body::Body::empty()).unwrap())
            .await
            .expect("index");
        let (status, headers, body) = response_parts(index).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body.as_ref(), b"<!doctype html><p>airlock</p>");
        assert_eq!(headers[header::CONTENT_TYPE], "text/html; charset=utf-8");
        assert_eq!(headers[header::CACHE_CONTROL], "no-store");
        assert!(
            headers[header::CONTENT_SECURITY_POLICY]
                .to_str()
                .expect("CSP")
                .contains("frame-ancestors 'none'")
        );

        let asset = app
            .clone()
            .oneshot(
                Request::get("/assets/app.js")
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .expect("asset");
        let (status, headers, body) = response_parts(asset).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body.as_ref(), b"globalThis.checked = true;");
        assert_eq!(headers[header::CONTENT_TYPE], "text/javascript");

        // The encoded-parent fixture is `%2F` + `index`.
        for path in [
            "/missing",
            "/assets/",
            "/assets/missing.js",
            // cspell:disable-next-line
            "/assets/..%2Findex.html",
            "/api/v1/usage/extra",
        ] {
            let response = app
                .clone()
                .oneshot(Request::get(path).body(axum::body::Body::empty()).unwrap())
                .await
                .expect("missing route");
            let (status, _, bytes) = response_parts(response).await;
            assert_eq!(status, StatusCode::NOT_FOUND, "{path}");
            if path.starts_with("/assets/") {
                assert!(bytes.is_empty(), "{path}: {bytes:?}");
            } else {
                let body: serde_json::Value = serde_json::from_slice(&bytes).expect("JSON error");
                assert_eq!(body["error"]["code"], "not_found", "{path}");
            }
        }
    }

    async fn websocket_json(
        socket: &mut tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    ) -> serde_json::Value {
        let message = tokio::time::timeout(std::time::Duration::from_secs(2), socket.next())
            .await
            .expect("frame deadline")
            .expect("frame stream")
            .expect("frame websocket")
            .into_text()
            .expect("frame text");
        serde_json::from_str(message.as_ref()).expect("frame json")
    }

    async fn connect_control(
        authority: &str,
    ) -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>
    {
        use tokio_tungstenite::tungstenite::client::IntoClientRequest;

        let mut request = format!("ws://{authority}/api/v1/live")
            .into_client_request()
            .expect("websocket request");
        request
            .headers_mut()
            .insert("Host", authority.parse().expect("host header"));
        request.headers_mut().insert(
            "Origin",
            format!("http://{authority}")
                .parse()
                .expect("origin header"),
        );
        request.headers_mut().insert(
            "Sec-WebSocket-Protocol",
            "airlock.v1".parse().expect("protocol header"),
        );
        tokio_tungstenite::connect_async(request)
            .await
            .expect("websocket upgrade")
            .0
    }

    async fn websocket_message(
        socket: &mut tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    ) -> tokio_tungstenite::tungstenite::Message {
        tokio::time::timeout(Duration::from_secs(2), socket.next())
            .await
            .expect("websocket message deadline")
            .expect("websocket stream")
            .expect("websocket message")
    }

    async fn rejected_control_upgrade(
        authority: &str,
        host: Option<&str>,
        origin: Option<&str>,
        protocol: Option<&str>,
    ) -> (StatusCode, serde_json::Value) {
        use tokio_tungstenite::tungstenite::client::IntoClientRequest;

        let mut request = format!("ws://{authority}/api/v1/live")
            .into_client_request()
            .expect("websocket request");
        match host {
            Some(value) => request
                .headers_mut()
                .insert("Host", value.parse().expect("host value")),
            None => request.headers_mut().remove("Host"),
        };
        match origin {
            Some(value) => request
                .headers_mut()
                .insert("Origin", value.parse().expect("origin value")),
            None => request.headers_mut().remove("Origin"),
        };
        match protocol {
            Some(value) => request.headers_mut().insert(
                "Sec-WebSocket-Protocol",
                value.parse().expect("protocol value"),
            ),
            None => request.headers_mut().remove("Sec-WebSocket-Protocol"),
        };
        let error = tokio_tungstenite::connect_async(request)
            .await
            .expect_err("rejected upgrade");
        let tokio_tungstenite::tungstenite::Error::Http(response) = error else {
            panic!("upgrade must return HTTP: {error:?}");
        };
        let status = response.status();
        let bytes = response.into_body().unwrap_or_default();
        (
            status,
            serde_json::from_slice(&bytes).expect("rejection JSON"),
        )
    }

    async fn socket_send(
        socket: &mut tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
        frame: serde_json::Value,
    ) {
        socket
            .send(tokio_tungstenite::tungstenite::Message::Text(
                frame.to_string().into(),
            ))
            .await
            .expect("send client frame");
    }

    async fn authenticate(
        socket: &mut tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    ) {
        socket_send(
            socket,
            serde_json::json!({"v":1,"type":"auth","token":"fake-control-token"}),
        )
        .await;
        let hello = websocket_json(socket).await;
        assert_eq!(hello["type"], "hello");
        assert!(
            hello
                .get("limits")
                .and_then(|limits| limits.get("replay_ttl_seconds"))
                .is_none()
        );
    }

    fn start_control(
        server: ControlServer,
    ) -> (
        String,
        ControlState,
        watch::Sender<()>,
        tokio::task::JoinHandle<Result<(), super::Error>>,
    ) {
        let state = server.state.clone();
        let authority = server.local_addr().to_string();
        let (shutdown, mut shutdown_received) = watch::channel(());
        let serve = tokio::spawn(server.serve(async move {
            let _ = shutdown_received.changed().await;
        }));
        (authority, state, shutdown, serve)
    }

    #[tokio::test(start_paused = true)]
    async fn stalled_flow_closes_1013_while_independent_flow_continues() {
        let stalled = Arc::new(Flow::default());
        let independent = Flow::default();
        for seq in 1..=MAX_UNACKED_FRAMES {
            stalled
                .acquire("widget", "epoch", seq as u64, 1)
                .await
                .expect("fill credit");
        }
        let blocked = Arc::clone(&stalled);
        let slow = tokio::spawn(async move {
            blocked
                .acquire("widget", "epoch", MAX_UNACKED_FRAMES as u64 + 1, 1)
                .await
                .expect_err("credit exhausted")
        });
        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(10)).await;
        let gap = tokio::time::timeout(Duration::from_secs(1), slow)
            .await
            .expect("slow deadline")
            .expect("slow task");
        assert_eq!(gap["code"], "slow_consumer");
        independent
            .acquire("other", "epoch", 1, 1)
            .await
            .expect("independent flow has fresh credit");
        let (sender, mut receiver) = mpsc::channel(2);
        close_subscription(&sender, gap, &Notify::new());
        assert!(matches!(receiver.try_recv(), Ok(Outbound::Text(_))));
        assert!(matches!(
            receiver.try_recv(),
            Ok(Outbound::Close(Some(1013)))
        ));
    }

    fn fixed_cursor_query() -> serde_json::Value {
        let mut query = RequestsTableQuery {
            before: None,
            client: None,
            credential: None,
            group: None,
            limit: 1,
            model: None,
            outcome: None,
            provider: None,
            window: Window::Fixed {
                since_unix: 1,
                until_unix: 2,
            },
        };
        let cursor = RequestCursor::first(
            &query,
            airlock_core::storage::RequestRowCursor {
                cutoff_id: 1,
                occurred_at_unix: 1,
                row_id: 1,
            },
            1,
            2,
        );
        query.before = cursor_string(&cursor);
        serde_json::to_value(&query).expect("fixed cursor query")
    }

    async fn subscribe_ack_fixed_cursor(
        socket: &mut tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
        id: &str,
    ) -> String {
        socket_send(
            socket,
            serde_json::json!({
                "v":1,"type":"subscribe","id":id,"kind":"requests.table",
                "query":fixed_cursor_query()
            }),
        )
        .await;
        let subscribed = websocket_json(socket).await;
        assert_eq!(subscribed["type"], "subscribed");
        let epoch = subscribed["epoch"].as_str().expect("epoch").to_owned();
        let snapshot = websocket_json(socket).await;
        assert_eq!(snapshot["type"], "snapshot");
        assert_eq!(snapshot["id"], id);
        socket_send(
            socket,
            serde_json::json!({"v":1,"type":"ack","id":id,"epoch":epoch,"seq":1}),
        )
        .await;
        epoch
    }

    #[tokio::test]
    async fn completed_cursor_subscriptions_retain_ownership_until_unsubscribe() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, state, shutdown, serve) = start_control(server);
        let mut socket = connect_control(&authority).await;
        authenticate(&mut socket).await;

        let mut retired_epoch = String::new();
        for index in 0..super::MAX_SUBSCRIPTIONS {
            let id = format!("fixed-{index}");
            let epoch = subscribe_ack_fixed_cursor(&mut socket, &id).await;
            if index == 0 {
                retired_epoch = epoch;
            }
        }

        socket_send(
            &mut socket,
            serde_json::json!({
                "v":1,"type":"subscribe","id":"ninth","kind":"requests.table",
                "query":fixed_cursor_query()
            }),
        )
        .await;
        let refusal = websocket_json(&mut socket).await;
        assert_eq!(refusal["type"], "error");
        assert_eq!(refusal["id"], "ninth");
        assert_eq!(refusal["code"], "resource_limit");

        socket_send(
            &mut socket,
            serde_json::json!({"v":1,"type":"unsubscribe","id":"fixed-0"}),
        )
        .await;
        assert_eq!(websocket_json(&mut socket).await["type"], "unsubscribed");

        let replacement_epoch = subscribe_ack_fixed_cursor(&mut socket, "replacement").await;
        assert_ne!(replacement_epoch, retired_epoch);

        socket_send(
            &mut socket,
            serde_json::json!({
                "v":1,"type":"ack","id":"fixed-0","epoch":retired_epoch,"seq":1
            }),
        )
        .await;
        let invalid = websocket_json(&mut socket).await;
        assert_eq!(invalid["type"], "error");
        assert_eq!(invalid["code"], "invalid_frame");
        assert!(matches!(
            websocket_message(&mut socket).await,
            tokio_tungstenite::tungstenite::Message::Close(_)
        ));
        drop(socket);
        wait_for_active_sessions(&state, 0).await;
        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test]
    async fn real_reconnect_authenticates_and_resubscribes_with_fresh_snapshots() {
        let (server, directory, _web) = control_server_fixture().await;
        let (authority, state, shutdown, serve) = start_control(server);
        let subscribe = serde_json::json!({
            "v":1,"type":"subscribe","id":"rows","kind":"requests.table",
            "query":{"limit":200,"window":{"last_seconds":3600}}
        });
        let mut first = connect_control(&authority).await;
        authenticate(&mut first).await;
        socket_send(&mut first, subscribe.clone()).await;
        let first_subscribed = websocket_json(&mut first).await;
        assert_eq!(first_subscribed["type"], "subscribed");
        let first_snapshot = websocket_json(&mut first).await;
        assert_eq!(first_snapshot["type"], "snapshot");
        assert_eq!(first_snapshot["seq"], 1);
        drop(first);
        wait_for_active_sessions(&state, 0).await;

        let database = directory.path().join("airlock.sqlite3");
        let mut writer =
            sqlx::SqliteConnection::connect(&format!("sqlite://{}", database.display()))
                .await
                .expect("seed first request");
        sqlx::query("INSERT INTO request_events (occurred_at_unix, client_id, group_id, credential_id, model_id, outcome, status_code, request_bytes, response_bytes, latency_ms, input_tokens, output_tokens, usage_complete, dropped_events) VALUES (?, NULL, 'anthropic', 'claude', 'model', 'completed', 200, 1, 1, 1, 1, 1, 1, 0)")
            .bind(now_unix() - 1)
            .execute(&mut writer)
            .await
            .expect("insert first request");
        writer.close().await.expect("close first writer");

        let mut second = connect_control(&authority).await;
        authenticate(&mut second).await;
        socket_send(&mut second, subscribe).await;
        let second_subscribed = websocket_json(&mut second).await;
        assert_eq!(second_subscribed["type"], "subscribed");
        assert_ne!(second_subscribed["epoch"], first_subscribed["epoch"]);
        let second_snapshot = websocket_json(&mut second).await;
        assert_eq!(second_snapshot["type"], "snapshot");
        assert_eq!(second_snapshot["seq"], 1);
        assert_eq!(second_snapshot["epoch"], second_subscribed["epoch"]);
        assert_eq!(
            second_snapshot["collections"]["requests"]
                .as_array()
                .expect("rows")
                .len(),
            1
        );
        socket_send(
            &mut second,
            serde_json::json!({
                "v":1,"type":"ack","id":"rows",
                "epoch":second_subscribed["epoch"],"seq":1
            }),
        )
        .await;

        let mut writer =
            sqlx::SqliteConnection::connect(&format!("sqlite://{}", database.display()))
                .await
                .expect("seed second request");
        sqlx::query("INSERT INTO request_events (occurred_at_unix, client_id, group_id, credential_id, model_id, outcome, status_code, request_bytes, response_bytes, latency_ms, input_tokens, output_tokens, usage_complete, dropped_events) VALUES (?, NULL, 'anthropic', 'claude', 'model', 'completed', 200, 1, 1, 1, 1, 1, 1, 0)")
            .bind(now_unix() - 1)
            .execute(&mut writer)
            .await
            .expect("insert second request");
        writer.close().await.expect("close second writer");
        let delta = tokio::time::timeout(Duration::from_secs(2), websocket_json(&mut second))
            .await
            .expect("delta deadline");
        assert_eq!(delta["type"], "delta");
        assert_eq!(delta["epoch"], second_subscribed["epoch"]);
        assert_eq!(delta["seq"], 2);
        assert_eq!(delta["prev_seq"], 1);
        socket_send(
            &mut second,
            serde_json::json!({
                "v":1,"type":"ack","id":"rows",
                "epoch":second_subscribed["epoch"],"seq":2
            }),
        )
        .await;
        second.close(None).await.expect("close second socket");
        drop(second);
        wait_for_active_sessions(&state, 0).await;
        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test]
    async fn shutdown_drains_preauth_and_subscribed_sockets_before_closing_reader() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, state, shutdown, serve) = start_control(server);
        let mut preauth = connect_control(&authority).await;
        let mut subscribed = connect_control(&authority).await;
        authenticate(&mut subscribed).await;
        socket_send(
            &mut subscribed,
            serde_json::json!({"v":1,"type":"subscribe","id":"before","kind":"usage.overview","query":{}}),
        )
        .await;
        assert_eq!(websocket_json(&mut subscribed).await["type"], "subscribed");
        assert_eq!(websocket_json(&mut subscribed).await["type"], "snapshot");
        let reader_guard = state.reader.lock().await;
        socket_send(
            &mut subscribed,
            serde_json::json!({"v":1,"type":"subscribe","id":"pending","kind":"usage.overview","query":{}}),
        )
        .await;
        assert_eq!(websocket_json(&mut subscribed).await["type"], "subscribed");
        assert_eq!(state.active_sessions.lock().await.len(), 2);

        shutdown.send(()).expect("shutdown");
        wait_for_active_sessions(&state, 0).await;
        drop(reader_guard);
        tokio::time::timeout(Duration::from_secs(2), serve)
            .await
            .expect("serve drains sockets")
            .expect("serve task")
            .expect("serve result");
        assert!(state.active_sessions.lock().await.is_empty());
        assert!(
            state.reader.lock().await.is_none(),
            "reader closed before storage teardown"
        );

        let _ = preauth
            .send(tokio_tungstenite::tungstenite::Message::Text(
                serde_json::json!({"v":1,"type":"auth","token":"fake-control-token"})
                    .to_string()
                    .into(),
            ))
            .await;
        let _ = subscribed
            .send(tokio_tungstenite::tungstenite::Message::Text(
                serde_json::json!({"v":1,"type":"subscribe","id":"after","kind":"usage.overview","query":{}})
                    .to_string()
                    .into(),
            ))
            .await;
        for socket in [&mut preauth, &mut subscribed] {
            let next = tokio::time::timeout(Duration::from_secs(2), socket.next())
                .await
                .expect("shutdown closes socket");
            assert!(
                matches!(
                    next,
                    None | Some(Err(_) | Ok(tokio_tungstenite::tungstenite::Message::Close(_)))
                ),
                "no hello or new snapshot after shutdown: {next:?}"
            );
        }
    }

    async fn wait_for_active_sessions(state: &ControlState, expected: usize) {
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if state.active_sessions.lock().await.len() == expected {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("active session cleanup deadline");
    }

    #[tokio::test]
    async fn real_auth_rejects_non_auth_frames_and_invalid_tokens_without_hello() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, state, shutdown, serve) = start_control(server);

        let mut subscribe_first = connect_control(&authority).await;
        socket_send(
            &mut subscribe_first,
            serde_json::json!({"v":1,"type":"subscribe","id":"x","kind":"usage.overview","query":{}}),
        )
        .await;
        let rejected = websocket_json(&mut subscribe_first).await;
        assert_eq!(rejected["type"], "error");
        assert_eq!(rejected["code"], "unauthorized");
        assert!(
            matches!(
                websocket_message(&mut subscribe_first).await,
                tokio_tungstenite::tungstenite::Message::Close(_)
            ),
            "subscribe before auth must close"
        );
        wait_for_active_sessions(&state, 0).await;

        let mut invalid_token = connect_control(&authority).await;
        socket_send(
            &mut invalid_token,
            serde_json::json!({"v":1,"type":"auth","token":"wrong-token"}),
        )
        .await;
        let rejected = websocket_json(&mut invalid_token).await;
        assert_eq!(rejected["type"], "error");
        assert_eq!(rejected["code"], "unauthorized");
        assert!(
            matches!(
                websocket_message(&mut invalid_token).await,
                tokio_tungstenite::tungstenite::Message::Close(_)
            ),
            "invalid token must close"
        );
        wait_for_active_sessions(&state, 0).await;

        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test]
    async fn real_auth_deadline_closes_silent_socket() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, state, shutdown, serve) = start_control(server);
        let mut socket = connect_control(&authority).await;

        let closed = tokio::time::timeout(Duration::from_secs(6), socket.next())
            .await
            .expect("auth deadline")
            .expect("auth stream")
            .expect("auth close");
        assert!(
            matches!(closed, tokio_tungstenite::tungstenite::Message::Close(_)),
            "silent auth must reach its five-second deadline"
        );
        wait_for_active_sessions(&state, 0).await;

        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test]
    async fn real_upgrade_rejects_bad_host_origin_and_subprotocol() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, _state, shutdown, serve) = start_control(server);

        let bad_host = rejected_control_upgrade(
            &authority,
            Some("evil.example"),
            Some(&format!("http://{authority}")),
            Some("airlock.v1"),
        )
        .await;
        assert_eq!(bad_host.0, StatusCode::FORBIDDEN);
        assert_eq!(bad_host.1["error"]["code"], "forbidden_host");

        let bad_origin = rejected_control_upgrade(
            &authority,
            Some(&authority),
            Some("http://evil.example"),
            Some("airlock.v1"),
        )
        .await;
        assert_eq!(bad_origin.0, StatusCode::FORBIDDEN);
        assert_eq!(bad_origin.1["error"]["code"], "forbidden_origin");

        let bad_protocol = rejected_control_upgrade(
            &authority,
            Some(&authority),
            Some(&format!("http://{authority}")),
            Some("airlock.v2"),
        )
        .await;
        assert_eq!(bad_protocol.0, StatusCode::CONFLICT);
        assert_eq!(bad_protocol.1["error"]["code"], "unsupported_version");

        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test(start_paused = true)]
    async fn real_ping_requires_its_exact_nonce() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, state, shutdown, serve) = start_control(server);
        let mut socket = connect_control(&authority).await;
        authenticate(&mut socket).await;

        tokio::time::advance(super::PING_INTERVAL).await;
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
        let ping = socket
            .next()
            .await
            .expect("ping stream")
            .expect("ping websocket")
            .into_text()
            .expect("ping text");
        let ping: serde_json::Value = serde_json::from_str(ping.as_ref()).expect("ping JSON");
        assert_eq!(ping["type"], "ping");
        socket_send(
            &mut socket,
            serde_json::json!({"v":1,"type":"pong","nonce":"wrong-nonce"}),
        )
        .await;
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
        let mut rejected_with_frame = false;
        let mut closed = false;
        for _ in 0..2 {
            match socket.next().await.expect("wrong pong stream") {
                Ok(tokio_tungstenite::tungstenite::Message::Text(text)) => {
                    let rejected: serde_json::Value =
                        serde_json::from_str(text.as_ref()).expect("rejection JSON");
                    assert_eq!(rejected["type"], "error");
                    assert_eq!(rejected["code"], "invalid_frame");
                    rejected_with_frame = true;
                }
                Ok(tokio_tungstenite::tungstenite::Message::Close(_))
                | Err(tokio_tungstenite::tungstenite::Error::Protocol(
                    tokio_tungstenite::tungstenite::error::ProtocolError::ResetWithoutClosingHandshake,
                )) => {
                    closed = true;
                    break;
                }
                other => panic!("unexpected wrong-pong response: {other:?}"),
            }
        }
        assert!(
            rejected_with_frame || closed,
            "wrong pong nonce must close the socket"
        );
        wait_for_active_sessions(&state, 0).await;

        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test(start_paused = true)]
    async fn real_ping_deadline_closes_missing_pong() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, state, shutdown, serve) = start_control(server);
        let mut socket = connect_control(&authority).await;
        authenticate(&mut socket).await;

        tokio::time::advance(super::PING_INTERVAL).await;
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
        let ping = socket
            .next()
            .await
            .expect("ping stream")
            .expect("ping websocket")
            .into_text()
            .expect("ping text");
        let ping: serde_json::Value = serde_json::from_str(ping.as_ref()).expect("ping JSON");
        assert_eq!(ping["type"], "ping");
        tokio::time::advance(super::PONG_TIMEOUT + Duration::from_secs(1)).await;
        let closed = tokio::time::timeout(Duration::from_secs(35), socket.next())
            .await
            .expect("pong deadline")
            .expect("pong stream");
        assert!(
            matches!(
                closed,
                Ok(tokio_tungstenite::tungstenite::Message::Close(_))
                    | Err(tokio_tungstenite::tungstenite::Error::Protocol(
                        tokio_tungstenite::tungstenite::error::ProtocolError::ResetWithoutClosingHandshake,
                    ))
            ),
            "missing pong must close"
        );
        wait_for_active_sessions(&state, 0).await;

        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test]
    async fn real_storage_gap_recovers_with_fresh_epoch_resnapshot() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, state, shutdown, serve) = start_control(server);
        state
            .test_query_failures
            .lock()
            .await
            .push_back("query_budget_exceeded");

        let mut socket = connect_control(&authority).await;
        authenticate(&mut socket).await;
        socket_send(
            &mut socket,
            serde_json::json!({
                "v":1, "type":"subscribe", "id":"overview",
                "kind":"usage.overview", "query":{}
            }),
        )
        .await;
        let subscribed = websocket_json(&mut socket).await;
        assert_eq!(subscribed["type"], "subscribed");
        let old_epoch = subscribed["epoch"].as_str().expect("old epoch").to_owned();

        let gap = websocket_json(&mut socket).await;
        assert_eq!(gap["type"], "gap");
        assert_eq!(gap["code"], "query_budget_exceeded");
        assert_eq!(gap["retryable"], true);
        assert_eq!(gap["action"], "retry");

        tokio::time::sleep(Duration::from_millis(5_100)).await;
        let transition = websocket_json(&mut socket).await;
        assert_eq!(transition["type"], "gap");
        assert_eq!(transition["action"], "resnapshot");
        assert_eq!(transition["epoch"], old_epoch);
        let snapshot = websocket_json(&mut socket).await;
        assert_eq!(snapshot["type"], "snapshot");
        assert_eq!(snapshot["seq"], 1);
        assert_ne!(snapshot["epoch"], old_epoch);

        socket.close(None).await.expect("close recovered socket");
        drop(socket);
        wait_for_active_sessions(&state, 0).await;
        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test(start_paused = true)]
    async fn flow_rejects_seventeenth_frame_and_accepts_cumulative_ack() {
        let flow = Arc::new(Flow::default());
        let frame_bytes = MAX_UNACKED_BYTES / MAX_UNACKED_FRAMES;
        for seq in 1..=MAX_UNACKED_FRAMES {
            flow.acquire("sub", "epoch", seq as u64, frame_bytes)
                .await
                .expect("credit budget");
        }
        let blocked = Arc::clone(&flow);
        let slow = tokio::spawn(async move {
            blocked
                .acquire("sub", "epoch", MAX_UNACKED_FRAMES as u64 + 1, frame_bytes)
                .await
                .expect_err("credit exhausted")
        });
        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(10)).await;
        tokio::task::yield_now().await;
        let slow = tokio::time::timeout(Duration::from_secs(1), slow)
            .await
            .expect("slow deadline")
            .expect("slow task");
        assert_eq!(slow["code"], "slow_consumer");
        assert_eq!(slow["action"], "resnapshot");
        flow.ack("sub", "epoch", MAX_UNACKED_FRAMES as u64)
            .await
            .expect("cumulative ack");
        {
            let state = flow.state.lock().await;
            assert!(state.unacked.is_empty());
            assert_eq!(state.total_bytes, 0);
        }
        flow.ack("sub", "epoch", MAX_UNACKED_FRAMES as u64)
            .await
            .expect("duplicate older ack");
        assert!(
            flow.ack("sub", "epoch", MAX_UNACKED_FRAMES as u64 + 1)
                .await
                .is_err()
        );
    }

    #[test]
    fn slow_consumer_close_is_1013() {
        let (sender, mut receiver) = mpsc::channel(2);
        let close = Notify::new();
        close_subscription(
            &sender,
            gap_frame("sub", "epoch", 0, "slow_consumer", false),
            &close,
        );
        let text = receiver.try_recv().expect("gap queued");
        let Outbound::Text(frame) = text else {
            panic!("expected gap");
        };
        assert_eq!(frame["code"], "slow_consumer");
        assert!(matches!(
            receiver.try_recv(),
            Ok(Outbound::Close(Some(1013)))
        ));
    }

    #[tokio::test]
    async fn repeated_epoch_retirement_releases_credit() {
        let flow = Flow::default();
        for _ in 0..100 {
            flow.acquire("widget", "epoch", 1, 10)
                .await
                .expect("fresh credit");
            {
                let state = flow.state.lock().await;
                assert_eq!(state.delivered.len(), 1);
            }
            flow.discard("widget").await;
            let state = flow.state.lock().await;
            assert!(state.delivered.is_empty());
            assert!(state.unacked.is_empty());
            assert_eq!(state.total_bytes, 0);
        }
    }

    #[tokio::test]
    async fn real_snapshot_ack_delta_keeps_closed_collections_and_sibling_alive() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, _state, shutdown, serve) = start_control(server);
        let mut socket = connect_control(&authority).await;
        authenticate(&mut socket).await;
        socket_send(
            &mut socket,
            serde_json::json!({
                "v":1,"type":"subscribe","id":"rows","kind":"requests.table",
                "query":{"limit":200,"window":{"last_seconds":3600}}
            }),
        )
        .await;
        assert_eq!(websocket_json(&mut socket).await["type"], "subscribed");
        let snapshot = websocket_json(&mut socket).await;
        assert_eq!(snapshot["type"], "snapshot");
        for _ in 0..2 {
            socket_send(
                &mut socket,
                serde_json::json!({
                    "v":1,"type":"ack","id":"rows","epoch":snapshot["epoch"],"seq":1
                }),
            )
            .await;
        }
        socket_send(
            &mut socket,
            serde_json::json!({
                "v":1,"type":"subscribe","id":"invalid","kind":"requests.table",
                "query":{"limit":200,"provider":"bad id","window":{"last_seconds":3600}}
            }),
        )
        .await;
        assert_eq!(websocket_json(&mut socket).await["type"], "subscribed");
        let error = websocket_json(&mut socket).await;
        assert_eq!(error["type"], "error");
        assert_eq!(error["id"], "invalid");
        assert_eq!(error["code"], "invalid_query");
        let delta = websocket_json(&mut socket).await;
        assert_eq!(delta["type"], "delta");
        assert_eq!(delta["id"], "rows");
        assert_eq!(delta["seq"], 2);
        assert_eq!(delta["prev_seq"], 1);
        assert_eq!(delta["upserts"], serde_json::json!({"requests":[]}));
        assert_eq!(delta["removes"], serde_json::json!({"requests":[]}));
        drop(socket);
        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test]
    async fn failed_upgrades_release_slots_before_valid_socket() {
        let (server, _directory, _web) = control_server_fixture().await;
        let state = server.state.clone();
        let authority = server.local_addr().to_string();
        for _ in 0..super::MAX_SESSIONS + 2 {
            let mut request = Request::get("/api/v1/live")
                .header(header::HOST, &authority)
                .header(header::ORIGIN, format!("http://{authority}"))
                .header(header::CONNECTION, "upgrade")
                .header(header::UPGRADE, "websocket")
                .header(header::SEC_WEBSOCKET_KEY, "AAAAAAAAAAAAAAAAAAAAAA==")
                .header(header::SEC_WEBSOCKET_VERSION, "13")
                .header(header::SEC_WEBSOCKET_PROTOCOL, "airlock.v1")
                .body(axum::body::Body::empty())
                .expect("upgrade request");
            let failed = hyper::upgrade::on(&mut request);
            request.extensions_mut().insert(failed);
            let response = router(state.clone())
                .oneshot(request)
                .await
                .expect("upgrade response");
            assert_eq!(response.status(), StatusCode::SWITCHING_PROTOCOLS);
            wait_for_active_sessions(&state, 0).await;
        }
        let (authority, _state, shutdown, serve) = start_control(server);
        let mut socket = connect_control(&authority).await;
        authenticate(&mut socket).await;
        drop(socket);
        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test]
    async fn real_ack_refuses_unknown_owner_zero_and_future_sequence() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, state, shutdown, serve) = start_control(server);
        for (id, epoch, seq) in [
            ("unknown", "epoch", 0),
            ("rows", "unknown", 0),
            ("rows", "valid", 0),
            ("rows", "valid", 2),
        ] {
            let mut socket = connect_control(&authority).await;
            authenticate(&mut socket).await;
            socket_send(
                &mut socket,
                serde_json::json!({
                    "v":1,"type":"subscribe","id":"rows","kind":"usage.overview","query":{}
                }),
            )
            .await;
            websocket_json(&mut socket).await;
            let snapshot = websocket_json(&mut socket).await;
            let epoch = if epoch == "valid" {
                snapshot["epoch"].as_str().expect("epoch")
            } else {
                epoch
            };
            socket_send(
                &mut socket,
                serde_json::json!({"v":1,"type":"ack","id":id,"epoch":epoch,"seq":seq}),
            )
            .await;
            assert_eq!(websocket_json(&mut socket).await["code"], "invalid_frame");
            assert!(matches!(
                websocket_message(&mut socket).await,
                tokio_tungstenite::tungstenite::Message::Close(_)
            ));
            drop(socket);
            wait_for_active_sessions(&state, 0).await;
        }
        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test]
    async fn fixed_window_input_errors_are_terminal_and_leave_sibling_usable() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, _state, shutdown, serve) = start_control(server);
        let mut socket = connect_control(&authority).await;
        authenticate(&mut socket).await;
        for (index, (since, until, code)) in [
            (-60, 60, "invalid_query"),
            (0, 60, "invalid_query"),
            (i64::MIN, i64::MAX, "invalid_query"),
            (1, i64::MAX, "range_too_large"),
        ]
        .into_iter()
        .enumerate()
        {
            let id = format!("invalid-{index}");
            socket_send(
                &mut socket,
                serde_json::json!({
                    "v":1,"type":"subscribe","id":id,"kind":"requests.table",
                    "query":{"limit":10,"window":{"since_unix":since,"until_unix":until}}
                }),
            )
            .await;
            let error = websocket_json(&mut socket).await;
            assert_eq!(error["type"], "error");
            assert_eq!(error["id"], id);
            assert_eq!(error["code"], code);
            assert_eq!(error["retryable"], false);
        }
        socket_send(
            &mut socket,
            serde_json::json!({
                "v":1,"type":"subscribe","id":"valid","kind":"usage.overview","query":{}
            }),
        )
        .await;
        assert_eq!(websocket_json(&mut socket).await["type"], "subscribed");
        assert_eq!(websocket_json(&mut socket).await["type"], "snapshot");
        drop(socket);
        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test]
    async fn exact_size_malformed_control_fields_get_bounded_errors() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, state, shutdown, serve) = start_control(server);
        for mut frame in [
            serde_json::json!({"v":1,"type":"subscribe","id":"","kind":"usage.overview","query":{}}),
            serde_json::json!({"v":1,"type":"unsubscribe","id":""}),
            serde_json::json!({"v":1,"type":"ack","id":"","epoch":"e","seq":1}),
            serde_json::json!({"v":1,"type":"ack","id":"ok","epoch":"","seq":1}),
        ] {
            let empty_len = frame.to_string().len();
            let field = if frame["type"] == "ack" && frame["id"] == "ok" {
                &mut frame["epoch"]
            } else {
                &mut frame["id"]
            };
            *field = serde_json::Value::String("x".repeat(super::MAX_FRAME_BYTES - empty_len));
            assert_eq!(frame.to_string().len(), super::MAX_FRAME_BYTES);
            let mut socket = connect_control(&authority).await;
            authenticate(&mut socket).await;
            socket_send(&mut socket, frame).await;
            let error = websocket_json(&mut socket).await;
            assert_eq!(error["code"], "invalid_frame");
            assert!(error["id"].is_null());
            assert!(error.to_string().len() < 256);
            assert!(matches!(
                websocket_message(&mut socket).await,
                tokio_tungstenite::tungstenite::Message::Close(_)
            ));
            drop(socket);
            wait_for_active_sessions(&state, 0).await;
        }
        let mut sibling = connect_control(&authority).await;
        authenticate(&mut sibling).await;
        socket_send(&mut sibling, serde_json::json!({"v":1,"type":"subscribe","id":"ok","kind":"usage.overview","query":{}})).await;
        assert_eq!(websocket_json(&mut sibling).await["type"], "subscribed");
        assert_eq!(websocket_json(&mut sibling).await["type"], "snapshot");
        drop(sibling);
        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[test]
    fn retired_resume_fields_are_closed_and_wrong_version_is_explicit() {
        let subscribe = serde_json::json!({
            "v":1,"type":"subscribe","id":"rows","kind":"usage.overview","query":{},
            "resume":{"epoch":"e","after_seq":1}
        });
        assert_eq!(
            decode_client_frame(Message::Text(subscribe.to_string().into()))
                .expect_err("retired subscribe field"),
            "invalid_frame"
        );
        let auth = serde_json::json!({
            "v":1,"type":"auth","token":"fake-control-token","resume_session":"e"
        });
        assert_eq!(
            decode_client_frame(Message::Text(auth.to_string().into()))
                .expect_err("retired auth field"),
            "invalid_frame"
        );
        let version = serde_json::json!({
            "v":2,"type":"subscribe","id":"rows","kind":"usage.overview","query":{}
        });
        assert_eq!(
            decode_client_frame(Message::Text(version.to_string().into())).expect_err("version"),
            "unsupported_version"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn multiple_widgets_share_sixteen_frame_credit() {
        let flow = Arc::new(Flow::default());
        for seq in 1..=8 {
            for id in ["a", "b"] {
                flow.acquire(id, "epoch", seq, 1)
                    .await
                    .expect("session credit");
            }
        }
        let blocked = Arc::clone(&flow);
        let task = tokio::spawn(async move { blocked.acquire("a", "epoch", 9, 1).await });
        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(10)).await;
        assert_eq!(
            task.await
                .expect("blocked task")
                .expect_err("session limit")["code"],
            "slow_consumer"
        );
    }

    #[tokio::test]
    async fn wire_client_null_selects_unknown_rows_and_binds_cursor() {
        let (server, directory, _web) = control_server_fixture().await;
        let path = directory.path().join("airlock.sqlite3");
        let mut writer = sqlx::SqliteConnection::connect(&format!("sqlite://{}", path.display()))
            .await
            .expect("test writer");
        for client in [None, None, Some("harness")] {
            sqlx::query("INSERT INTO request_events (occurred_at_unix, client_id, group_id, credential_id, model_id, outcome, status_code, request_bytes, response_bytes, latency_ms, input_tokens, output_tokens, usage_complete, dropped_events) VALUES (?, ?, 'anthropic', 'claude', 'model', 'completed', 200, 1, 1, 1, 1, 1, 1, 0)")
                .bind(now_unix() - 1).bind(client).execute(&mut writer).await.expect("seed client rows");
        }
        writer.close().await.expect("close test writer");
        let (authority, _state, shutdown, serve) = start_control(server);
        let mut socket = connect_control(&authority).await;
        authenticate(&mut socket).await;
        for (id, client, expected) in [
            ("unknown", Some(Value::Null), 2),
            ("all", None, 3),
            ("known", Some(serde_json::json!("harness")), 1),
        ] {
            let mut query = serde_json::json!({"limit":200,"window":{"last_seconds":3600}});
            if let Some(client) = client {
                query["client"] = client;
            }
            socket_send(&mut socket, serde_json::json!({"v":1,"type":"subscribe","id":id,"kind":"requests.table","query":query})).await;
            assert_eq!(websocket_json(&mut socket).await["type"], "subscribed");
            let snapshot = websocket_json(&mut socket).await;
            assert_eq!(
                snapshot["collections"]["requests"]
                    .as_array()
                    .expect("rows")
                    .len(),
                expected
            );
        }
        let query: super::RequestsTableQuery = serde_json::from_value(
            serde_json::json!({"client":null,"limit":1,"window":{"last_seconds":3600}}),
        )
        .expect("nullable query");
        assert_eq!(query.client, Some(None));
        let cursor = super::RequestCursor::first(
            &query,
            airlock_core::storage::RequestRowCursor {
                cutoff_id: 3,
                occurred_at_unix: now_unix() - 1,
                row_id: 2,
            },
            now_unix() - 3600,
            now_unix(),
        );
        let encoded = super::cursor_string(&cursor).expect("cursor encoding");
        assert!(super::parse_cursor(&encoded, &query).is_some());
        let mut all = query;
        all.client = None;
        assert!(super::parse_cursor(&encoded, &all).is_none());
        drop(socket);
        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[tokio::test]
    async fn real_terminal_storage_errors_leave_valid_widget_usable() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, state, shutdown, serve) = start_control(server);
        let mut socket = connect_control(&authority).await;
        authenticate(&mut socket).await;
        for code in [
            "storage_corrupt",
            "range_too_large",
            "numeric_range_unsupported",
        ] {
            state.test_query_failures.lock().await.push_back(code);
            socket_send(&mut socket, serde_json::json!({"v":1,"type":"subscribe","id":code,"kind":"usage.overview","query":{}})).await;
            assert_eq!(websocket_json(&mut socket).await["type"], "subscribed");
            let error = websocket_json(&mut socket).await;
            assert_eq!(error["type"], "error");
            assert_eq!(error["code"], code);
        }
        socket_send(&mut socket, serde_json::json!({"v":1,"type":"subscribe","id":"valid","kind":"usage.overview","query":{}})).await;
        assert_eq!(websocket_json(&mut socket).await["type"], "subscribed");
        assert_eq!(websocket_json(&mut socket).await["type"], "snapshot");
        drop(socket);
        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }

    #[test]
    fn numeric_or_range_error_does_not_queue_connection_close() {
        for code in [
            "numeric_range_unsupported",
            "range_too_large",
            "storage_corrupt",
        ] {
            let (sender, mut receiver) = mpsc::channel(2);
            close_subscription(
                &sender,
                super::error_frame(Some("invalid"), code, false),
                &Notify::new(),
            );
            assert!(matches!(receiver.try_recv(), Ok(Outbound::Text(_))));
            assert!(receiver.try_recv().is_err());
        }
    }

    #[tokio::test]
    async fn real_series_metadata_delta_has_every_closed_collection() {
        let (server, _directory, _web) = control_server_fixture().await;
        let (authority, _state, shutdown, serve) = start_control(server);
        let mut socket = connect_control(&authority).await;
        authenticate(&mut socket).await;
        socket_send(&mut socket, serde_json::json!({
            "v":1,"type":"subscribe","id":"series","kind":"usage.series",
            "query":{"provider":"claude","credential":"claude","source":"out_of_band_fetch","surface":"claude_subscription","limit":1000,"window":{"last_seconds":3600}}
        })).await;
        assert_eq!(websocket_json(&mut socket).await["type"], "subscribed");
        let snapshot = websocket_json(&mut socket).await;
        socket_send(
            &mut socket,
            serde_json::json!({"v":1,"type":"ack","id":"series","epoch":snapshot["epoch"],"seq":1}),
        )
        .await;
        tokio::time::sleep(Duration::from_millis(5100)).await;
        let delta = websocket_json(&mut socket).await;
        assert_eq!(delta["type"], "delta");
        assert_eq!(
            delta["upserts"],
            serde_json::json!({"snapshots":[],"reset_events":[]})
        );
        assert_eq!(
            delta["removes"],
            serde_json::json!({"snapshots":[],"reset_events":[]})
        );
        drop(socket);
        shutdown.send(()).expect("shutdown");
        serve.await.expect("serve task").expect("serve clean");
    }
}

#[cfg(test)]
mod view_tests {
    use super::{
        QueryBody, ResetDimension, SubscriptionKind, SubscriptionQuery, ViewCollection, ViewKey,
        ViewState, data_frame,
    };
    use serde_json::{Value, json};

    fn series_query() -> SubscriptionQuery {
        SubscriptionQuery::new(
            SubscriptionKind::UsageSeries,
            QueryBody::UsageSeries(super::UsageSeriesQuery {
                credential: "claude".to_owned(),
                limit: 1000,
                provider: "claude".to_owned(),
                source: super::SnapshotSourceWire::OutOfBandFetch,
                surface: super::SnapshotSurfaceWire::ClaudeSubscription,
                window: super::Window::Rolling {
                    last_seconds: 86_400,
                },
            }),
        )
        .expect("series query")
    }

    fn snapshot_view(value: i64) -> ViewState {
        let mut view = ViewState::empty(series_query().kind());
        view.insert(
            ViewCollection::Snapshots,
            ViewKey::Snapshot { id: "1".to_owned() },
            json!({"value": value}),
        );
        view
    }

    #[test]
    fn snapshot_contains_every_permitted_collection_even_when_empty() {
        let view = ViewState::empty(series_query().kind());
        let frame = data_frame("snapshot", "history", "epoch", 1, None, &view, None);
        let collections = frame["collections"].as_object().expect("collections");
        assert_eq!(collections.len(), 2);
        assert!(collections.contains_key("snapshots"));
        assert!(collections.contains_key("reset_events"));
    }

    #[test]
    fn delta_contains_only_changed_rows_and_departed_rows() {
        let first = snapshot_view(1);
        let mut second = snapshot_view(2);
        second.insert(
            ViewCollection::ResetEvents,
            ViewKey::ResetEvent {
                current: "2".to_owned(),
                dimension: ResetDimension::Quota,
                kind: "utilization_drop".to_owned(),
                pool: "five_hour".to_owned(),
                preceding: "1".to_owned(),
            },
            json!({"kind":"utilization_drop"}),
        );
        let (upserts, removes) = first.diff(&second);
        assert_eq!(
            upserts[&ViewCollection::Snapshots],
            vec![(ViewKey::Snapshot { id: "1".to_owned() }, json!({"value":2}))]
        );
        assert_eq!(
            upserts[&ViewCollection::ResetEvents].len(),
            1,
            "the reset event is a new upsert"
        );
        assert!(removes.values().all(Vec::is_empty));

        let (upserts, removes) = second.diff(&first);
        let frame = data_frame(
            "delta",
            "history",
            "epoch",
            2,
            Some(1),
            &first,
            Some((&upserts, &removes)),
        );
        assert_eq!(
            frame["upserts"]["snapshots"].as_array().map(Vec::len),
            Some(1)
        );
        assert_eq!(
            frame["removes"]["reset_events"].as_array().map(Vec::len),
            Some(1)
        );
        assert_eq!(frame["removes"]["reset_events"][0]["reason"], "left_window");
        assert_eq!(frame["upserts"]["reset_events"], json!([]));
        let _: Value = frame;
    }
}

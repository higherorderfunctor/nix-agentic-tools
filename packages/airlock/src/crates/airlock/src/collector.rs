//! Scheduled, bounded quota collection. Provider payloads stay in memory and only typed
//! dimensions enter SQLite. Every failed attempt becomes a gap snapshot.

use std::{future::Future, net::SocketAddr, sync::Arc, time::Duration};

use airlock_core::{
    config::{Auth, Config, UsageCredential, UsageProviderKind},
    secret::Secret,
    storage::{
        ClaudeLimit, CreditPool, ProviderSnapshot, QuotaMetric, QuotaPool, SnapshotFetchStatus,
        SnapshotSource, SnapshotSurface, SqliteStorage, Storage,
    },
};
use http_body_util::{BodyExt, Full};
use hyper::{
    Request,
    body::Bytes,
    client::conn::http1,
    header::{AUTHORIZATION, HeaderValue},
};
use hyper_util::rt::TokioIo;
use rustls::{ClientConfig, RootCertStore, pki_types::ServerName};
use serde_json::Value;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use tokio::{net::TcpStream, time::timeout};
use tokio_rustls::TlsConnector;
use zeroize::Zeroizing;

const FETCH_CADENCE: Duration = Duration::from_secs(300);
const FETCH_DEADLINE: Duration = Duration::from_secs(25);
const RESPONSE_LIMIT: usize = 256 << 10;
const TOKEN_LIMIT: usize = 16 << 10;
pub const MAX_CREDENTIALS: usize = 64;

#[derive(Clone, Copy)]
struct Target {
    host: &'static str,
    path: &'static str,
    surface: SnapshotSurface,
}

fn target(kind: UsageProviderKind) -> Target {
    match kind {
        UsageProviderKind::Claude => Target {
            host: "api.anthropic.com",
            path: "/api/oauth/usage",
            surface: SnapshotSurface::ClaudeSubscription,
        },
        UsageProviderKind::Codex => Target {
            host: "chatgpt.com",
            path: "/backend-api/wham/usage",
            surface: SnapshotSurface::CodexRateLimits,
        },
        UsageProviderKind::Zai => Target {
            host: "api.z.ai",
            path: "/api/monitor/usage/quota/limit",
            surface: SnapshotSurface::ZaiQuota,
        },
    }
}

fn request(
    target: Target,
    kind: UsageProviderKind,
    token: &str,
    account_id: Option<&str>,
) -> Result<Request<Full<Bytes>>, &'static str> {
    let mut builder = Request::builder()
        .method("GET")
        .uri(target.path)
        .header("Host", target.host)
        .header("Accept", "application/json")
        .header("Accept-Encoding", "identity");
    let mut bearer = HeaderValue::from_str(&format!("Bearer {token}"))
        .map_err(|_| "invalid_credential_header")?;
    bearer.set_sensitive(true);
    builder = builder.header(AUTHORIZATION, bearer);
    builder = match kind {
        UsageProviderKind::Claude => builder.header("anthropic-beta", "oauth-2025-04-20"),
        UsageProviderKind::Codex => {
            let account = account_id.ok_or("codex_account_id_missing")?;
            builder.header("User-Agent", "codex-tui").header(
                "Chatgpt-Account-Id",
                HeaderValue::from_str(account).map_err(|_| "invalid_account_id_header")?,
            )
        }
        UsageProviderKind::Zai => builder.header("Accept-Language", "en-US,en"),
    };
    builder
        .body(Full::new(Bytes::new()))
        .map_err(|_| "invalid_usage_request")
}

async fn https_get(
    target: Target,
    request: Request<Full<Bytes>>,
    roots: &RootCertStore,
) -> Result<Zeroizing<Vec<u8>>, &'static str> {
    https_get_at(target, request, roots, None, FETCH_DEADLINE).await
}

async fn https_get_at(
    target: Target,
    request: Request<Full<Bytes>>,
    roots: &RootCertStore,
    connect_at: Option<SocketAddr>,
    deadline: Duration,
) -> Result<Zeroizing<Vec<u8>>, &'static str> {
    timeout(deadline, async {
        let config = ClientConfig::builder()
            .with_root_certificates(roots.clone())
            .with_no_client_auth();
        let connector = TlsConnector::from(Arc::new(config));
        let socket = if let Some(address) = connect_at {
            TcpStream::connect(address).await
        } else {
            TcpStream::connect((target.host, 443)).await
        }
        .map_err(|_| "usage_connect_failed")?;
        let name =
            ServerName::try_from(target.host.to_owned()).map_err(|_| "usage_host_invalid")?;
        let tls = connector
            .connect(name, socket)
            .await
            .map_err(|_| "usage_tls_failed")?;
        let (mut sender, connection) = http1::handshake(TokioIo::new(tls))
            .await
            .map_err(|_| "usage_handshake_failed")?;
        let task = tokio::spawn(async move {
            let _ = connection.await;
        });
        let response = sender
            .send_request(request)
            .await
            .map_err(|_| "usage_send_failed");
        let result = async {
            let mut response = response?;
            if !response.status().is_success() {
                return Err(match response.status().as_u16() {
                    401 | 403 => "usage_unauthorized",
                    429 => "usage_rate_limited",
                    _ => "usage_http_error",
                });
            }
            let mut body = Zeroizing::new(Vec::new());
            while let Some(frame) = response.body_mut().frame().await {
                let frame = frame.map_err(|_| "usage_body_failed")?;
                if let Ok(bytes) = frame.into_data() {
                    if bytes.len() > RESPONSE_LIMIT.saturating_sub(body.len()) {
                        return Err("usage_body_too_large");
                    }
                    body.extend_from_slice(&bytes);
                }
            }
            Ok(body)
        }
        .await;
        task.abort();
        result
    })
    .await
    .map_err(|_| "usage_timeout")?
}

fn unix_now() -> Result<i64, &'static str> {
    let now = OffsetDateTime::now_utc().unix_timestamp();
    (now > 0).then_some(now).ok_or("usage_clock_invalid")
}

fn percent_milli(value: &Value) -> Result<u64, &'static str> {
    let number = value.as_f64().ok_or("usage_schema_error")?;
    if !number.is_finite() || !(0.0..=100.0).contains(&number) {
        return Err("usage_schema_error");
    }
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    Ok((number * 1000.0).round() as u64)
}

fn date(value: &Value) -> Result<i64, &'static str> {
    if let Some(number) = value.as_i64() {
        return (number > 0).then_some(number).ok_or("usage_schema_error");
    }
    let text = value.as_str().ok_or("usage_schema_error")?;
    let parsed = OffsetDateTime::parse(text, &Rfc3339).map_err(|_| "usage_schema_error")?;
    Ok(parsed.unix_timestamp())
}

fn optional_date(object: &Value, field: &str) -> Result<Option<i64>, &'static str> {
    object
        .get(field)
        .filter(|value| !value.is_null())
        .map(date)
        .transpose()
}

fn nonnegative(value: &Value) -> Result<u64, &'static str> {
    value.as_u64().ok_or("usage_schema_error")
}

fn dollars_to_minor(value: &Value) -> Result<u64, &'static str> {
    let number = value.as_f64().ok_or("usage_schema_error")?;
    let minor = number * 100.0;
    if !minor.is_finite()
        || minor < 0.0
        || minor > 9_000_000_000_000_000.0
        || (minor - minor.round()).abs() > 0.000_01
    {
        return Err("usage_schema_error");
    }
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    Ok(minor.round() as u64)
}

fn optional_text(value: &Value, field: &str, max: usize) -> Result<Option<String>, &'static str> {
    value
        .get(field)
        .filter(|value| !value.is_null())
        .map(|value| {
            let text = value.as_str().ok_or("usage_schema_error")?;
            if text.is_empty() || text.len() > max || text.chars().any(char::is_control) {
                return Err("usage_schema_error");
            }
            Ok(text.to_owned())
        })
        .transpose()
}

fn partial_gap(snapshot: &mut ProviderSnapshot, label: &str) {
    snapshot.metrics.push(QuotaMetric {
        label: label.to_owned(),
        unit: "gap".to_owned(),
        value: 1,
    });
}

#[expect(
    clippy::too_many_lines,
    reason = "the four quota windows and two distinct credit contracts are projected together"
)]
fn parse_claude(value: &Value, snapshot: &mut ProviderSnapshot) -> Result<(), &'static str> {
    for field in [
        "five_hour",
        "seven_day",
        "seven_day_oauth_apps",
        "seven_day_opus",
        "seven_day_sonnet",
        "cinder_cove",
    ] {
        let Some(window) = value.get(field).filter(|value| !value.is_null()) else {
            continue;
        };
        window.as_object().ok_or("usage_schema_error")?;
        let utilization = window.get("utilization").ok_or("usage_schema_error")?;
        if utilization.is_null() {
            partial_gap(snapshot, &format!("{field}_utilization_unavailable"));
            continue;
        }
        let used = percent_milli(utilization)?;
        snapshot.pools.push(QuotaPool {
            label: field.to_owned(),
            limit: 100_000,
            reset_at_unix: optional_date(window, "resets_at")?,
            utilized: used,
        });
    }
    if let Some(extra) = value.get("extra_usage").filter(|value| !value.is_null()) {
        extra.as_object().ok_or("usage_schema_error")?;
        if let Some(enabled) = extra.get("is_enabled") {
            snapshot.metrics.push(QuotaMetric {
                label: "extra_usage_enabled".to_owned(),
                unit: "boolean".to_owned(),
                value: u64::from(enabled.as_bool().ok_or("usage_schema_error")?),
            });
        }
        if let (Some(limit), Some(used), Some(currency)) = (
            extra.get("monthly_limit").filter(|value| !value.is_null()),
            extra.get("used_credits").filter(|value| !value.is_null()),
            extra.get("currency").and_then(Value::as_str),
        ) {
            if currency.len() != 3 || !currency.bytes().all(|byte| byte.is_ascii_uppercase()) {
                return Err("usage_schema_error");
            }
            let limit = nonnegative(limit)?;
            let used = nonnegative(used)?;
            if limit > 0 {
                snapshot.credits.push(CreditPool {
                    label: format!("extra_usage_{currency}"),
                    limit_minor_units: limit,
                    remaining_minor_units: limit.saturating_sub(used),
                    reset_at_unix: None,
                    used_minor_units: used,
                });
            }
        } else {
            partial_gap(snapshot, "extra_usage_balance_unavailable");
        }
    }
    if let Some(credit) = value.get("wattle_ember").filter(|value| !value.is_null()) {
        credit.as_object().ok_or("usage_schema_error")?;
        let label = optional_text(credit, "label", 64)?;
        let money = ["limit_dollars", "used_dollars", "remaining_dollars"]
            .map(|field| {
                credit
                    .get(field)
                    .filter(|value| !value.is_null())
                    .map(dollars_to_minor)
                    .transpose()
            })
            .into_iter()
            .collect::<Result<Vec<_>, _>>()?;
        if let [Some(limit), Some(used), Some(remaining)] = money.as_slice() {
            if *limit > 0 && *used <= *limit && *remaining <= *limit {
                snapshot.credits.push(CreditPool {
                    label: label.map_or_else(
                        || "wattle_ember".to_owned(),
                        |label| format!("wattle_ember: {label}"),
                    ),
                    limit_minor_units: *limit,
                    remaining_minor_units: *remaining,
                    reset_at_unix: optional_date(credit, "resets_at")?,
                    used_minor_units: *used,
                });
            } else {
                partial_gap(snapshot, "wattle_ember_balance_unavailable");
            }
        } else {
            partial_gap(snapshot, "wattle_ember_balance_unavailable");
        }
        if let Some(periods) = credit.get("periods").filter(|value| !value.is_null()) {
            let periods = periods.as_array().ok_or("usage_schema_error")?;
            if periods.len() > 8 {
                return Err("usage_schema_error");
            }
            for (index, period) in periods.iter().enumerate() {
                for (field, label) in [("starts_at", "start"), ("ends_at", "end")] {
                    if let Some(at) = optional_date(period, field)? {
                        snapshot.metrics.push(QuotaMetric {
                            label: format!("wattle_ember_period_{index}_{label}"),
                            unit: "unix_seconds".to_owned(),
                            value: u64::try_from(at).map_err(|_| "usage_schema_error")?,
                        });
                    }
                }
            }
        }
    }
    if let Some(limits) = value.get("limits").filter(|value| !value.is_null()) {
        let limits = limits.as_array().ok_or("usage_schema_error")?;
        if limits.len() > 64 {
            return Err("usage_schema_error");
        }
        for limit in limits {
            limit.as_object().ok_or("usage_schema_error")?;
            let kind = optional_text(limit, "kind", 64)?.ok_or("usage_schema_error")?;
            let scope = limit.get("scope").filter(|value| !value.is_null());
            if let Some(scope) = scope {
                scope.as_object().ok_or("usage_schema_error")?;
            }
            let scoped_name = |field: &str| -> Result<Option<String>, &'static str> {
                let Some(value) = scope
                    .and_then(|scope| scope.get(field))
                    .filter(|value| !value.is_null())
                else {
                    return Ok(None);
                };
                value.as_object().ok_or("usage_schema_error")?;
                optional_text(value, "display_name", 128)
            };
            snapshot.claude_limits.push(ClaudeLimit {
                kind,
                group: optional_text(limit, "group", 64)?,
                percent_milli: percent_milli(limit.get("percent").ok_or("usage_schema_error")?)?,
                reset_at_unix: optional_date(limit, "resets_at")?,
                severity: optional_text(limit, "severity", 64)?,
                is_active: limit
                    .get("is_active")
                    .and_then(Value::as_bool)
                    .ok_or("usage_schema_error")?,
                model_display_name: scoped_name("model")?,
                surface_display_name: scoped_name("surface")?,
            });
        }
    }
    if !snapshot.has_typed_data() {
        return Err("usage_schema_error");
    }
    Ok(())
}

fn parse_zai(value: &Value, snapshot: &mut ProviderSnapshot) -> Result<(), &'static str> {
    if value.get("code").and_then(Value::as_i64) != Some(200) {
        return Err("usage_schema_error");
    }
    let data = value.get("data").ok_or("usage_schema_error")?;
    let limits = data
        .get("limits")
        .and_then(Value::as_array)
        .ok_or("usage_schema_error")?;
    if limits.len() > 64 {
        return Err("usage_schema_error");
    }
    let mut labels = std::collections::BTreeSet::new();
    for limit in limits {
        let unit = limit
            .get("unit")
            .and_then(Value::as_i64)
            .ok_or("usage_schema_error")?;
        if unit != 3 && unit != 6 {
            continue;
        }
        let number = limit
            .get("number")
            .and_then(Value::as_u64)
            .ok_or("usage_schema_error")?;
        if number == 0 || number > 1_000 {
            return Err("usage_schema_error");
        }
        let reset_ms = limit
            .get("nextResetTime")
            .and_then(Value::as_i64)
            .ok_or("usage_schema_error")?;
        if reset_ms <= 0 {
            return Err("usage_schema_error");
        }
        let label = format!("zai_{number}{}", if unit == 3 { "h" } else { "w" });
        if !labels.insert(label.clone()) {
            return Err("usage_schema_error");
        }
        snapshot.pools.push(QuotaPool {
            label,
            limit: 100_000,
            reset_at_unix: Some(reset_ms / 1000),
            utilized: percent_milli(limit.get("percentage").ok_or("usage_schema_error")?)?,
        });
    }
    if snapshot.pools.is_empty() {
        return Err("usage_schema_error");
    }
    if let Some(level) = data.get("level").filter(|value| !value.is_null()) {
        let level = level.as_u64().ok_or("usage_schema_error")?;
        if level > i64::MAX as u64 {
            return Err("usage_schema_error");
        }
        snapshot.metrics.push(QuotaMetric {
            label: "zai_level".to_owned(),
            unit: "level".to_owned(),
            value: level,
        });
    }
    Ok(())
}

fn parse_codex(value: &Value, snapshot: &mut ProviderSnapshot) -> Result<(), &'static str> {
    let window = value
        .get("rate_limit")
        .and_then(|item| item.get("primary_window"))
        .ok_or("usage_schema_error")?;
    snapshot.pools.push(QuotaPool {
        label: "codex_primary".to_owned(),
        limit: 100_000,
        reset_at_unix: optional_date(window, "reset_at")?,
        utilized: percent_milli(window.get("used_percent").ok_or("usage_schema_error")?)?,
    });
    Ok(())
}

fn blank_snapshot(
    credential: &UsageCredential,
    surface: SnapshotSurface,
    now: i64,
) -> ProviderSnapshot {
    ProviderSnapshot {
        account_id: credential
            .account_id
            .clone()
            .unwrap_or_else(|| credential.id.as_ref().to_owned()),
        client: credential.client.clone(),
        claude_limits: Vec::new(),
        credential: credential.id.clone(),
        credits: Vec::new(),
        fetched_at_unix: now,
        fetch_status: SnapshotFetchStatus::Success,
        gap_reason: None,
        group: credential.group.clone(),
        header_windows: Vec::new(),
        metrics: Vec::new(),
        pools: Vec::new(),
        provider: credential.provider.clone(),
        source: SnapshotSource::OutOfBandFetch,
        surface,
    }
}

fn gap(mut snapshot: ProviderSnapshot, reason: &'static str) -> ProviderSnapshot {
    snapshot.fetched_at_unix = unix_now().unwrap_or(snapshot.fetched_at_unix);
    snapshot.credits.clear();
    snapshot.claude_limits.clear();
    snapshot.metrics.clear();
    snapshot.pools.clear();
    snapshot.fetch_status = SnapshotFetchStatus::Gap;
    snapshot.gap_reason = Some(reason.to_owned());
    snapshot
}

async fn load_token(
    config: &Config,
    storage: &SqliteStorage,
    credential: &UsageCredential,
    now: i64,
) -> Result<Zeroizing<String>, &'static str> {
    match config.usage_auth(&credential.id) {
        Some(Auth::ApiKey { file } | Auth::OauthBearer { file }) => {
            let file = file.clone();
            tokio::task::spawn_blocking(move || {
                file.load_bounded_regular(TOKEN_LIMIT)
                    .map(Secret::into_value)
            })
            .await
            .map_err(|_| "credential_unavailable")?
            .map_err(|_| "credential_unavailable")
        }
        Some(Auth::OauthManaged) => {
            let client = credential.client.as_ref().ok_or("oauth_owner_missing")?;
            match storage
                .oauth_pair(client, &credential.id, &credential.provider)
                .await
            {
                Ok(pair) if pair.real_access_expires_at_unix > now.saturating_add(25) => {
                    Ok(Zeroizing::new(pair.real_access_token.as_str().to_owned()))
                }
                Ok(_) | Err(_) => Err("oauth_refresh_needed"),
            }
        }
        None => Err("credential_unavailable"),
    }
}

async fn collect_one(
    config: &Config,
    storage: &SqliteStorage,
    credential: &UsageCredential,
    roots: &RootCertStore,
    now: i64,
) -> ProviderSnapshot {
    let target = target(credential.provider_kind);
    let blank = blank_snapshot(credential, target.surface, now);
    let token = load_token(config, storage, credential, now).await;
    let Ok(token) = token else {
        return gap(blank, token.err().unwrap_or("credential_unavailable"));
    };
    let request = match request(
        target,
        credential.provider_kind,
        &token,
        credential.account_id.as_deref(),
    ) {
        Ok(request) => request,
        Err(reason) => return gap(blank, reason),
    };
    let body = match https_get(target, request, roots).await {
        Ok(body) => body,
        Err(reason) => return gap(blank, reason),
    };
    let Ok(value) = serde_json::from_slice::<Value>(&body) else {
        return gap(blank, "usage_schema_error");
    };
    let mut snapshot = blank;
    let parsed = match credential.provider_kind {
        UsageProviderKind::Claude => parse_claude(&value, &mut snapshot),
        UsageProviderKind::Codex => parse_codex(&value, &mut snapshot),
        UsageProviderKind::Zai => parse_zai(&value, &mut snapshot),
    };
    if let Err(reason) = parsed {
        return gap(snapshot, reason);
    }
    if airlock_core::storage::validate_provider_snapshot(&snapshot).is_err() {
        return gap(snapshot, "usage_schema_error");
    }
    let Ok(observed_at) = unix_now() else {
        return gap(snapshot, "usage_clock_invalid");
    };
    snapshot.fetched_at_unix = observed_at;
    snapshot
}

/// Runs one collection immediately, then every five minutes. A failed fetch never retries hot.
pub async fn run(config: Arc<Config>, storage: Arc<SqliteStorage>, roots: RootCertStore) {
    let credentials = config.usage_collector_credentials();
    if credentials.len() > MAX_CREDENTIALS {
        tracing::warn!("usage credential count exceeds collector bound");
        return;
    }
    run_cadence((), |()| {
        let credentials = &credentials;
        let config = &config;
        let storage = &storage;
        let roots = &roots;
        async move {
            for credential in credentials {
                if credential.provider_kind == UsageProviderKind::Codex
                    && !credential.explicit_usage_selection
                {
                    continue;
                }
                let Ok(now) = unix_now() else {
                    tracing::warn!("usage collector clock unavailable");
                    break;
                };
                let snapshot = match timeout(
                    FETCH_DEADLINE,
                    collect_one(config, storage, credential, roots, now),
                )
                .await
                {
                    Ok(snapshot) => snapshot,
                    Err(_) => gap(
                        blank_snapshot(credential, target(credential.provider_kind).surface, now),
                        "usage_timeout",
                    ),
                };
                storage.append_provider_snapshot_observed(snapshot).await;
                if credential.provider_kind == UsageProviderKind::Claude {
                    let console_gap = gap(
                        blank_snapshot(
                            credential,
                            SnapshotSurface::ConsoleBalance,
                            unix_now().unwrap_or(now),
                        ),
                        "console_balance_requires_ant_auth_login",
                    );
                    storage.append_provider_snapshot_observed(console_gap).await;
                }
            }
        }
    })
    .await;
}

async fn run_cadence<State, F, Fut>(mut state: State, mut cycle: F)
where
    F: FnMut(State) -> Fut,
    Fut: Future<Output = State>,
{
    let mut cadence = tokio::time::interval(FETCH_CADENCE);
    cadence.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        cadence.tick().await;
        state = cycle(state).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    use hyper::{
        Response, body::Incoming, server::conn::http1 as server_http1, service::service_fn,
    };
    use rcgen::{BasicConstraints, CertificateParams, IsCa, Issuer, KeyPair, KeyUsagePurpose};
    use rustls::{
        ServerConfig,
        pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer},
    };
    use serde_json::json;
    use tokio::{net::TcpListener, sync::oneshot};
    use tokio_rustls::TlsAcceptor;

    async fn fake_https(
        host: &str,
        status: u16,
        response_body: Vec<u8>,
        delay: Duration,
    ) -> (
        SocketAddr,
        RootCertStore,
        oneshot::Receiver<(String, String, String)>,
        tokio::task::JoinHandle<()>,
    ) {
        let ca_key = KeyPair::generate().expect("fake CA key");
        let mut ca_params = CertificateParams::new(Vec::new()).expect("fake CA params");
        ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        ca_params.key_usages = vec![KeyUsagePurpose::KeyCertSign];
        let ca_cert = ca_params
            .self_signed(&ca_key)
            .expect("fake CA")
            .der()
            .clone();
        let issuer = Issuer::new(ca_params, ca_key);
        let key = KeyPair::generate().expect("fake server key");
        let leaf = CertificateParams::new(vec![host.to_owned()])
            .expect("fake leaf")
            .signed_by(&key, &issuer)
            .expect("signed leaf");
        let server = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                vec![leaf.der().clone()],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der())),
            )
            .expect("fake TLS server");
        let mut roots = RootCertStore::empty();
        roots.add(ca_cert).expect("test root");
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("fake loopback listener");
        let address = listener.local_addr().expect("fake loopback address");
        let (sent, received) = oneshot::channel();
        let sender = Arc::new(Mutex::new(Some(sent)));
        let task = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.expect("fake accept");
            let tls = TlsAcceptor::from(Arc::new(server))
                .accept(socket)
                .await
                .expect("fake TLS accept");
            let service = service_fn(move |request: Request<Incoming>| {
                let sender = Arc::clone(&sender);
                let body = response_body.clone();
                async move {
                    let observed = (
                        request.uri().path().to_owned(),
                        request.headers()["Host"].to_str().expect("host").to_owned(),
                        request.headers()[AUTHORIZATION]
                            .to_str()
                            .expect("fake auth")
                            .to_owned(),
                    );
                    if let Some(sender) = sender.lock().expect("sender lock").take() {
                        let _ = sender.send(observed);
                    }
                    tokio::time::sleep(delay).await;
                    let response = Response::builder()
                        .status(status)
                        .header("Location", "https://evil.invalid/steal")
                        .body(Full::new(Bytes::from(body)))
                        .expect("fake response");
                    Ok::<_, std::convert::Infallible>(response)
                }
            });
            let _ = server_http1::Builder::new()
                .serve_connection(TokioIo::new(tls), service)
                .await;
        });
        (address, roots, received, task)
    }

    #[tokio::test]
    async fn cadence_skips_missed_ticks_and_stops_on_shutdown() {
        tokio::time::pause();
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        let task = tokio::spawn(run_cadence(0_u32, move |cycle| {
            let sender = sender.clone();
            async move {
                sender.send(cycle).expect("cycle receiver");
                if cycle == 1 {
                    tokio::time::sleep(Duration::from_secs(650)).await;
                }
                cycle + 1
            }
        }));
        assert_eq!(receiver.recv().await, Some(0));
        tokio::time::advance(Duration::from_secs(299)).await;
        assert!(
            receiver.try_recv().is_err(),
            "failed cycle must not retry hot"
        );
        tokio::time::advance(Duration::from_secs(1)).await;
        assert_eq!(receiver.recv().await, Some(1));
        tokio::time::advance(Duration::from_secs(650)).await;
        tokio::task::yield_now().await;
        assert!(
            receiver.try_recv().is_err(),
            "slow cycle must skip missed ticks"
        );
        tokio::time::advance(Duration::from_secs(250)).await;
        assert_eq!(receiver.recv().await, Some(2));
        task.abort();
        assert!(task.await.expect_err("abort should cancel").is_cancelled());
        tokio::time::advance(Duration::from_secs(600)).await;
        assert!(
            receiver.try_recv().is_err(),
            "shutdown must stop future cycles"
        );
    }

    #[test]
    fn source_targets_and_auth_are_provider_specific() {
        for (kind, host, path) in [
            (
                UsageProviderKind::Claude,
                "api.anthropic.com",
                "/api/oauth/usage",
            ),
            (
                UsageProviderKind::Codex,
                "chatgpt.com",
                "/backend-api/wham/usage",
            ),
            (
                UsageProviderKind::Zai,
                "api.z.ai",
                "/api/monitor/usage/quota/limit",
            ),
        ] {
            let target = target(kind);
            let request = request(target, kind, "fake-provider-token", Some("fake-account"))
                .expect("request");
            assert_eq!(target.host, host);
            assert_eq!(request.uri().path(), path);
            assert_eq!(request.headers()["Host"], host);
            assert!(request.headers()[AUTHORIZATION].is_sensitive());
            assert_eq!(
                request.headers().contains_key("anthropic-beta"),
                kind == UsageProviderKind::Claude
            );
            assert_eq!(
                request.headers().contains_key("Chatgpt-Account-Id"),
                kind == UsageProviderKind::Codex
            );
            assert_eq!(
                request.headers().contains_key("Accept-Language"),
                kind == UsageProviderKind::Zai
            );
        }
    }

    #[test]
    #[expect(
        clippy::too_many_lines,
        reason = "one typed parser matrix checks valid families and invalid boundaries together"
    )]
    fn typed_schema_parsers_refuse_missing_and_invalid_capacity() {
        let mut snapshot = ProviderSnapshot {
            account_id: "fake-account".to_owned(),
            client: None,
            claude_limits: vec![],
            credential: airlock_core::ids::CredentialId::try_from("fake").expect("id"),
            credits: vec![],
            fetched_at_unix: 1,
            fetch_status: SnapshotFetchStatus::Success,
            gap_reason: None,
            group: None,
            header_windows: vec![],
            metrics: vec![],
            pools: vec![],
            provider: airlock_core::ids::ProviderId::try_from("fake").expect("id"),
            source: SnapshotSource::OutOfBandFetch,
            surface: SnapshotSurface::ClaudeSubscription,
        };
        assert!(parse_claude(&json!({}), &mut snapshot).is_err());
        parse_claude(&json!({"five_hour": {"utilization": 42.5, "resets_at": "2026-10-25T12:00:00Z"},
            "extra_usage": {"is_enabled": true, "monthly_limit": 20000, "used_credits": 1000, "currency": "USD"},
            "wattle_ember": {"label": "Fable Credit", "limit_dollars": 200, "used_dollars": 10, "remaining_dollars": 190}}), &mut snapshot).expect("claude");
        assert_eq!(snapshot.pools[0].utilized, 42_500);
        assert_eq!(snapshot.credits.len(), 2);
        assert_eq!(snapshot.credits[0].label, "extra_usage_USD");
        assert_eq!(snapshot.credits[1].label, "wattle_ember: Fable Credit");
        snapshot.pools.clear();
        snapshot.credits.clear();
        snapshot.metrics.clear();
        parse_claude(
            &json!({
                "five_hour": {"utilization": 20, "resets_at": null},
                "seven_day": {"utilization": null},
                "seven_day_oauth_apps": {"utilization": 100},
                "cinder_cove": {"utilization": 100},
                "wattle_ember": {"label": null, "limit_dollars": null,
                    "used_dollars": null, "remaining_dollars": null, "periods": null},
                "limits": [{"kind": "rate", "group": "models", "percent": 100,
                    "resets_at": null, "severity": "warning", "is_active": true,
                    "scope": {"model": {"display_name": "fake-model"},
                        "surface": {"display_name": "fake-surface"}}}]
            }),
            &mut snapshot,
        )
        .expect("nullable Claude fields");
        assert_eq!(snapshot.pools.len(), 3);
        assert!(
            snapshot
                .metrics
                .iter()
                .any(|metric| metric.label == "seven_day_utilization_unavailable")
        );
        assert!(
            snapshot
                .metrics
                .iter()
                .any(|metric| metric.label == "wattle_ember_balance_unavailable")
        );
        assert_eq!(
            snapshot.claude_limits[0].model_display_name.as_deref(),
            Some("fake-model")
        );
        assert_eq!(
            snapshot.claude_limits[0].surface_display_name.as_deref(),
            Some("fake-surface")
        );
        assert_eq!(snapshot.claude_limits[0].percent_milli, 100_000);
        for (name, payload) in [
            ("quota", json!({"five_hour": {"utilization": 42}})),
            (
                "credit",
                json!({"five_hour": null, "seven_day": null,
                "wattle_ember": {"label": "Fable Credit", "limit_dollars": 200,
                    "used_dollars": 10, "remaining_dollars": 190, "periods": null}}),
            ),
            (
                "scoped limit",
                json!({"limits": [{"kind": "rate", "percent": 100,
                "is_active": true, "scope": {"model": {"display_name": "fake-model"}}}]}),
            ),
        ] {
            snapshot.pools.clear();
            snapshot.credits.clear();
            snapshot.metrics.clear();
            snapshot.claude_limits.clear();
            parse_claude(&payload, &mut snapshot).expect(name);
            airlock_core::storage::validate_provider_snapshot(&snapshot).expect(name);
            assert!(
                snapshot.has_typed_data(),
                "{name} must retain its typed data"
            );
            if name == "credit" {
                assert!(
                    snapshot.pools.is_empty(),
                    "credit does not invent quota capacity"
                );
                assert_eq!(snapshot.credits.len(), 1);
            }
        }
        snapshot.pools.clear();
        snapshot.credits.clear();
        snapshot.metrics.clear();
        snapshot.claude_limits.clear();
        assert!(
            parse_claude(
                &json!({"five_hour": null, "seven_day": null,
            "wattle_ember": null, "limits": null}),
                &mut snapshot
            )
            .is_err()
        );
        assert!(
            parse_claude(
                &json!({"wattle_ember": {"label": 5,
            "limit_dollars": 200, "used_dollars": 10,
            "remaining_dollars": 190}}),
                &mut snapshot
            )
            .is_err()
        );
        assert!(parse_zai(&json!({"code": 200, "data": {"limits": []}}), &mut snapshot).is_err());
        parse_zai(
            &json!({"code": 200, "data": {"limits": [{"unit": 3, "number": 5,
            "percentage": 100, "nextResetTime": 1_790_000_000_000_i64}]}}),
            &mut snapshot,
        )
        .expect("zai");
        assert_eq!(snapshot.pools[0].utilized, 100_000);
        snapshot.pools.clear();
        assert!(parse_zai(&json!({"code": 200, "data": {"limits": [
            {"unit": 3, "number": 5, "percentage": 20, "nextResetTime": 1_790_000_000_000_i64},
            {"unit": 3, "number": 5, "percentage": 20, "nextResetTime": 1_790_000_000_000_i64}
        ]}}), &mut snapshot).is_err());
        snapshot.pools.clear();
        assert!(parse_zai(&json!({"code": 200, "data": {"level": u64::MAX, "limits": [
            {"unit": 3, "number": 5, "percentage": 20, "nextResetTime": 1_790_000_000_000_i64}
        ]}}), &mut snapshot).is_err());
        snapshot.pools.clear();
        parse_codex(
            &json!({"rate_limit": {"primary_window": {"used_percent": 7,
            "reset_at": 1_790_000_000}}}),
            &mut snapshot,
        )
        .expect("codex");
        assert_eq!(snapshot.pools[0].utilized, 7_000);
    }

    #[tokio::test]
    #[expect(
        clippy::too_many_lines,
        reason = "one fake TLS fixture checks each provider and all transport failure modes"
    )]
    async fn fake_provider_transport_is_bound_to_host_path_auth_and_budgets() {
        for kind in [
            UsageProviderKind::Claude,
            UsageProviderKind::Codex,
            UsageProviderKind::Zai,
        ] {
            let target = target(kind);
            let (address, roots, observed, task) =
                fake_https(target.host, 200, b"{}".to_vec(), Duration::ZERO).await;
            let token = format!("fake-{}-only", target.host);
            let request =
                request(target, kind, &token, Some("fake-account")).expect("fake request");
            let body = https_get_at(
                target,
                request,
                &roots,
                Some(address),
                Duration::from_secs(2),
            )
            .await
            .expect("fake response");
            assert_eq!(body.as_slice(), b"{}");
            let (path, host, authorization) = observed.await.expect("request received");
            assert_eq!(path, target.path);
            assert_eq!(host, target.host);
            assert_eq!(authorization, format!("Bearer {token}"));
            task.await.expect("fake server task");
        }

        let target = target(UsageProviderKind::Zai);
        let (address, roots, observed, task) =
            fake_https(target.host, 302, Vec::new(), Duration::ZERO).await;
        let redirect_request =
            request(target, UsageProviderKind::Zai, "fake-zai-only", None).expect("request");
        assert_eq!(
            https_get_at(
                target,
                redirect_request,
                &roots,
                Some(address),
                Duration::from_secs(2)
            )
            .await
            .err(),
            Some("usage_http_error")
        );
        assert_eq!(observed.await.expect("redirect request").0, target.path);
        task.await.expect("redirect server");

        let (address, roots, observed, task) =
            fake_https(target.host, 401, Vec::new(), Duration::ZERO).await;
        let unauthorized_request =
            request(target, UsageProviderKind::Zai, "fake-zai-only", None).expect("request");
        assert_eq!(
            https_get_at(
                target,
                unauthorized_request,
                &roots,
                Some(address),
                Duration::from_secs(2)
            )
            .await
            .err(),
            Some("usage_unauthorized")
        );
        assert_eq!(observed.await.expect("unauthorized request").0, target.path);
        task.await.expect("unauthorized server");

        let (address, roots, _, task) = fake_https(
            target.host,
            200,
            vec![b'x'; RESPONSE_LIMIT + 1],
            Duration::ZERO,
        )
        .await;
        let oversized_request =
            request(target, UsageProviderKind::Zai, "fake-zai-only", None).expect("request");
        assert_eq!(
            https_get_at(
                target,
                oversized_request,
                &roots,
                Some(address),
                Duration::from_secs(2)
            )
            .await
            .err(),
            Some("usage_body_too_large")
        );
        task.await.expect("oversized server");

        let (address, roots, _, task) =
            fake_https(target.host, 200, b"{}".to_vec(), Duration::from_millis(200)).await;
        let timeout_request =
            request(target, UsageProviderKind::Zai, "fake-zai-only", None).expect("request");
        assert_eq!(
            https_get_at(
                target,
                timeout_request,
                &roots,
                Some(address),
                Duration::from_millis(25)
            )
            .await
            .err(),
            Some("usage_timeout")
        );
        task.await.expect("timeout server");
    }

    #[tokio::test]
    async fn managed_primary_collection_uses_replaced_real_token_and_refuses_expiry() {
        use airlock_core::{
            config::RawConfig,
            storage::{OauthPairReplacement, TokenMaterial},
        };
        fn token(name: &str) -> TokenMaterial {
            TokenMaterial::new(format!("fake-{name}-token")).expect("fake token")
        }
        let directory = tempfile::tempdir().expect("private scratch");
        let value = json!({
            "clients": {"harness": {"grants": ["anthropic"], "token_file": "/run/fake-client-token"}},
            "credentials": {"claude": {"auth": {"type": "oauth_managed"}, "provider": "claude"}},
            "groups": {"anthropic": {"intercept": ["api.anthropic.com", "platform.claude.com"],
                "members": {"claude": {"models": []}}, "primary": "claude", "protocol": "anthropic"}},
            "listen": "127.0.0.1:0", "providers": {"claude": {"preset": "claude"}},
            "state_dir": directory.path().join("state"),
        });
        let raw: RawConfig = serde_json::from_value(value).expect("fake config JSON");
        let config = Config::try_from(raw).expect("fake managed config");
        let storage = SqliteStorage::open(config.state_dir(), config.storage_identities(1_000))
            .await
            .expect("scratch storage");
        let credential = config
            .usage_credentials()
            .into_iter()
            .next()
            .expect("primary");
        let pair = |generation, name: &str, expiry| OauthPairReplacement {
            client: credential.client.clone().expect("owner"),
            credential: credential.id.clone(),
            expected_generation: generation,
            fake_access_token: token(&format!("access-{name}")),
            fake_access_expires_at_unix: expiry,
            fake_refresh_token: token(&format!("refresh-{name}")),
            real_access_token: token(&format!("real-access-{name}")),
            real_access_expires_at_unix: expiry,
            real_refresh_token: token(&format!("real-refresh-{name}")),
            real_refresh_expires_at_unix: None,
            updated_at_unix: 1_000,
        };
        let old = storage
            .replace_oauth_pair(pair(0, "old", 2_000))
            .await
            .expect("first pair");
        assert_eq!(
            load_token(&config, &storage, &credential, 1_000)
                .await
                .expect("real token")
                .as_str(),
            "fake-real-access-old-token"
        );
        assert_eq!(
            load_token(&config, &storage, &credential, 1_976)
                .await
                .err(),
            Some("oauth_refresh_needed")
        );
        storage
            .replace_oauth_pair(pair(old.generation, "new", 3_000))
            .await
            .expect("replacement");
        assert_eq!(
            load_token(&config, &storage, &credential, 1_976)
                .await
                .expect("new real token")
                .as_str(),
            "fake-real-access-new-token"
        );
        storage.close().await.expect("close scratch storage");
    }

    #[tokio::test]
    async fn failed_snapshot_write_is_counted_after_recovery() {
        use airlock_core::{config::RawConfig, storage::ReadOnlyStorage};
        let directory = tempfile::tempdir().expect("private scratch");
        let raw: RawConfig = serde_json::from_value(json!({
            "clients": {"harness": {"grants": ["anthropic"], "token_file": "/run/fake-client"}},
            "credentials": {"zai": {"auth": {"type": "api_key", "file": "/run/fake-provider"}, "provider": "zai"}},
            "groups": {"anthropic": {"intercept": ["api.anthropic.com"],
                "members": {"zai": {"models": []}}, "primary": "zai", "protocol": "anthropic"}},
            "listen": "127.0.0.1:0", "providers": {"zai": {"preset": "zai"}},
            "state_dir": directory.path().join("state")
        })).expect("fake config JSON");
        let config = Config::try_from(raw).expect("fake config");
        let storage = SqliteStorage::open(config.state_dir(), config.storage_identities(100))
            .await
            .expect("scratch storage");
        let credential = config
            .usage_credentials()
            .into_iter()
            .next()
            .expect("credential");
        storage
            .append_provider_snapshot_observed(blank_snapshot(
                &credential,
                SnapshotSurface::ZaiQuota,
                100,
            ))
            .await;
        storage
            .append_provider_snapshot_observed(gap(
                blank_snapshot(&credential, SnapshotSurface::ZaiQuota, 101),
                "usage_schema_error",
            ))
            .await;
        let mut reader = ReadOnlyStorage::open(config.state_dir())
            .await
            .expect("reader");
        assert_eq!(
            reader
                .provider_snapshot_loss_total()
                .await
                .expect("loss total"),
            1
        );
        storage.close().await.expect("close storage");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn fifo_token_returns_a_gap_before_any_provider_request() {
        use airlock_core::config::RawConfig;
        let directory = tempfile::tempdir().expect("private scratch");
        let fifo = directory.path().join("fake-token-fifo");
        assert!(
            std::process::Command::new("mkfifo")
                .arg(&fifo)
                .status()
                .expect("mkfifo")
                .success()
        );
        let raw: RawConfig = serde_json::from_value(json!({
            "clients": {},
            "credentials": {"codex": {"account_id": "fake-account",
                "auth": {"type": "oauth_bearer", "file": fifo}, "provider": "codex"}},
            "groups": {}, "listen": "127.0.0.1:0",
            "providers": {"codex": {"preset": "codex"}},
            "state_dir": directory.path().join("state"),
            "usage": {"credentials": ["codex"]}
        }))
        .expect("fake config JSON");
        let config = Config::try_from(raw).expect("fake Codex config");
        let storage = SqliteStorage::open(config.state_dir(), config.storage_identities(100))
            .await
            .expect("scratch storage");
        let credential = config
            .usage_credentials()
            .into_iter()
            .next()
            .expect("credential");
        let result = tokio::time::timeout(
            Duration::from_secs(2),
            collect_one(&config, &storage, &credential, &RootCertStore::empty(), 100),
        )
        .await
        .expect("FIFO collection must finish");
        assert_eq!(result.fetch_status, SnapshotFetchStatus::Gap);
        assert_eq!(result.gap_reason.as_deref(), Some("credential_unavailable"));
        storage.close().await.expect("close storage");
    }
}

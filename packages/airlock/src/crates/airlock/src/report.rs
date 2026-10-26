//! Read-only, versioned usage report for delegate routing and human inspection.

use std::{collections::BTreeMap, future::Future, num::NonZeroU64};

use airlock_core::{
    config::{Config, CredentialAuthKind, UsageCredential, UsageProviderKind},
    ids::{CredentialId, ProviderId},
    storage::{
        ControlReader, ControlReport, IdentifiedSnapshot, ProviderSnapshot, ReadOnlyStorage,
        RequestOutcome, RequestUsageAggregate, RequestUsageQuery, SnapshotFetchStatus,
        SnapshotPage, SnapshotQuery, SnapshotSource, SnapshotSurface, StorageError,
    },
};
use serde_json::{Value, json};

const FRESH_SECONDS: i64 = 900;
const DEFAULT_HISTORY_LIMIT: u64 = 100;
const MAX_HISTORY_LIMIT: u64 = 1_000;

pub(crate) trait ReportReader {
    fn provider_snapshot_page(
        &mut self,
        query: SnapshotQuery,
    ) -> impl Future<Output = Result<SnapshotPage, StorageError>> + Send;

    fn latest_provider_snapshot(
        &mut self,
        provider: ProviderId,
        credential: CredentialId,
        source: SnapshotSource,
        surface: SnapshotSurface,
    ) -> impl Future<Output = Result<Option<ProviderSnapshot>, StorageError>> + Send;

    fn request_usage(
        &mut self,
        query: RequestUsageQuery,
    ) -> impl Future<Output = Result<Vec<RequestUsageAggregate>, StorageError>> + Send;

    fn request_usage_loss_total(
        &mut self,
    ) -> impl Future<Output = Result<u64, StorageError>> + Send;

    fn provider_snapshot_loss_total(
        &mut self,
    ) -> impl Future<Output = Result<u64, StorageError>> + Send;
}

impl ReportReader for ReadOnlyStorage {
    async fn provider_snapshot_page(
        &mut self,
        query: SnapshotQuery,
    ) -> Result<SnapshotPage, StorageError> {
        ReadOnlyStorage::provider_snapshot_page(self, query).await
    }

    async fn latest_provider_snapshot(
        &mut self,
        provider: ProviderId,
        credential: CredentialId,
        source: SnapshotSource,
        surface: SnapshotSurface,
    ) -> Result<Option<ProviderSnapshot>, StorageError> {
        ReadOnlyStorage::latest_provider_snapshot(self, provider, credential, source, surface).await
    }

    async fn request_usage(
        &mut self,
        query: RequestUsageQuery,
    ) -> Result<Vec<RequestUsageAggregate>, StorageError> {
        ReadOnlyStorage::request_usage(self, query).await
    }

    async fn request_usage_loss_total(&mut self) -> Result<u64, StorageError> {
        ReadOnlyStorage::request_usage_loss_total(self).await
    }

    async fn provider_snapshot_loss_total(&mut self) -> Result<u64, StorageError> {
        ReadOnlyStorage::provider_snapshot_loss_total(self).await
    }
}

impl ReportReader for ControlReport<'_> {
    async fn provider_snapshot_page(
        &mut self,
        query: SnapshotQuery,
    ) -> Result<SnapshotPage, StorageError> {
        ControlReport::report_provider_snapshot_page(self, query).await
    }

    async fn latest_provider_snapshot(
        &mut self,
        provider: ProviderId,
        credential: CredentialId,
        source: SnapshotSource,
        surface: SnapshotSurface,
    ) -> Result<Option<ProviderSnapshot>, StorageError> {
        ControlReport::report_latest_provider_snapshot(self, provider, credential, source, surface)
            .await
    }

    async fn request_usage(
        &mut self,
        query: RequestUsageQuery,
    ) -> Result<Vec<RequestUsageAggregate>, StorageError> {
        ControlReport::report_request_usage(self, query).await
    }

    async fn request_usage_loss_total(&mut self) -> Result<u64, StorageError> {
        ControlReport::report_request_usage_loss_total(self).await
    }

    async fn provider_snapshot_loss_total(&mut self) -> Result<u64, StorageError> {
        ControlReport::report_provider_snapshot_loss_total(self).await
    }
}

pub struct Options {
    pub bucket_seconds: NonZeroU64,
    pub history_limit: u64,
    pub since_unix: i64,
}

impl Options {
    pub fn validate(&self, now: i64) -> Result<(), &'static str> {
        if self.history_limit == 0 || self.history_limit > MAX_HISTORY_LIMIT {
            return Err("history limit must be 1..=1000");
        }
        if self.since_unix <= 0 || self.since_unix >= now {
            return Err("since-unix must be a positive past timestamp");
        }
        Ok(())
    }
}

pub fn default_history_limit() -> u64 {
    DEFAULT_HISTORY_LIMIT
}

fn surface(surface: SnapshotSurface) -> &'static str {
    match surface {
        SnapshotSurface::ClaudeSubscription => "claude_subscription",
        SnapshotSurface::CodexRateLimits => "codex_rate_limits",
        SnapshotSurface::ConsoleBalance => "console_balance",
        SnapshotSurface::ResponseHeaders => "response_headers",
        SnapshotSurface::ZaiQuota => "zai_quota",
    }
}

fn source(source: SnapshotSource) -> &'static str {
    match source {
        SnapshotSource::OutOfBandFetch => "out_of_band_fetch",
        SnapshotSource::ResponseHeaders => "response_headers",
    }
}

fn safe_gap(reason: Option<&str>) -> &'static str {
    match reason {
        Some("codex_account_id_missing") => "codex_account_id_missing",
        Some("console_balance_requires_ant_auth_login") => {
            "console_balance_requires_ant_auth_login"
        }
        Some("credential_unavailable") => "credential_unavailable",
        Some("invalid_account_id_header") => "invalid_account_id_header",
        Some("invalid_credential_header") => "invalid_credential_header",
        Some("oauth_owner_missing") => "oauth_owner_missing",
        Some("oauth_refresh_needed") => "oauth_refresh_needed",
        Some("usage_body_failed") => "usage_body_failed",
        Some("usage_body_too_large") => "usage_body_too_large",
        Some("usage_clock_invalid") => "usage_clock_invalid",
        Some("usage_connect_failed") => "usage_connect_failed",
        Some("usage_handshake_failed") => "usage_handshake_failed",
        Some("usage_http_error") => "usage_http_error",
        Some("usage_host_invalid") => "usage_host_invalid",
        Some("invalid_usage_request") => "invalid_usage_request",
        Some("usage_rate_limited") => "usage_rate_limited",
        Some("usage_schema_error") => "usage_schema_error",
        Some("usage_send_failed") => "usage_send_failed",
        Some("usage_timeout") => "usage_timeout",
        Some("usage_tls_failed") => "usage_tls_failed",
        Some("usage_unauthorized") => "usage_unauthorized",
        _ => "unknown_gap",
    }
}

fn status(snapshot: Option<&ProviderSnapshot>, now: i64) -> &'static str {
    let Some(snapshot) = snapshot else {
        return "unavailable";
    };
    if snapshot.fetch_status == SnapshotFetchStatus::Gap {
        return "unavailable";
    }
    if snapshot.pools.is_empty() {
        return "unavailable";
    }
    if now.saturating_sub(snapshot.fetched_at_unix) > FRESH_SECONDS {
        return "stale";
    }
    if snapshot
        .pools
        .iter()
        .any(|pool| global_pool(snapshot.surface, &pool.label) && pool.utilized >= pool.limit)
    {
        return "exhausted";
    }
    "fresh"
}

fn global_pool(surface: SnapshotSurface, label: &str) -> bool {
    surface != SnapshotSurface::ClaudeSubscription || matches!(label, "five_hour" | "seven_day")
}

fn global_quota_complete(snapshot: Option<&ProviderSnapshot>, kind: UsageProviderKind) -> bool {
    let Some(snapshot) = snapshot else {
        return false;
    };
    if snapshot.fetch_status == SnapshotFetchStatus::Gap {
        return false;
    }
    let required: &[&str] = match kind {
        UsageProviderKind::Claude => &["five_hour", "seven_day"],
        UsageProviderKind::Codex => &["codex_primary"],
        UsageProviderKind::Zai => &[],
    };
    required
        .iter()
        .all(|label| snapshot.pools.iter().any(|pool| pool.label == *label))
        && !snapshot.metrics.iter().any(|metric| {
            metric.unit == "gap"
                && (metric.label.starts_with("five_hour_")
                    || metric.label.starts_with("seven_day_utilization_"))
        })
}

pub(crate) fn known_gaps() -> Vec<Value> {
    vec![
        "claude_limit_ui_mapping_unverified".into(),
        "claude_credit_pool_rows_schema_unverified".into(),
        "claude_profile_subscription_metadata_unavailable".into(),
        "codex_secondary_window_schema_unverified".into(),
        "console_balance_requires_ant_auth_login".into(),
        "cpa_management_api_unsupported".into(),
    ]
}

pub(crate) fn snapshot_json(snapshot: &ProviderSnapshot, now: i64) -> Value {
    json!({
        "account_id": snapshot.account_id,
        "client": snapshot.client.as_ref().map(AsRef::as_ref),
        "claude_limits": snapshot.claude_limits.iter().map(|limit| json!({
            "kind": limit.kind, "group": limit.group, "percent_milli": limit.percent_milli,
            "reset_at_unix": limit.reset_at_unix, "severity": limit.severity,
            "is_active": limit.is_active, "scope": {
                "model_display_name": limit.model_display_name,
                "surface_display_name": limit.surface_display_name,
            },
        })).collect::<Vec<_>>(),
        "credential": snapshot.credential.as_ref(),
        "credits": snapshot.credits.iter().map(|credit| json!({
            "label": credit.label,
            "limit_minor_units": credit.limit_minor_units,
            "remaining_minor_units": credit.remaining_minor_units,
            "reset_at_unix": credit.reset_at_unix,
            "used_minor_units": credit.used_minor_units,
        })).collect::<Vec<_>>(),
        "fetched_at_unix": snapshot.fetched_at_unix,
        "gap_reason": (snapshot.fetch_status == SnapshotFetchStatus::Gap)
            .then(|| safe_gap(snapshot.gap_reason.as_deref())),
        "group": snapshot.group.as_ref().map(AsRef::as_ref),
        "header_windows": snapshot.header_windows.iter().map(|window| json!({
            "label": match window.label {
                airlock_core::storage::ResponseWindowLabel::FiveHour => "five_hour",
                airlock_core::storage::ResponseWindowLabel::SevenDay => "seven_day",
            },
            "reset_at_unix": window.reset_at_unix,
            "status": window.status.map(|status| match status {
                airlock_core::storage::ResponseWindowStatus::Allowed => "allowed",
                airlock_core::storage::ResponseWindowStatus::AllowedWarning => "allowed_warning",
                airlock_core::storage::ResponseWindowStatus::Rejected => "rejected",
            }),
            "utilization_milli": window.utilization_milli,
        })).collect::<Vec<_>>(),
        "metrics": snapshot.metrics.iter().map(|metric| json!({
            "label": metric.label, "unit": metric.unit, "value": metric.value,
        })).collect::<Vec<_>>(),
        "partial_gaps": snapshot.metrics.iter().filter(|metric| metric.unit == "gap")
            .map(|metric| metric.label.as_str()).collect::<Vec<_>>(),
        "pools": snapshot.pools.iter().map(|pool| json!({
            "label": pool.label, "limit": pool.limit, "remaining": pool.limit.saturating_sub(pool.utilized),
            "reset_at_unix": pool.reset_at_unix, "unit": "percent_milli", "utilized": pool.utilized,
        })).collect::<Vec<_>>(),
        "provider": snapshot.provider.as_ref(),
        "source": source(snapshot.source),
        "status": status(Some(snapshot), now),
        "surface": surface(snapshot.surface),
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum ResetDimension {
    Credit,
    Quota,
}

#[derive(Debug)]
pub(crate) struct IdentifiedResetEvent {
    pub current_snapshot_id: i64,
    pub dimension: ResetDimension,
    pub pool: String,
    pub preceding_snapshot_id: i64,
    pub value: Value,
}

#[derive(Debug)]
struct PriorPool {
    id: i64,
    value: u64,
    reset_at_unix: Option<i64>,
}

#[expect(
    clippy::too_many_lines,
    reason = "reset detection walks every typed quota, credit, metric, and limit pool together"
)]
pub(crate) fn identified_reset_events(
    snapshots: &[IdentifiedSnapshot],
) -> Vec<IdentifiedResetEvent> {
    let mut prior = BTreeMap::<(CredentialId, &'static str, String), PriorPool>::new();
    let mut prior_credits = BTreeMap::<(CredentialId, &'static str, String), PriorPool>::new();
    let mut events = Vec::new();
    for identified in snapshots {
        let snapshot = &identified.snapshot;
        let surface = surface(snapshot.surface);
        if snapshot.fetch_status == SnapshotFetchStatus::Gap {
            let gap_surface = surface;
            prior.retain(|(credential, prior_surface, _), _| {
                credential != &snapshot.credential || *prior_surface != gap_surface
            });
            prior_credits.retain(|(credential, prior_surface, _), _| {
                credential != &snapshot.credential || *prior_surface != gap_surface
            });
            continue;
        }
        for pool in &snapshot.pools {
            let key = (snapshot.credential.clone(), surface, pool.label.clone());
            let next = PriorPool {
                id: identified.id,
                value: pool.utilized,
                reset_at_unix: pool.reset_at_unix,
            };
            if let Some(previous) = prior.insert(key, next)
                && (pool.utilized < previous.value
                    || (previous.reset_at_unix.is_some()
                        && pool.reset_at_unix.is_some()
                        && previous.reset_at_unix != pool.reset_at_unix))
            {
                events.push(IdentifiedResetEvent {
                    current_snapshot_id: identified.id,
                    dimension: ResetDimension::Quota,
                    pool: pool.label.clone(),
                    preceding_snapshot_id: previous.id,
                    value: json!({
                        "credential": snapshot.credential.as_ref(),
                        "detected_at_unix": snapshot.fetched_at_unix,
                        "kind": if pool.utilized < previous.value {
                            "utilization_drop"
                        } else {
                            "reset_time_change"
                        },
                        "pool": pool.label,
                        "provider": snapshot.provider.as_ref(),
                        "reset_at_unix": pool.reset_at_unix,
                        "surface": surface,
                    }),
                });
            }
        }
        for credit in &snapshot.credits {
            let key = (snapshot.credential.clone(), surface, credit.label.clone());
            let next = PriorPool {
                id: identified.id,
                value: credit.remaining_minor_units,
                reset_at_unix: credit.reset_at_unix,
            };
            if let Some(previous) = prior_credits.insert(key, next)
                && (credit.remaining_minor_units > previous.value
                    || (previous.reset_at_unix.is_some()
                        && credit.reset_at_unix.is_some()
                        && previous.reset_at_unix != credit.reset_at_unix))
            {
                events.push(IdentifiedResetEvent {
                    current_snapshot_id: identified.id,
                    dimension: ResetDimension::Credit,
                    pool: credit.label.clone(),
                    preceding_snapshot_id: previous.id,
                    value: json!({
                        "credential": snapshot.credential.as_ref(),
                        "detected_at_unix": snapshot.fetched_at_unix,
                        "kind": if credit.remaining_minor_units > previous.value {
                            "credit_refill"
                        } else {
                            "reset_time_change"
                        },
                        "pool": credit.label,
                        "provider": snapshot.provider.as_ref(),
                        "reset_at_unix": credit.reset_at_unix,
                        "surface": surface,
                    }),
                });
            }
        }
        let observed_pools = snapshot
            .pools
            .iter()
            .map(|pool| pool.label.as_str())
            .collect::<std::collections::BTreeSet<_>>();
        prior.retain(|(credential, observed_surface, label), _| {
            credential != &snapshot.credential
                || *observed_surface != surface
                || observed_pools.contains(label.as_str())
        });
        let observed_credits = snapshot
            .credits
            .iter()
            .map(|credit| credit.label.as_str())
            .collect::<std::collections::BTreeSet<_>>();
        prior_credits.retain(|(credential, observed_surface, label), _| {
            credential != &snapshot.credential
                || *observed_surface != surface
                || observed_credits.contains(label.as_str())
        });
    }
    events
}

fn reset_events(snapshots: &[&ProviderSnapshot]) -> Vec<Value> {
    let identified = snapshots
        .iter()
        .enumerate()
        .map(|(index, snapshot)| IdentifiedSnapshot {
            id: i64::try_from(index).unwrap_or(0),
            snapshot: (*snapshot).clone(),
        })
        .collect::<Vec<_>>();
    identified_reset_events(&identified)
        .into_iter()
        .map(|event| event.value)
        .collect()
}

pub(crate) fn credential_json(
    credential: &UsageCredential,
    latest_fetch: Option<&ProviderSnapshot>,
    latest_header: Option<&ProviderSnapshot>,
    now: i64,
) -> Value {
    json!({
        "account_id": credential.account_id,
        "auth": match credential.auth {
            CredentialAuthKind::ApiKey => "api_key",
            CredentialAuthKind::OauthBearer => "oauth_bearer",
            CredentialAuthKind::OauthManaged => "oauth_managed",
        },
        "client": credential.client.as_ref().map(AsRef::as_ref),
        "credential": credential.id.as_ref(),
        "global_quota_complete": global_quota_complete(latest_fetch, credential.provider_kind),
        "explicit_usage_selection": credential.explicit_usage_selection,
        "group": credential.group.as_ref().map(AsRef::as_ref),
        "header_age_seconds": latest_header.map(|snapshot| now.saturating_sub(snapshot.fetched_at_unix)),
        "latest_fetch": latest_fetch.map(|snapshot| snapshot_json(snapshot, now)),
        "latest_header": latest_header.map(|snapshot| snapshot_json(snapshot, now)),
        "provider": credential.provider.as_ref(),
        "routes": credential.routes.iter().map(|route| json!({
            "client": route.client.as_ref(),
            "group": route.group.as_ref(),
            "models": route.models,
            "primary": route.primary,
            "protocol": route.protocol,
        })).collect::<Vec<_>>(),
        "status": status(latest_fetch, now),
        "surface": surface(target_surface(credential.provider_kind)),
    })
}

pub(crate) fn target_surface(kind: UsageProviderKind) -> SnapshotSurface {
    match kind {
        UsageProviderKind::Claude => SnapshotSurface::ClaudeSubscription,
        UsageProviderKind::Codex => SnapshotSurface::CodexRateLimits,
        UsageProviderKind::Zai => SnapshotSurface::ZaiQuota,
    }
}

pub(crate) fn aggregate_json(group: &str, value: &RequestUsageAggregate) -> Value {
    json!({
        "bucket_start_unix": value.bucket_start_unix,
        "cache_read_tokens": value.cache_read_tokens,
        "cache_write_tokens": value.cache_write_tokens,
        "client": value.client.as_ref().map(AsRef::as_ref),
        "complete_events": value.complete_events,
        "credential": value.credential.as_ref(),
        "error_events": value.error_events,
        "events": value.events,
        "group": group,
        "input_tokens": value.input_tokens,
        "latency_ms": value.latency_ms,
        "model": value.model,
        "outcome": match value.outcome {
            RequestOutcome::Cancelled => "cancelled", RequestOutcome::Completed => "completed",
            RequestOutcome::Failed => "failed", RequestOutcome::Rejected => "rejected",
        },
        "output_tokens": value.output_tokens,
        "provider": value.provider.as_ref(),
        "request_bytes": value.request_bytes,
        "response_bytes": value.response_bytes,
        "successful_events": value.successful_events,
    })
}

/// Reads and projects typed history; no credential file or OAuth table is touched.
pub(crate) async fn build_control(
    config: &Config,
    reader: &mut ControlReader,
    options: &Options,
    now: i64,
) -> Result<Value, StorageError> {
    let mut transaction = reader.report_transaction().await?;
    let result = build(config, &mut transaction, options, now).await;
    transaction.finish(result).await
}

#[expect(
    clippy::too_many_lines,
    reason = "the versioned report assembles bounded typed sections"
)]
pub(crate) async fn build(
    config: &Config,
    reader: &mut impl ReportReader,
    options: &Options,
    now: i64,
) -> Result<Value, airlock_core::storage::StorageError> {
    let credentials = config.usage_credentials();
    if credentials.len() > 64 {
        return Err(airlock_core::storage::StorageError::Input {
            field: "usage credential count exceeds 64",
        });
    }
    let providers = credentials
        .iter()
        .map(|credential| credential.provider.clone())
        .collect::<std::collections::BTreeSet<ProviderId>>();
    let mut snapshots = Vec::new();
    let mut history_truncated = false;
    for provider in providers {
        let page = reader
            .provider_snapshot_page(SnapshotQuery {
                limit: NonZeroU64::new(options.history_limit).ok_or(
                    airlock_core::storage::StorageError::Input {
                        field: "history limit is zero",
                    },
                )?,
                provider,
                since_unix: options.since_unix,
            })
            .await?;
        if snapshots.len() + page.snapshots.len() > 1_000 {
            return Err(airlock_core::storage::StorageError::SnapshotRangeIncomplete);
        }
        history_truncated |= page.truncated;
        snapshots.extend(page.snapshots);
    }
    snapshots.sort_by_key(|snapshot| snapshot.fetched_at_unix);
    let references = snapshots.iter().collect::<Vec<_>>();
    let mut credential_views = Vec::with_capacity(credentials.len());
    let route_count = credentials
        .iter()
        .map(|credential| credential.routes.len())
        .sum::<usize>();
    if route_count > 256 {
        return Err(airlock_core::storage::StorageError::Input {
            field: "usage route count exceeds 256",
        });
    }
    for credential in &credentials {
        let latest_fetch = reader
            .latest_provider_snapshot(
                credential.provider.clone(),
                credential.id.clone(),
                SnapshotSource::OutOfBandFetch,
                target_surface(credential.provider_kind),
            )
            .await?;
        let latest_header = reader
            .latest_provider_snapshot(
                credential.provider.clone(),
                credential.id.clone(),
                SnapshotSource::ResponseHeaders,
                SnapshotSurface::ResponseHeaders,
            )
            .await?;
        credential_views.push(credential_json(
            credential,
            latest_fetch.as_ref(),
            latest_header.as_ref(),
            now,
        ));
    }
    let mut aggregates = Vec::new();
    let groups = config.usage_groups();
    if groups.len() > 64 {
        return Err(airlock_core::storage::StorageError::Input {
            field: "usage group count exceeds 64",
        });
    }
    for group in groups {
        let usage = reader
            .request_usage(RequestUsageQuery {
                bucket_seconds: options.bucket_seconds,
                group: group.clone(),
                since_unix: options.since_unix,
                until_unix: now,
            })
            .await?;
        if aggregates.len() + usage.len() > 10_000 {
            return Err(airlock_core::storage::StorageError::UsageRangeIncomplete);
        }
        aggregates.extend(
            usage
                .iter()
                .map(|value| aggregate_json(group.as_ref(), value)),
        );
    }
    let lost = reader.request_usage_loss_total().await?;
    let provider_lost = reader.provider_snapshot_loss_total().await?;
    Ok(json!({
        "bucket_seconds": options.bucket_seconds.get(),
        "credentials": credential_views,
        "fresh_seconds": FRESH_SECONDS,
        "generated_at_unix": now,
        "history_oldest_at_unix": snapshots.first().map(|snapshot| snapshot.fetched_at_unix),
        "history_truncated": history_truncated,
        "known_gaps": known_gaps(),
        "provider_snapshot_loss_total": provider_lost,
        "request_loss_total": lost,
        "request_usage": aggregates,
        "reset_events": reset_events(&references),
        "reset_events_complete_since_unix": null,
        "reset_events_observed_only": true,
        "schema_version": 1,
        "since_unix": options.since_unix,
        "snapshots": snapshots.iter().map(|snapshot| snapshot_json(snapshot, now)).collect::<Vec<_>>(),
    }))
}

pub fn human(report: &Value) -> String {
    let mut lines = Vec::new();
    lines.push(format!(
        "airlock usage v1 at {}",
        report["generated_at_unix"]
    ));
    if let Some(credentials) = report["credentials"].as_array() {
        for credential in credentials {
            let provider = credential["provider"].as_str().unwrap_or("unknown");
            let id = credential["credential"].as_str().unwrap_or("unknown");
            let status = credential["status"].as_str().unwrap_or("unavailable");
            let at = credential["latest_fetch"]["fetched_at_unix"].as_i64();
            let reason = credential["latest_fetch"]["gap_reason"].as_str();
            lines.push(format!(
                "{provider}/{id}: {status} (observed {}, reason {})",
                at.map_or_else(|| "never".to_owned(), |value| value.to_string()),
                reason.unwrap_or("none")
            ));
            if let Some(fetch) = credential.get("latest_fetch") {
                for pool in fetch["pools"].as_array().into_iter().flatten() {
                    lines.push(format!(
                        "  quota {}: {} / {} percent-milli, reset {}",
                        pool["label"].as_str().unwrap_or("unknown"),
                        pool["utilized"],
                        pool["limit"],
                        pool["reset_at_unix"]
                    ));
                }
                for credit in fetch["credits"].as_array().into_iter().flatten() {
                    lines.push(format!(
                        "  credit {}: {} / {} minor units remaining, reset {}",
                        credit["label"].as_str().unwrap_or("unknown"),
                        credit["remaining_minor_units"],
                        credit["limit_minor_units"],
                        credit["reset_at_unix"]
                    ));
                }
                for limit in fetch["claude_limits"].as_array().into_iter().flatten() {
                    lines.push(format!(
                        "  limit {}: {} percent-milli, active {}, reset {}, model {}, surface {}",
                        limit["kind"].as_str().unwrap_or("unknown"),
                        limit["percent_milli"],
                        limit["is_active"],
                        limit["reset_at_unix"],
                        limit["scope"]["model_display_name"],
                        limit["scope"]["surface_display_name"]
                    ));
                }
                for gap in fetch["partial_gaps"].as_array().into_iter().flatten() {
                    lines.push(format!(
                        "  partial gap: {}",
                        gap.as_str().unwrap_or("unknown")
                    ));
                }
            }
        }
    }
    lines.push(format!(
        "request telemetry losses: {}",
        report["request_loss_total"]
    ));
    lines.push(format!(
        "provider snapshot losses: {}",
        report["provider_snapshot_loss_total"]
    ));
    lines.push(format!(
        "history truncated: {}; reset coverage since: {}",
        report["history_truncated"], report["reset_events_complete_since_unix"]
    ));
    if let Some(gaps) = report["known_gaps"].as_array() {
        for gap in gaps {
            lines.push(format!("known gap: {}", gap.as_str().unwrap_or("unknown")));
        }
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use airlock_core::{
        config::RawConfig,
        storage::{
            ClaudeLimit, CreditPool, QuotaMetric, RequestEvent, ResponseHeaderWindow,
            ResponseWindowLabel, SnapshotFetchStatus, SnapshotSource, SqliteStorage,
        },
    };
    use serde_json::json;

    #[test]
    fn status_never_treats_missing_stale_or_gap_as_free() {
        assert_eq!(status(None, 1_000), "unavailable");
        let credential = airlock_core::ids::CredentialId::try_from("fake").expect("id");
        let provider = ProviderId::try_from("fake").expect("id");
        let mut snapshot = ProviderSnapshot {
            account_id: "fake".to_owned(),
            client: None,
            claude_limits: vec![],
            credential,
            credits: vec![],
            fetched_at_unix: 100,
            fetch_status: SnapshotFetchStatus::Gap,
            gap_reason: Some("usage_timeout".to_owned()),
            group: None,
            header_windows: vec![],
            metrics: vec![],
            pools: vec![],
            provider,
            source: SnapshotSource::OutOfBandFetch,
            surface: SnapshotSurface::ZaiQuota,
        };
        assert_eq!(status(Some(&snapshot), 101), "unavailable");
        snapshot.fetch_status = SnapshotFetchStatus::Success;
        snapshot.pools.push(airlock_core::storage::QuotaPool {
            label: "zai_5h".to_owned(),
            limit: 100_000,
            reset_at_unix: None,
            utilized: 100_000,
        });
        assert_eq!(status(Some(&snapshot), 101), "exhausted");
        snapshot.pools[0].utilized = 20_000;
        assert_eq!(status(Some(&snapshot), 101), "fresh");
        snapshot.pools.clear();
        snapshot.credits.push(CreditPool {
            label: "wattle_ember".to_owned(),
            limit_minor_units: 20_000,
            remaining_minor_units: 19_000,
            reset_at_unix: None,
            used_minor_units: 1_000,
        });
        assert_eq!(status(Some(&snapshot), 101), "unavailable");
        assert_eq!(status(Some(&snapshot), 2_000), "unavailable");
        assert_eq!(
            snapshot_json(&snapshot, 101)["credits"][0]["remaining_minor_units"],
            19_000
        );
        snapshot.pools.push(airlock_core::storage::QuotaPool {
            label: "zai_5h".to_owned(),
            limit: 100_000,
            reset_at_unix: None,
            utilized: 20_000,
        });
        assert_eq!(status(Some(&snapshot), 2_000), "stale");
        snapshot.surface = SnapshotSurface::ClaudeSubscription;
        snapshot.pools[0].label = "five_hour".to_owned();
        assert!(!global_quota_complete(
            Some(&snapshot),
            UsageProviderKind::Claude
        ));
        snapshot.pools.push(airlock_core::storage::QuotaPool {
            label: "seven_day".to_owned(),
            limit: 100_000,
            reset_at_unix: None,
            utilized: 30_000,
        });
        snapshot.claude_limits.push(ClaudeLimit {
            kind: "rate".to_owned(),
            group: Some("models".to_owned()),
            percent_milli: 100_000,
            reset_at_unix: None,
            severity: None,
            is_active: true,
            model_display_name: Some("other-model".to_owned()),
            surface_display_name: None,
        });
        assert!(global_quota_complete(
            Some(&snapshot),
            UsageProviderKind::Claude
        ));
        snapshot.pools.push(airlock_core::storage::QuotaPool {
            label: "seven_day_opus".to_owned(),
            limit: 100_000,
            reset_at_unix: None,
            utilized: 100_000,
        });
        assert_eq!(
            status(Some(&snapshot), 101),
            "fresh",
            "a scoped pool does not exhaust unrelated models"
        );
    }

    #[test]
    #[expect(
        clippy::too_many_lines,
        reason = "one reset fixture checks monotonic history, true resets, gaps, and missing predecessors"
    )]
    fn reset_events_require_two_observed_samples_without_a_relevant_gap() {
        let sample = |at, surface, fetch_status, utilized| ProviderSnapshot {
            account_id: "fake".to_owned(),
            client: None,
            claude_limits: vec![],
            credential: CredentialId::try_from("fake").expect("credential"),
            credits: vec![],
            fetched_at_unix: at,
            fetch_status,
            gap_reason: (fetch_status == SnapshotFetchStatus::Gap)
                .then(|| "usage_timeout".to_owned()),
            group: None,
            header_windows: vec![],
            metrics: vec![],
            pools: (fetch_status == SnapshotFetchStatus::Success)
                .then(|| airlock_core::storage::QuotaPool {
                    label: "five_hour".to_owned(),
                    limit: 100_000,
                    reset_at_unix: None,
                    utilized,
                })
                .into_iter()
                .collect(),
            provider: ProviderId::try_from("fake").expect("provider"),
            source: SnapshotSource::OutOfBandFetch,
            surface,
        };
        let before = sample(
            99,
            SnapshotSurface::ClaudeSubscription,
            SnapshotFetchStatus::Success,
            90_000,
        );
        let after = sample(
            101,
            SnapshotSurface::ClaudeSubscription,
            SnapshotFetchStatus::Success,
            0,
        );
        let quota_gap = sample(
            100,
            SnapshotSurface::ClaudeSubscription,
            SnapshotFetchStatus::Gap,
            0,
        );
        let console_gap = sample(
            100,
            SnapshotSurface::ConsoleBalance,
            SnapshotFetchStatus::Gap,
            0,
        );
        let mut partial = sample(
            100,
            SnapshotSurface::ClaudeSubscription,
            SnapshotFetchStatus::Success,
            0,
        );
        partial.pools.clear();
        partial.metrics.push(QuotaMetric {
            label: "five_hour_utilization_unavailable".to_owned(),
            unit: "gap".to_owned(),
            value: 1,
        });
        let identified = |id, snapshot: &ProviderSnapshot| IdentifiedSnapshot {
            id,
            snapshot: snapshot.clone(),
        };
        let monotonic = sample(
            100,
            SnapshotSurface::ClaudeSubscription,
            SnapshotFetchStatus::Success,
            95_000,
        );
        let series = [
            identified(1, &before),
            identified(2, &monotonic),
            identified(3, &after),
        ];
        let resets = identified_reset_events(&series);
        assert_eq!(
            resets.len(),
            1,
            "monotonic predecessor must not fabricate another reset"
        );
        assert_eq!(resets[0].preceding_snapshot_id, 2);
        assert_eq!(resets[0].current_snapshot_id, 3);
        assert!(
            identified_reset_events(&[
                identified(1, &before),
                identified(2, &quota_gap),
                identified(3, &after)
            ])
            .is_empty()
        );
        assert!(
            identified_reset_events(&[
                identified(1, &before),
                identified(2, &partial),
                identified(3, &after)
            ])
            .is_empty()
        );
        assert!(
            reset_events(&[]).is_empty(),
            "empty history has no comparison"
        );
        assert!(
            reset_events(&[&after]).is_empty(),
            "one sample or truncated predecessor has no comparison"
        );
        assert_eq!(
            reset_events(&[&before, &after]).len(),
            1,
            "a boundary crossing is observable only with both samples"
        );
        assert!(
            reset_events(&[&before, &quota_gap, &after]).is_empty(),
            "a quota fetch gap breaks that series"
        );
        assert!(
            reset_events(&[&before, &partial, &after]).is_empty(),
            "a missing quota dimension breaks that series"
        );
        assert_eq!(
            reset_events(&[&before, &console_gap, &after]).len(),
            1,
            "a Console gap does not break quota observations"
        );
    }

    #[tokio::test]
    #[expect(
        clippy::too_many_lines,
        reason = "the read-only report contract needs a complete writer, snapshot, and aggregate fixture"
    )]
    async fn read_only_json_contract_keeps_header_age_and_request_usage_separate() {
        let directory = tempfile::tempdir().expect("private scratch");
        let raw: RawConfig = serde_json::from_value(json!({
            "clients": {"harness": {"grants": ["anthropic"], "token_file": "/run/fake-client-token"}},
            "credentials": {
                "claude": {"auth": {"type": "oauth_bearer", "file": "/run/fake-provider-token"}, "provider": "claude"},
                "other": {"auth": {"type": "oauth_bearer", "file": "/run/fake-provider2-token"}, "provider": "claude"}
            },
            "groups": {"anthropic": {"intercept": ["api.anthropic.com"],
                "members": {"claude": {"models": []}, "other": {"models": ["other-model"]}},
                "primary": "claude", "protocol": "anthropic"}},
            "listen": "127.0.0.1:0", "providers": {"claude": {"preset": "claude"}},
            "state_dir": directory.path().join("state"),
        }))
        .expect("fake config JSON");
        let config = Config::try_from(raw).expect("fake config");
        let storage = SqliteStorage::open(config.state_dir(), config.storage_identities(100))
            .await
            .expect("scratch storage");
        let credential = CredentialId::try_from("claude").expect("credential");
        let provider = ProviderId::try_from("claude").expect("provider");
        let client = airlock_core::ids::ClientId::try_from("harness").expect("client");
        let group = airlock_core::ids::GroupId::try_from("anthropic").expect("group");
        let snapshot = |at, source, surface| ProviderSnapshot {
            account_id: "claude".to_owned(),
            client: Some(client.clone()),
            claude_limits: vec![],
            credential: credential.clone(),
            credits: vec![],
            fetched_at_unix: at,
            fetch_status: SnapshotFetchStatus::Success,
            gap_reason: None,
            group: Some(group.clone()),
            header_windows: vec![],
            metrics: vec![],
            pools: vec![],
            provider: provider.clone(),
            source,
            surface,
        };
        let mut earlier = snapshot(
            700,
            SnapshotSource::OutOfBandFetch,
            SnapshotSurface::ClaudeSubscription,
        );
        earlier.pools.push(airlock_core::storage::QuotaPool {
            label: "five_hour".to_owned(),
            limit: 100_000,
            reset_at_unix: Some(1_200),
            utilized: 50_000,
        });
        earlier.credits.push(CreditPool {
            label: "wattle_ember".to_owned(),
            limit_minor_units: 20_000,
            remaining_minor_units: 5_000,
            reset_at_unix: Some(1_200),
            used_minor_units: 15_000,
        });
        storage
            .append_provider_snapshot(earlier)
            .await
            .expect("earlier fetch");
        let mut other_fetch = snapshot(
            850,
            SnapshotSource::OutOfBandFetch,
            SnapshotSurface::ClaudeSubscription,
        );
        other_fetch.account_id = "other".to_owned();
        other_fetch.credential = CredentialId::try_from("other").expect("other credential");
        other_fetch.pools.push(airlock_core::storage::QuotaPool {
            label: "five_hour".to_owned(),
            limit: 100_000,
            reset_at_unix: Some(1_300),
            utilized: 40_000,
        });
        storage
            .append_provider_snapshot(other_fetch)
            .await
            .expect("other fetch");
        let mut fetch = snapshot(
            900,
            SnapshotSource::OutOfBandFetch,
            SnapshotSurface::ClaudeSubscription,
        );
        fetch.pools.push(airlock_core::storage::QuotaPool {
            label: "five_hour".to_owned(),
            limit: 100_000,
            reset_at_unix: Some(1_500),
            utilized: 25_000,
        });
        fetch.credits.push(CreditPool {
            label: "wattle_ember".to_owned(),
            limit_minor_units: 20_000,
            remaining_minor_units: 15_000,
            reset_at_unix: Some(1_500),
            used_minor_units: 5_000,
        });
        fetch.claude_limits.push(ClaudeLimit {
            kind: "rate".to_owned(),
            group: Some("models".to_owned()),
            percent_milli: 100_000,
            reset_at_unix: Some(1_500),
            severity: Some("warning".to_owned()),
            is_active: true,
            model_display_name: Some("fake-model".to_owned()),
            surface_display_name: Some("fake-surface".to_owned()),
        });
        fetch.metrics.push(QuotaMetric {
            label: "seven_day_utilization_unavailable".to_owned(),
            unit: "gap".to_owned(),
            value: 1,
        });
        storage
            .append_provider_snapshot(fetch)
            .await
            .expect("fetch");
        let mut header = snapshot(
            800,
            SnapshotSource::ResponseHeaders,
            SnapshotSurface::ResponseHeaders,
        );
        header.header_windows.push(ResponseHeaderWindow {
            label: ResponseWindowLabel::FiveHour,
            reset_at_unix: Some(1_500),
            status: None,
            utilization_milli: 30_000,
        });
        storage
            .append_provider_snapshot(header)
            .await
            .expect("header");
        let mut console_gap = snapshot(
            901,
            SnapshotSource::OutOfBandFetch,
            SnapshotSurface::ConsoleBalance,
        );
        console_gap.fetch_status = SnapshotFetchStatus::Gap;
        console_gap.gap_reason = Some("console_balance_requires_ant_auth_login".to_owned());
        storage
            .append_provider_snapshot(console_gap)
            .await
            .expect("Console gap");
        storage
            .try_append_request_event(RequestEvent {
                cache_read_tokens: None,
                cache_write_tokens: None,
                client: client.clone(),
                credential: credential.clone(),
                dropped_events: 0,
                group: group.clone(),
                input_tokens: Some(12),
                latency_ms: 40,
                model: "glm-fake".to_owned(),
                occurred_at_unix: 950,
                outcome: RequestOutcome::Completed,
                output_tokens: Some(7),
                request_bytes: 32,
                response_bytes: 64,
                status_code: 200,
                usage_complete: true,
            })
            .await
            .expect("request event");
        let mut reader = ReadOnlyStorage::open(config.state_dir())
            .await
            .expect("reader");
        let value = build(
            &config,
            &mut reader,
            &Options {
                bucket_seconds: NonZeroU64::new(300).expect("bucket"),
                history_limit: 10,
                since_unix: 1,
            },
            1_000,
        )
        .await
        .expect("report");
        let golden: Value = serde_json::from_str(include_str!(
            "../../../../web-fixtures/usage-report-v1.json"
        ))
        .expect("checked-in golden JSON");
        assert_eq!(
            value, golden,
            "the entire populated v1 report contract changed"
        );
        assert_eq!(value["schema_version"], 1);
        assert_eq!(value["credentials"][0]["status"], "fresh");
        assert_eq!(value["credentials"][0]["header_age_seconds"], 200);
        assert_eq!(
            value["credentials"][0]["latest_fetch"]["source"],
            "out_of_band_fetch"
        );
        assert_eq!(
            value["credentials"][0]["latest_header"]["source"],
            "response_headers"
        );
        assert_eq!(value["request_usage"][0]["input_tokens"], 12);
        assert_eq!(value["request_usage"][0]["output_tokens"], 7);
        assert_eq!(value["request_usage"][0]["complete_events"], 1);
        assert_eq!(value["snapshots"].as_array().expect("history").len(), 5);
        assert_eq!(
            value["credentials"][1]["latest_fetch"]["fetched_at_unix"],
            850
        );
        assert_eq!(value["reset_events"][0]["kind"], "utilization_drop");
        assert_eq!(value["reset_events"][0]["detected_at_unix"], 900);
        assert!(value["reset_events_complete_since_unix"].is_null());
        assert_eq!(value["reset_events_observed_only"], true);
        let encoded = serde_json::to_string(&value).expect("JSON");
        assert!(!encoded.contains("fake-provider-token"));
        assert!(!encoded.contains("/run/fake-provider-token"));
        assert!(!human(&value).contains("fake-provider-token"));
        assert_eq!(
            consumer_capacity_state(encoded.as_bytes()),
            ("fresh", false)
        );
        for at in 901..=1_001 {
            let mut noisy_header = snapshot(
                at,
                SnapshotSource::ResponseHeaders,
                SnapshotSurface::ResponseHeaders,
            );
            noisy_header.header_windows.push(ResponseHeaderWindow {
                label: ResponseWindowLabel::FiveHour,
                reset_at_unix: None,
                status: None,
                utilization_milli: 20_000,
            });
            storage
                .append_provider_snapshot(noisy_header)
                .await
                .expect("noisy header");
        }
        let narrow = build(
            &config,
            &mut reader,
            &Options {
                bucket_seconds: NonZeroU64::new(300).expect("bucket"),
                history_limit: 1,
                since_unix: 1,
            },
            1_002,
        )
        .await
        .expect("narrow report");
        assert_eq!(narrow["credentials"][0]["status"], "fresh");
        assert_eq!(
            narrow["credentials"][0]["latest_fetch"]["fetched_at_unix"],
            900
        );
        assert_eq!(
            narrow["credentials"][1]["latest_fetch"]["fetched_at_unix"],
            850
        );
        assert_eq!(
            narrow["credentials"][0]["latest_header"]["fetched_at_unix"],
            1_001
        );
        assert_eq!(narrow["history_truncated"], true);
        assert!(narrow["reset_events_complete_since_unix"].is_null());
        assert_eq!(narrow["history_oldest_at_unix"], 1_001);
        let writing = async {
            for at in 1_002..1_022 {
                let mut header = snapshot(
                    at,
                    SnapshotSource::ResponseHeaders,
                    SnapshotSurface::ResponseHeaders,
                );
                header.header_windows.push(ResponseHeaderWindow {
                    label: ResponseWindowLabel::FiveHour,
                    reset_at_unix: None,
                    status: None,
                    utilization_milli: 10_000,
                });
                storage
                    .append_provider_snapshot(header)
                    .await
                    .expect("concurrent header");
                tokio::task::yield_now().await;
            }
        };
        let reading = async {
            for _ in 0..20 {
                let report = build(
                    &config,
                    &mut reader,
                    &Options {
                        bucket_seconds: NonZeroU64::new(300).expect("bucket"),
                        history_limit: 1,
                        since_unix: 1,
                    },
                    1_100,
                )
                .await
                .expect("concurrent read");
                assert_eq!(
                    report["credentials"][0]["latest_fetch"]["fetched_at_unix"],
                    900
                );
                assert_eq!(report["credentials"][0]["status"], "fresh");
                tokio::task::yield_now().await;
            }
        };
        tokio::join!(writing, reading);
        let mut exhausted = snapshot(
            1_022,
            SnapshotSource::OutOfBandFetch,
            SnapshotSurface::ClaudeSubscription,
        );
        exhausted.pools.push(airlock_core::storage::QuotaPool {
            label: "five_hour".to_owned(),
            limit: 100_000,
            reset_at_unix: Some(1_500),
            utilized: 100_000,
        });
        storage
            .append_provider_snapshot(exhausted)
            .await
            .expect("exhausted fetch");
        let options = Options {
            bucket_seconds: NonZeroU64::new(300).expect("bucket"),
            history_limit: 1,
            since_unix: 1,
        };
        let exhausted_report = build(&config, &mut reader, &options, 1_023)
            .await
            .expect("exhausted report");
        assert_eq!(
            consumer_capacity_state(&serde_json::to_vec(&exhausted_report).expect("JSON")),
            ("exhausted", false)
        );
        let stale_report = build(&config, &mut reader, &options, 5_000)
            .await
            .expect("stale report");
        assert_eq!(
            consumer_capacity_state(&serde_json::to_vec(&stale_report).expect("JSON")),
            ("stale", false)
        );
        let mut unavailable = snapshot(
            1_023,
            SnapshotSource::OutOfBandFetch,
            SnapshotSurface::ClaudeSubscription,
        );
        unavailable.fetch_status = SnapshotFetchStatus::Gap;
        unavailable.gap_reason = Some("usage_timeout".to_owned());
        storage
            .append_provider_snapshot(unavailable)
            .await
            .expect("gap fetch");
        let unavailable_report = build(&config, &mut reader, &options, 1_024)
            .await
            .expect("gap report");
        assert_eq!(
            consumer_capacity_state(&serde_json::to_vec(&unavailable_report).expect("JSON")),
            ("unavailable", false)
        );
        storage.close().await.expect("close writer");
    }

    fn consumer_capacity_state(encoded: &[u8]) -> (&'static str, bool) {
        let value: Value = serde_json::from_slice(encoded).expect("consumer JSON");
        assert_eq!(value["schema_version"], 1);
        let credential = &value["credentials"][0];
        let state = match credential["status"].as_str().expect("status") {
            "fresh" => "fresh",
            "exhausted" => "exhausted",
            "stale" => "stale",
            "unavailable" => "unavailable",
            other => panic!("unknown state: {other}"),
        };
        let usable =
            state == "fresh" && credential["global_quota_complete"].as_bool() == Some(true);
        (state, usable)
    }

    #[tokio::test]
    async fn empty_report_has_complete_versioned_json_golden_and_safe_consumer_states() {
        let directory = tempfile::tempdir().expect("scratch");
        let raw: RawConfig = serde_json::from_value(json!({
            "clients": {"harness": {"grants": ["anthropic"], "token_file": "/run/fake-client"}},
            "credentials": {"zai": {"auth": {"type": "api_key", "file": "/run/fake-provider"}, "provider": "zai"}},
            "groups": {"anthropic": {"intercept": ["api.anthropic.com"],
                "members": {"zai": {"models": []}}, "primary": "zai", "protocol": "anthropic"}},
            "listen": "127.0.0.1:0", "providers": {"zai": {"preset": "zai"}},
            "state_dir": directory.path().join("state")
        })).expect("fake config");
        let config = Config::try_from(raw).expect("config");
        let storage = SqliteStorage::open(config.state_dir(), config.storage_identities(100))
            .await
            .expect("storage");
        let mut reader = ReadOnlyStorage::open(config.state_dir())
            .await
            .expect("reader");
        let report = build(
            &config,
            &mut reader,
            &Options {
                bucket_seconds: NonZeroU64::new(300).expect("bucket"),
                history_limit: 1,
                since_unix: 1,
            },
            1_000,
        )
        .await
        .expect("report");
        let encoded = serde_json::to_vec(&report).expect("serialized report");
        let decoded: Value = serde_json::from_slice(&encoded).expect("consumer JSON");
        assert_eq!(
            decoded,
            json!({
                "bucket_seconds": 300,
                "credentials": [{"account_id": null, "auth": "api_key", "client": "harness",
                    "global_quota_complete": false,
                    "credential": "zai", "explicit_usage_selection": false, "group": "anthropic",
                    "header_age_seconds": null, "latest_fetch": null, "latest_header": null,
                    "provider": "zai", "routes": [{"client": "harness", "group": "anthropic",
                        "models": [], "primary": true, "protocol": "anthropic"}],
                    "status": "unavailable", "surface": "zai_quota"}],
                "fresh_seconds": 900, "generated_at_unix": 1_000,
                "history_oldest_at_unix": null, "history_truncated": false,
                "known_gaps": ["claude_limit_ui_mapping_unverified", "claude_credit_pool_rows_schema_unverified",
                    "claude_profile_subscription_metadata_unavailable", "codex_secondary_window_schema_unverified",
                    "console_balance_requires_ant_auth_login", "cpa_management_api_unsupported"],
                "provider_snapshot_loss_total": 0, "request_loss_total": 0, "request_usage": [],
                "reset_events": [], "reset_events_complete_since_unix": null,
                "reset_events_observed_only": true,
                "schema_version": 1, "since_unix": 1, "snapshots": []
            })
        );
        assert_eq!(consumer_capacity_state(&encoded), ("unavailable", false));
        storage.close().await.expect("close storage");
    }
    #[test]
    fn serialized_consumer_refuses_partial_global_quota() {
        let value: Value = serde_json::from_str(include_str!(
            "../../../../web-fixtures/usage-report-v1.json"
        ))
        .expect("committed partial fixture");
        assert_eq!(
            value["credentials"][0]["latest_fetch"]["partial_gaps"][0],
            "seven_day_utilization_unavailable"
        );
        assert_eq!(
            consumer_capacity_state(&serde_json::to_vec(&value).expect("JSON")),
            ("fresh", false)
        );
    }
}

//! Guarded SQLite persistence for airlock daemon state.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, DirBuilder, OpenOptions},
    io,
    num::NonZeroU64,
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

use log::LevelFilter;
use rustix::process::getuid;
use sqlx::{
    ConnectOptions, Connection, Sqlite, Transaction,
    sqlite::{SqliteConnectOptions, SqliteConnection, SqliteJournalMode, SqliteSynchronous},
};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use crate::ids::{ClientId, CredentialId, GroupId, ProviderId};

const DATABASE_FILE: &str = "airlock.sqlite3";
const MAX_SNAPSHOT_HISTORY: u64 = 1_000;
const MAX_AGGREGATE_ROWS: usize = 10_000;
const MAX_SNAPSHOT_CHILDREN: usize = 64;
const MAX_RESPONSE_WINDOWS: usize = 2;

#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("storage changed while replacing OAuth tokens for {credential}")]
    ConcurrentOauth { credential: CredentialId },
    #[error(transparent)]
    Database(#[from] sqlx::Error),
    #[error("storage at {path} failed integrity checks")]
    Integrity { path: PathBuf },
    #[error("invalid storage input: {field}")]
    Input { field: &'static str },
    #[error("could not take exclusive ownership of storage at {path}")]
    ConnectionOwnership { path: PathBuf },
    #[error("could not prepare storage at {path}: {source}")]
    Io { path: PathBuf, source: io::Error },
    #[error(transparent)]
    Migrate(#[from] sqlx::migrate::MigrateError),
    #[error("OAuth pair for {credential} and {provider} is absent")]
    MissingOauthPair {
        credential: CredentialId,
        provider: ProviderId,
    },
    #[error(
        "{path} is not a regular file, not a symlink, mode 0600, and readable only by this user"
    )]
    NotPrivateFile { path: PathBuf },
    #[error("{path} must be a directory, not a symlink, owned by this user with mode 0700")]
    NotPrivateDirectory { path: PathBuf },
    #[error("stored identity for {credential} is inconsistent")]
    StoredIdentity { credential: CredentialId },
    #[error("usage range produces more than 10000 aggregate groups")]
    UsageRangeIncomplete,
    #[error("control query exceeded its 250 ms execution budget")]
    QueryBudgetExceeded,
    #[error("provider snapshot report exceeds its 1000-row bound")]
    SnapshotRangeIncomplete,
    #[error("request usage storage is unavailable")]
    UsageUnavailable,
    #[error("stored {kind} identity is invalid: {value:?}")]
    StoredId { kind: &'static str, value: String },
    #[error("storage usage worker for {path} stopped unexpectedly: {source}")]
    UsageWorker {
        path: PathBuf,
        source: tokio::task::JoinError,
    },
}

/// Secret token material used by the storage interface.
///
/// The buffer zeroizes on drop and its `Debug` implementation never exposes the value.
#[derive(Clone)]
pub struct TokenMaterial(Zeroizing<String>);

impl TokenMaterial {
    /// Validates and wraps daemon-owned token material.
    ///
    /// # Errors
    ///
    /// Returns [`StorageError::Input`] for an empty token or one over 8192 bytes.
    pub fn new(value: String) -> Result<Self, StorageError> {
        let material = Self(Zeroizing::new(value));
        if material.0.is_empty() || material.0.len() > 8192 {
            return Err(StorageError::Input {
                field: "token material must be 1..=8192 bytes",
            });
        }
        Ok(material)
    }

    /// Returns token material for a caller that must transmit it.
    ///
    /// Callers must not debug, display, or log the returned value.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    #[must_use]
    pub fn matches(&self, candidate: &[u8]) -> bool {
        bool::from(self.0.as_bytes().ct_eq(candidate))
    }
}

impl std::fmt::Debug for TokenMaterial {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("[redacted]")
    }
}

impl TryFrom<String> for TokenMaterial {
    type Error = StorageError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

#[derive(Debug, Clone)]
pub struct StorageIdentities {
    pub clients: BTreeSet<ClientId>,
    pub credentials: BTreeMap<CredentialId, ProviderId>,
    pub group_members: BTreeSet<(GroupId, CredentialId)>,
    pub groups: BTreeSet<GroupId>,
    pub inserted_at_unix: i64,
    pub providers: BTreeSet<ProviderId>,
}

#[derive(Debug)]
pub struct OauthPairReplacement {
    pub client: ClientId,
    pub credential: CredentialId,
    pub expected_generation: u64,
    pub fake_access_token: TokenMaterial,
    pub fake_access_expires_at_unix: i64,
    pub fake_refresh_token: TokenMaterial,
    pub real_access_token: TokenMaterial,
    pub real_access_expires_at_unix: i64,
    pub real_refresh_token: TokenMaterial,
    pub real_refresh_expires_at_unix: Option<i64>,
    pub updated_at_unix: i64,
}

#[derive(Debug)]
pub struct OauthPairRecord {
    pub client: ClientId,
    pub credential: CredentialId,
    pub fake_access_token: TokenMaterial,
    pub fake_access_expires_at_unix: i64,
    pub fake_refresh_token: TokenMaterial,
    pub generation: u64,
    pub real_access_token: TokenMaterial,
    pub real_access_expires_at_unix: i64,
    pub real_refresh_token: TokenMaterial,
    pub real_refresh_expires_at_unix: Option<i64>,
    pub updated_at_unix: i64,
}

#[derive(Debug)]
pub struct OauthPairRetirement {
    pub client: ClientId,
    pub credential: CredentialId,
    pub expected_generation: u64,
    pub fake_refresh_token: TokenMaterial,
    pub provider: ProviderId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestOutcome {
    Cancelled,
    Completed,
    Failed,
    Rejected,
}

impl RequestOutcome {
    fn as_storage(self) -> &'static str {
        match self {
            Self::Cancelled => "cancelled",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Rejected => "rejected",
        }
    }

    fn from_storage(value: &str) -> Option<Self> {
        match value {
            "cancelled" => Some(Self::Cancelled),
            "completed" => Some(Self::Completed),
            "failed" => Some(Self::Failed),
            "rejected" => Some(Self::Rejected),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RequestEvent {
    pub cache_read_tokens: Option<u64>,
    pub cache_write_tokens: Option<u64>,
    pub client: ClientId,
    pub credential: CredentialId,
    pub dropped_events: u64,
    pub group: GroupId,
    pub input_tokens: Option<u64>,
    pub latency_ms: u64,
    pub model: String,
    pub occurred_at_unix: i64,
    pub outcome: RequestOutcome,
    pub output_tokens: Option<u64>,
    pub request_bytes: u64,
    pub response_bytes: u64,
    pub status_code: u16,
    pub usage_complete: bool,
}

#[derive(Debug)]
pub struct RequestUsageQuery {
    pub bucket_seconds: NonZeroU64,
    pub group: GroupId,
    pub since_unix: i64,
    pub until_unix: i64,
}

#[derive(Debug, PartialEq, Eq)]
pub struct RequestUsageAggregate {
    pub bucket_start_unix: i64,
    pub cache_read_tokens: Option<u64>,
    pub cache_write_tokens: Option<u64>,
    pub client: Option<ClientId>,
    pub complete_events: u64,
    pub credential: CredentialId,
    pub error_events: u64,
    pub events: u64,
    pub input_tokens: Option<u64>,
    pub latency_ms: u64,
    pub model: String,
    pub outcome: RequestOutcome,
    pub output_tokens: Option<u64>,
    pub provider: ProviderId,
    pub request_bytes: u64,
    pub response_bytes: u64,
    pub successful_events: u64,
}

#[derive(Debug)]
pub struct RequestSeriesAggregate {
    pub aggregate: RequestUsageAggregate,
    pub group: GroupId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SnapshotFetchStatus {
    Gap,
    Success,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SnapshotSource {
    OutOfBandFetch,
    ResponseHeaders,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SnapshotSurface {
    ClaudeSubscription,
    CodexRateLimits,
    ConsoleBalance,
    ResponseHeaders,
    ZaiQuota,
}

impl SnapshotSurface {
    const fn as_storage(self) -> &'static str {
        match self {
            Self::ClaudeSubscription => "claude_subscription",
            Self::CodexRateLimits => "codex_rate_limits",
            Self::ConsoleBalance => "console_balance",
            Self::ResponseHeaders => "response_headers",
            Self::ZaiQuota => "zai_quota",
        }
    }

    fn from_storage(value: &str) -> Option<Self> {
        match value {
            "claude_subscription" => Some(Self::ClaudeSubscription),
            "codex_rate_limits" => Some(Self::CodexRateLimits),
            "console_balance" => Some(Self::ConsoleBalance),
            "response_headers" => Some(Self::ResponseHeaders),
            "zai_quota" => Some(Self::ZaiQuota),
            _ => None,
        }
    }
}

impl SnapshotSource {
    const fn as_storage(self) -> &'static str {
        match self {
            Self::OutOfBandFetch => "out_of_band_fetch",
            Self::ResponseHeaders => "response_headers",
        }
    }

    fn from_storage(value: &str) -> Option<Self> {
        match value {
            "out_of_band_fetch" => Some(Self::OutOfBandFetch),
            "response_headers" => Some(Self::ResponseHeaders),
            _ => None,
        }
    }
}

impl SnapshotFetchStatus {
    fn as_storage(self) -> &'static str {
        match self {
            Self::Gap => "gap",
            Self::Success => "success",
        }
    }

    fn from_storage(value: &str) -> Option<Self> {
        match value {
            "gap" => Some(Self::Gap),
            "success" => Some(Self::Success),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuotaPool {
    pub label: String,
    pub limit: u64,
    pub reset_at_unix: Option<i64>,
    pub utilized: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreditPool {
    pub label: String,
    pub limit_minor_units: u64,
    pub remaining_minor_units: u64,
    pub reset_at_unix: Option<i64>,
    pub used_minor_units: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuotaMetric {
    pub label: String,
    pub unit: String,
    pub value: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClaudeLimit {
    pub kind: String,
    pub group: Option<String>,
    pub percent_milli: u64,
    pub reset_at_unix: Option<i64>,
    pub severity: Option<String>,
    pub is_active: bool,
    pub model_display_name: Option<String>,
    pub surface_display_name: Option<String>,
}

#[derive(Debug, Clone, Copy, Eq, Ord, PartialEq, PartialOrd)]
pub enum ResponseWindowLabel {
    FiveHour,
    SevenDay,
}

impl ResponseWindowLabel {
    const fn as_storage(self) -> &'static str {
        match self {
            Self::FiveHour => "five_hour",
            Self::SevenDay => "seven_day",
        }
    }

    fn from_storage(value: &str) -> Option<Self> {
        match value {
            "five_hour" => Some(Self::FiveHour),
            "seven_day" => Some(Self::SevenDay),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResponseWindowStatus {
    Allowed,
    AllowedWarning,
    Rejected,
}

impl ResponseWindowStatus {
    const fn as_storage(self) -> &'static str {
        match self {
            Self::Allowed => "allowed",
            Self::AllowedWarning => "allowed_warning",
            Self::Rejected => "rejected",
        }
    }

    fn from_storage(value: &str) -> Option<Self> {
        match value {
            "allowed" => Some(Self::Allowed),
            "allowed_warning" => Some(Self::AllowedWarning),
            "rejected" => Some(Self::Rejected),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResponseHeaderWindow {
    pub label: ResponseWindowLabel,
    pub reset_at_unix: Option<i64>,
    pub status: Option<ResponseWindowStatus>,
    pub utilization_milli: u32,
}

#[derive(Debug, Clone)]
pub struct ProviderSnapshot {
    pub account_id: String,
    pub client: Option<ClientId>,
    pub claude_limits: Vec<ClaudeLimit>,
    pub credential: CredentialId,
    pub credits: Vec<CreditPool>,
    pub fetched_at_unix: i64,
    pub fetch_status: SnapshotFetchStatus,
    pub gap_reason: Option<String>,
    pub group: Option<GroupId>,
    pub header_windows: Vec<ResponseHeaderWindow>,
    pub metrics: Vec<QuotaMetric>,
    pub pools: Vec<QuotaPool>,
    pub provider: ProviderId,
    pub source: SnapshotSource,
    pub surface: SnapshotSurface,
}

impl ProviderSnapshot {
    /// Whether a successful observation carries any validated typed dimension.
    #[must_use]
    pub fn has_typed_data(&self) -> bool {
        !self.pools.is_empty()
            || !self.credits.is_empty()
            || !self.metrics.is_empty()
            || !self.claude_limits.is_empty()
            || !self.header_windows.is_empty()
    }
}

#[derive(Debug, Clone)]
pub struct SnapshotQuery {
    pub limit: NonZeroU64,
    pub provider: ProviderId,
    pub since_unix: i64,
}

#[derive(Debug)]
pub struct SnapshotPage {
    pub snapshots: Vec<ProviderSnapshot>,
    pub truncated: bool,
}

#[derive(Debug, Clone)]
pub struct IdentifiedSnapshot {
    pub id: i64,
    pub snapshot: ProviderSnapshot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ControlMetadata {
    pub provider_snapshot_loss_total: u64,
    pub request_loss_total: u64,
}

#[derive(Debug)]
pub struct IdentifiedSnapshotPage {
    pub metadata: ControlMetadata,
    /// Chronological returned snapshots.
    pub snapshots: Vec<IdentifiedSnapshot>,
    /// One older same-filter snapshot used to derive cross-page resets.
    pub predecessor: Option<IdentifiedSnapshot>,
    /// Older matching history in the requested window was omitted.
    pub truncated: bool,
}

#[derive(Debug)]
pub struct RequestRow {
    pub cache_read_tokens: Option<u64>,
    pub cache_write_tokens: Option<u64>,
    pub client: Option<ClientId>,
    pub credential: CredentialId,
    pub group: GroupId,
    pub id: i64,
    pub input_tokens: Option<u64>,
    pub latency_ms: u64,
    pub model: String,
    pub occurred_at_unix: i64,
    pub outcome: RequestOutcome,
    pub output_tokens: Option<u64>,
    pub provider: ProviderId,
    pub request_bytes: u64,
    pub response_bytes: u64,
    pub status_code: u16,
    pub usage_complete: bool,
}

#[derive(Debug)]
pub struct RequestRowPage {
    pub metadata: ControlMetadata,
    /// Chronological rows matching the bounded page.
    pub rows: Vec<RequestRow>,
    /// Cursor to the next older immutable page.
    pub next_before: Option<RequestRowCursor>,
    pub has_more: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RequestRowCursor {
    pub cutoff_id: i64,
    pub occurred_at_unix: i64,
    pub row_id: i64,
}

type UsageWork = (
    RequestEvent,
    tokio::sync::oneshot::Sender<Result<(), StorageError>>,
);

pub struct SqliteStorage {
    connection: std::sync::Arc<tokio::sync::Mutex<SqliteConnection>>,
    database_path: PathBuf,
    snapshot_loss_flush_lock: Arc<tokio::sync::Mutex<()>>,
    snapshot_losses_pending: Arc<AtomicU64>,
    observation_permits: Arc<tokio::sync::Semaphore>,
    observation_tasks: std::sync::Mutex<tokio::task::JoinSet<()>>,
    #[cfg(test)]
    observation_after_commit: std::sync::Mutex<
        Option<(
            tokio::sync::oneshot::Sender<()>,
            tokio::sync::oneshot::Receiver<()>,
        )>,
    >,
    usage_sender: tokio::sync::mpsc::Sender<UsageWork>,
    usage_worker: tokio::task::JoinHandle<()>,
}

/// A CLI connection that cannot seed identities, migrate, or read OAuth tables.
pub struct ReadOnlyStorage {
    connection: SqliteConnection,
    database_path: PathBuf,
}

impl ReadOnlyStorage {
    /// Opens existing private state without creating or changing application data.
    ///
    /// # Errors
    /// Refuses absent, exposed, or corrupt state.
    pub async fn open(directory: &Path) -> Result<Self, StorageError> {
        check_private_directory(directory)?;
        let database_path = directory.join(DATABASE_FILE);
        private_file(&database_path)?;
        check_private_companions(&database_path)?;
        let options = SqliteConnectOptions::new()
            .filename(&database_path)
            .read_only(true)
            .foreign_keys(true)
            .busy_timeout(std::time::Duration::ZERO)
            .log_statements(LevelFilter::Off)
            .log_slow_statements(LevelFilter::Off, std::time::Duration::from_secs(1));
        let mut connection = options.connect().await?;
        sqlx::query("PRAGMA query_only = ON")
            .execute(&mut connection)
            .await?;
        quick_check(&mut connection, &database_path).await?;
        ensure_foreign_keys(&mut connection, &database_path).await?;
        check_private_companions(&database_path)?;
        Ok(Self {
            connection,
            database_path,
        })
    }

    /// Returns persisted request aggregates without opening token-bearing rows.
    ///
    /// # Errors
    /// Propagates bounded-query, integrity, and SQLite errors.
    pub async fn request_usage(
        &mut self,
        query: RequestUsageQuery,
    ) -> Result<Vec<RequestUsageAggregate>, StorageError> {
        read_request_usage(&mut self.connection, &self.database_path, query).await
    }

    /// Returns the unattributed lifetime count of dropped request events.
    ///
    /// # Errors
    /// Propagates integrity and SQLite errors.
    pub async fn request_usage_loss_total(&mut self) -> Result<u64, StorageError> {
        let row = sqlx::query!(
            r#"SELECT COALESCE(SUM(dropped_events), 0) AS "total!: i64" FROM request_events"#
        )
        .fetch_one(&mut self.connection)
        .await?;
        stored_count(row.total, &self.database_path)
    }

    /// Returns the bounded, unattributed count of snapshot writes lost before recovery.
    ///
    /// # Errors
    /// Propagates integrity and SQLite errors.
    pub async fn provider_snapshot_loss_total(&mut self) -> Result<u64, StorageError> {
        let row =
            sqlx::query_scalar!("SELECT lost_snapshots FROM provider_snapshot_losses WHERE id = 1")
                .fetch_optional(&mut self.connection)
                .await?;
        stored_count(row.unwrap_or(0), &self.database_path)
    }

    /// Returns bounded append-only provider snapshot history.
    ///
    /// # Errors
    /// Propagates bounded-query, integrity, and SQLite errors.
    pub async fn provider_snapshots(
        &mut self,
        query: SnapshotQuery,
    ) -> Result<Vec<ProviderSnapshot>, StorageError> {
        read_provider_snapshots(&mut self.connection, &self.database_path, query).await
    }

    /// Returns bounded history with an explicit indication of older omitted rows.
    ///
    /// # Errors
    /// Propagates bounded-query, integrity, and SQLite errors.
    pub async fn provider_snapshot_page(
        &mut self,
        query: SnapshotQuery,
    ) -> Result<SnapshotPage, StorageError> {
        read_provider_snapshot_page(&mut self.connection, &self.database_path, query, None).await
    }

    /// Reads current state independently of the caller's bounded history window.
    ///
    /// # Errors
    /// Propagates integrity and SQLite errors.
    /// Converts the existing private read-only connection into the control reader.
    ///
    /// The control plane owns this persistent connection so its bounded transactions never share
    /// the CLI lifecycle and never use the forwarding writer.
    #[must_use]
    pub fn into_control_reader(self) -> ControlReader {
        ControlReader {
            connection: self.connection,
            database_path: self.database_path,
        }
    }

    /// Reads the latest snapshot for an identified quota series.
    ///
    /// # Errors
    /// Propagates bounded-query, integrity, and SQLite errors.
    pub async fn latest_provider_snapshot(
        &mut self,
        provider: ProviderId,
        credential: CredentialId,
        source: SnapshotSource,
        surface: SnapshotSurface,
    ) -> Result<Option<ProviderSnapshot>, StorageError> {
        let page = read_provider_snapshot_page(
            &mut self.connection,
            &self.database_path,
            SnapshotQuery {
                limit: NonZeroU64::MIN,
                provider,
                since_unix: 1,
            },
            Some((credential, source, surface)),
        )
        .await?;
        Ok(page.snapshots.into_iter().next())
    }
}

pub struct ControlReader {
    connection: SqliteConnection,
    database_path: PathBuf,
}

struct ReadBudget {
    cancelled: Arc<AtomicBool>,
    deadline: std::time::Instant,
}

impl Drop for ReadBudget {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
    }
}

/// One bounded read transaction for the complete HTTP report.
pub struct ControlReport<'a> {
    budget: ReadBudget,
    database_path: &'a Path,
    transaction: Transaction<'a, Sqlite>,
}

impl ControlReader {
    const QUERY_BUDGET: std::time::Duration = std::time::Duration::from_millis(250);

    /// Closes the control reader after its socket and report tasks have drained.
    ///
    /// # Errors
    /// Returns the underlying SQLite close error.
    pub async fn close(self) -> Result<(), StorageError> {
        self.connection.close().await?;
        Ok(())
    }

    async fn deadline(&mut self) -> Result<ReadBudget, StorageError> {
        let deadline = std::time::Instant::now() + Self::QUERY_BUDGET;
        let mut handle = self.connection.lock_handle().await?;
        let cancelled = Arc::new(AtomicBool::new(false));
        let observed = Arc::clone(&cancelled);
        handle.set_progress_handler(1_000, move || {
            !observed.load(Ordering::Acquire) && std::time::Instant::now() < deadline
        });
        Ok(ReadBudget {
            cancelled,
            deadline,
        })
    }

    async fn clear_deadline(&mut self) -> Result<(), StorageError> {
        let mut handle = self.connection.lock_handle().await?;
        handle.remove_progress_handler();
        Ok(())
    }

    fn bounded<T>(budget: &ReadBudget, result: Result<T, StorageError>) -> Result<T, StorageError> {
        match result {
            Ok(_) if std::time::Instant::now() >= budget.deadline => {
                Err(StorageError::QueryBudgetExceeded)
            }
            Ok(value) => Ok(value),
            Err(error)
                if std::time::Instant::now() >= budget.deadline
                    && matches!(error, StorageError::Database(_)) =>
            {
                Err(StorageError::QueryBudgetExceeded)
            }
            Err(error) => Err(error),
        }
    }

    async fn read<T>(
        &mut self,
        operation: impl for<'a> FnOnce(
            &'a mut SqliteConnection,
            &'a Path,
        ) -> std::pin::Pin<
            Box<dyn Future<Output = Result<T, StorageError>> + Send + 'a>,
        >,
    ) -> Result<T, StorageError> {
        let budget = self.deadline().await?;
        let result = operation(&mut self.connection, &self.database_path).await;
        let result = Self::bounded(&budget, result);
        let cleanup = self.clear_deadline().await;
        match result {
            Ok(value) => {
                cleanup?;
                Ok(value)
            }
            Err(error) => Err(error),
        }
    }

    /// Reads an identified snapshot page and its reset predecessor in one transaction.
    ///
    /// # Errors
    /// Returns bounded-query, integrity, and SQLite errors without retaining SQL work.
    pub async fn identified_snapshot_page(
        &mut self,
        query: SnapshotQuery,
        until_unix: i64,
        credential: CredentialId,
        source: SnapshotSource,
        surface: SnapshotSurface,
    ) -> Result<IdentifiedSnapshotPage, StorageError> {
        validate_time(query.since_unix, "snapshot history start")?;
        if query.limit.get() > MAX_SNAPSHOT_HISTORY {
            return Err(StorageError::Input {
                field: "snapshot history limit exceeds 1000",
            });
        }
        self.read(move |connection, path| {
            Box::pin(read_identified_snapshot_transaction(
                connection,
                path,
                query,
                until_unix,
                (credential, source, surface),
            ))
        })
        .await
    }

    /// Reads every overview credential's latest observations in one transaction.
    ///
    /// # Errors
    /// Returns bounded-query, integrity, and SQLite errors without retaining SQL work.
    pub async fn overview(
        &mut self,
        credentials: Vec<OverviewCredentialQuery>,
    ) -> Result<OverviewPage, StorageError> {
        if credentials.len() > 64 {
            return Err(StorageError::Input {
                field: "usage credential count exceeds 64",
            });
        }
        self.read(move |connection, path| {
            Box::pin(read_overview_transaction(connection, path, credentials))
        })
        .await
    }

    /// Starts one deadline for every section of an HTTP report.
    ///
    /// # Errors
    /// Returns SQLite errors while acquiring the read transaction.
    pub async fn report_transaction(&mut self) -> Result<ControlReport<'_>, StorageError> {
        let budget = self.deadline().await?;
        let transaction = self.connection.begin().await?;
        Ok(ControlReport {
            budget,
            database_path: &self.database_path,
            transaction,
        })
    }

    /// Reads filtered request aggregates and totals in one transaction.
    ///
    /// # Errors
    /// Returns bounded-query, range, integrity, and SQLite errors without retaining SQL work.
    pub async fn request_series(
        &mut self,
        query: RequestSeriesQuery,
    ) -> Result<RequestSeriesPage, StorageError> {
        validate_time(query.since_unix, "request series start")?;
        validate_time(query.until_unix, "request series end")?;
        if query.since_unix >= query.until_unix {
            return Err(StorageError::Input {
                field: "request series start must precede end",
            });
        }
        self.read(move |connection, path| {
            Box::pin(read_request_series_transaction(connection, path, query))
        })
        .await
    }

    /// Reads a stable request row page and its totals in one transaction.
    ///
    /// # Errors
    /// Returns bounded-query, integrity, and SQLite errors without retaining SQL work.
    pub async fn request_row_page(
        &mut self,
        query: RequestRowQuery,
    ) -> Result<RequestRowPage, StorageError> {
        validate_time(query.since_unix, "request history start")?;
        validate_time(query.until_unix, "request history end")?;
        if query.since_unix >= query.until_unix {
            return Err(StorageError::Input {
                field: "request history start must precede end",
            });
        }
        self.read(move |connection, path| {
            Box::pin(read_request_row_transaction(connection, path, query))
        })
        .await
    }
}

impl ControlReport<'_> {
    /// Releases the read snapshot and removes its SQLite progress callback.
    ///
    /// # Errors
    /// Returns the report error, query deadline, or SQLite cleanup failure.
    pub async fn finish<T>(self, result: Result<T, StorageError>) -> Result<T, StorageError> {
        let result = ControlReader::bounded(&self.budget, result);
        let mut transaction = self.transaction;
        let cleanup = async {
            let mut handle = transaction.lock_handle().await?;
            handle.remove_progress_handler();
            drop(handle);
            transaction.rollback().await
        }
        .await;
        match result {
            Ok(value) => {
                cleanup?;
                Ok(value)
            }
            Err(error) => Err(error),
        }
    }

    /// Reads report history independently of the control plane.
    ///
    /// # Errors
    /// Propagates bounded-query, integrity, and SQLite errors.
    pub async fn report_provider_snapshot_page(
        &mut self,
        query: SnapshotQuery,
    ) -> Result<SnapshotPage, StorageError> {
        read_provider_snapshot_page(&mut self.transaction, self.database_path, query, None).await
    }

    /// Reads the latest report snapshot for an identified quota series.
    ///
    /// # Errors
    /// Propagates bounded-query, integrity, and SQLite errors.
    pub async fn report_latest_provider_snapshot(
        &mut self,
        provider: ProviderId,
        credential: CredentialId,
        source: SnapshotSource,
        surface: SnapshotSurface,
    ) -> Result<Option<ProviderSnapshot>, StorageError> {
        let page = read_provider_snapshot_page(
            &mut self.transaction,
            self.database_path,
            SnapshotQuery {
                limit: NonZeroU64::MIN,
                provider,
                since_unix: 1,
            },
            Some((credential, source, surface)),
        )
        .await?;
        Ok(page.snapshots.into_iter().next())
    }

    /// Reads bounded report aggregates.
    ///
    /// # Errors
    /// Propagates bounded-query, range, integrity, and SQLite errors.
    pub async fn report_request_usage(
        &mut self,
        query: RequestUsageQuery,
    ) -> Result<Vec<RequestUsageAggregate>, StorageError> {
        read_request_usage(&mut self.transaction, self.database_path, query).await
    }

    /// Reads the durable global count of dropped request events.
    ///
    /// # Errors
    /// Propagates integrity and SQLite errors.
    pub async fn report_request_usage_loss_total(&mut self) -> Result<u64, StorageError> {
        let row = sqlx::query!(
            r#"SELECT COALESCE(SUM(dropped_events), 0) AS "total!: i64" FROM request_events"#
        )
        .fetch_one(&mut *self.transaction)
        .await?;
        stored_count(row.total, self.database_path)
    }

    /// Reads the durable global count of lost provider snapshots.
    ///
    /// # Errors
    /// Propagates integrity and SQLite errors.
    pub async fn report_provider_snapshot_loss_total(&mut self) -> Result<u64, StorageError> {
        let row =
            sqlx::query_scalar!("SELECT lost_snapshots FROM provider_snapshot_losses WHERE id = 1")
                .fetch_optional(&mut *self.transaction)
                .await?;
        stored_count(row.unwrap_or(0), self.database_path)
    }
}

#[derive(Debug, Clone)]
pub struct RequestSeriesQuery {
    pub bucket_seconds: NonZeroU64,
    pub client: Option<Option<ClientId>>,
    pub credential: Option<CredentialId>,
    pub group: Option<GroupId>,
    pub model: Option<String>,
    pub outcome: Option<RequestOutcome>,
    pub provider: Option<ProviderId>,
    pub since_unix: i64,
    pub until_unix: i64,
}

#[derive(Debug)]
pub struct RequestSeriesPage {
    pub aggregates: Vec<RequestSeriesAggregate>,
    pub metadata: ControlMetadata,
}

#[derive(Debug)]
pub struct OverviewCredentialQuery {
    pub credential: CredentialId,
    pub fetch_source: SnapshotSource,
    pub fetch_surface: SnapshotSurface,
    pub header_surface: SnapshotSurface,
    pub provider: ProviderId,
}

#[derive(Debug)]
pub struct OverviewCredentialSnapshots {
    pub credential: CredentialId,
    pub latest_fetch: Option<ProviderSnapshot>,
    pub latest_header: Option<ProviderSnapshot>,
}

#[derive(Debug)]
pub struct OverviewPage {
    pub credentials: Vec<OverviewCredentialSnapshots>,
    pub metadata: ControlMetadata,
}

#[derive(Debug, Clone)]
pub struct RequestRowQuery {
    pub before: Option<RequestRowCursor>,
    pub client: Option<Option<ClientId>>,
    pub credential: Option<CredentialId>,
    pub group: Option<GroupId>,
    pub limit: u64,
    pub model: Option<String>,
    pub outcome: Option<RequestOutcome>,
    pub provider: Option<ProviderId>,
    pub since_unix: i64,
    pub until_unix: i64,
}

impl SqliteStorage {
    /// Retains a dropped typed observation without awaiting SQLite on response forwarding.
    pub fn record_provider_snapshot_loss(&self) {
        add_snapshot_loss(&self.snapshot_losses_pending);
    }

    /// Hands a collected observation to one owned write task. The task alone decides
    /// whether commit succeeded, so cancellation cannot count a committed row as lost.
    pub async fn append_provider_snapshot_observed(&self, snapshot: ProviderSnapshot) {
        let Ok(permit) = Arc::clone(&self.observation_permits).try_acquire_owned() else {
            self.record_provider_snapshot_loss();
            return;
        };
        let connection = Arc::clone(&self.connection);
        let pending = Arc::clone(&self.snapshot_losses_pending);
        let flush_lock = Arc::clone(&self.snapshot_loss_flush_lock);
        let (done_sender, done_receiver) = tokio::sync::oneshot::channel();
        let (_cancel_sender, mut cancel_receiver) = tokio::sync::oneshot::channel::<()>();
        #[cfg(test)]
        let after_commit = self
            .observation_after_commit
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        {
            let mut tasks = self
                .observation_tasks
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            while tasks.try_join_next().is_some() {}
            tasks.spawn(async move {
                let _permit = permit;
                let at_unix = snapshot.fetched_at_unix;
                flush_snapshot_losses(&connection, &pending, &flush_lock, at_unix).await;
                let mut held = connection.lock().await;
                let failed = if matches!(
                    cancel_receiver.try_recv(),
                    Err(tokio::sync::oneshot::error::TryRecvError::Closed)
                ) {
                    true
                } else {
                    append_provider_snapshot_with_connection(&mut held, snapshot)
                        .await
                        .is_err()
                };
                drop(held);
                #[cfg(test)]
                if !failed && let Some((committed, release)) = after_commit {
                    let _ = committed.send(());
                    let _ = release.await;
                }
                if failed {
                    add_snapshot_loss(&pending);
                    tracing::warn!("usage snapshot could not be persisted");
                }
                flush_snapshot_losses(&connection, &pending, &flush_lock, at_unix).await;
                let _ = done_sender.send(());
            });
        }
        let _ = done_receiver.await;
    }

    async fn flush_provider_snapshot_losses(&self, at_unix: i64) {
        flush_snapshot_losses(
            &self.connection,
            &self.snapshot_losses_pending,
            &self.snapshot_loss_flush_lock,
            at_unix,
        )
        .await;
    }

    /// Records previously failed snapshot writes once the database accepts writes again.
    ///
    /// # Errors
    /// Propagates invalid counts, timestamps, and SQLite errors.
    pub async fn record_provider_snapshot_losses(
        &self,
        count: u64,
        at_unix: i64,
    ) -> Result<(), StorageError> {
        record_snapshot_losses_to(&self.connection, count, at_unix).await
    }
    /// Creates or opens private SQLite state and refuses to return a serving handle on corruption.
    ///
    /// # Errors
    ///
    /// Returns I/O, migration, integrity, identity, or connection errors. No handle is exposed
    /// unless `quick_check` succeeds, foreign keys are enabled, and all files are private.
    pub async fn open(
        directory: &Path,
        identities: StorageIdentities,
    ) -> Result<Self, StorageError> {
        validate_identities(&identities)?;
        create_private_directory(directory)?;
        let database_path = directory.join(DATABASE_FILE);
        prepare_database_file(&database_path)?;
        check_private_companions(&database_path)?;

        let options = SqliteConnectOptions::new()
            .filename(&database_path)
            .create_if_missing(false)
            .foreign_keys(true)
            .journal_mode(SqliteJournalMode::Wal)
            .synchronous(SqliteSynchronous::Full)
            .pragma("secure_delete", "ON")
            .busy_timeout(std::time::Duration::ZERO)
            .log_statements(LevelFilter::Off)
            .log_slow_statements(LevelFilter::Off, std::time::Duration::from_secs(1));
        let mut connection = options.connect().await?;
        quick_check(&mut connection, &database_path).await?;
        ensure_foreign_keys(&mut connection, &database_path).await?;
        sqlx::migrate!("./migrations").run(&mut connection).await?;
        quick_check(&mut connection, &database_path).await?;
        ensure_foreign_keys(&mut connection, &database_path).await?;
        seed_identities(&mut connection, identities).await?;
        quick_check(&mut connection, &database_path).await?;
        ensure_foreign_keys(&mut connection, &database_path).await?;
        check_private_companions(&database_path)?;
        let connection = Arc::new(tokio::sync::Mutex::new(connection));
        let (usage_sender, usage_receiver) = tokio::sync::mpsc::channel(1);
        let worker_connection = Arc::clone(&connection);
        let usage_worker = tokio::spawn(async move {
            request_usage_worker(worker_connection, usage_receiver).await;
        });

        Ok(Self {
            connection,
            database_path,
            snapshot_loss_flush_lock: Arc::new(tokio::sync::Mutex::new(())),
            snapshot_losses_pending: Arc::new(AtomicU64::new(0)),
            observation_permits: Arc::new(tokio::sync::Semaphore::new(1)),
            observation_tasks: std::sync::Mutex::new(tokio::task::JoinSet::new()),
            #[cfg(test)]
            observation_after_commit: std::sync::Mutex::new(None),
            usage_sender,
            usage_worker,
        })
    }
}

impl SqliteStorage {
    /// Drains telemetry work and closes the explicitly owned connection.
    ///
    /// # Errors
    ///
    /// Returns the underlying SQLite close error, if any.
    pub async fn close(self) -> Result<(), StorageError> {
        let at_unix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .ok()
            .and_then(|duration| i64::try_from(duration.as_secs()).ok())
            .unwrap_or(1);
        let mut tasks = {
            let mut guard = self
                .observation_tasks
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            std::mem::take(&mut *guard)
        };
        while let Some(result) = tasks.join_next().await {
            if result.is_err() {
                tracing::warn!("usage observation task failed");
            }
        }
        self.flush_provider_snapshot_losses(at_unix).await;
        let Self {
            connection,
            database_path,
            snapshot_loss_flush_lock: _,
            snapshot_losses_pending: _,
            observation_permits: _,
            observation_tasks: _,
            #[cfg(test)]
                observation_after_commit: _,
            usage_sender,
            usage_worker,
        } = self;
        drop(usage_sender);
        usage_worker
            .await
            .map_err(|source| StorageError::UsageWorker {
                path: database_path.clone(),
                source,
            })?;
        let connection = Arc::try_unwrap(connection)
            .map_err(|_| StorageError::ConnectionOwnership {
                path: database_path.clone(),
            })?
            .into_inner();
        connection.close().await?;
        Ok(())
    }
}

impl SqliteStorage {
    /// Replaces a managed OAuth pair when its expected generation still matches.
    ///
    /// # Errors
    ///
    /// Returns input, concurrent-generation, or SQLite errors.
    pub async fn replace_oauth_pair(
        &self,
        replacement: OauthPairReplacement,
    ) -> Result<OauthPairRecord, StorageError> {
        validate_oauth_replacement(&replacement)?;
        let client_id = replacement.client.as_ref();
        let credential_id = replacement.credential.as_ref();
        let mut connection = self.connection.lock().await;
        let mut transaction = connection.begin().await?;
        let existing = sqlx::query!(
            "SELECT generation FROM oauth_mappings WHERE client_id = ? AND credential_id = ?",
            client_id,
            credential_id,
        )
        .fetch_optional(&mut *transaction)
        .await?;
        let expected =
            i64::try_from(replacement.expected_generation).map_err(|_| StorageError::Input {
                field: "OAuth generation is too large",
            })?;
        if (existing.is_none() && expected != 0)
            || existing
                .as_ref()
                .is_some_and(|record| record.generation != expected)
        {
            return Err(StorageError::ConcurrentOauth {
                credential: replacement.credential.clone(),
            });
        }
        let generation =
            persist_oauth_pair(transaction, &replacement, expected, existing.is_some()).await?;
        let client = replacement.client.clone();
        Ok(OauthPairRecord {
            client,
            credential: replacement.credential,
            fake_access_token: replacement.fake_access_token,
            fake_access_expires_at_unix: replacement.fake_access_expires_at_unix,
            fake_refresh_token: replacement.fake_refresh_token,
            generation,
            real_access_token: replacement.real_access_token,
            real_access_expires_at_unix: replacement.real_access_expires_at_unix,
            real_refresh_token: replacement.real_refresh_token,
            real_refresh_expires_at_unix: replacement.real_refresh_expires_at_unix,
            updated_at_unix: replacement.updated_at_unix,
        })
    }

    /// Returns the managed OAuth pair scoped to its client, credential, and provider.
    ///
    /// # Errors
    ///
    /// Returns missing-pair, stored-identity, or SQLite errors.
    pub async fn oauth_pair(
        &self,
        client: &ClientId,
        credential: &CredentialId,
        provider: &ProviderId,
    ) -> Result<OauthPairRecord, StorageError> {
        let client_id = client.as_ref();
        let credential_id = credential.as_ref();
        let provider_id = provider.as_ref();
        let record = sqlx::query!(
            r"
            SELECT mappings.client_id, mappings.credential_id, credentials.provider_id,
                   mappings.generation, mappings.fake_access_token, mappings.fake_refresh_token,
                   mappings.fake_access_expires_at_unix,
                   mappings.updated_at_unix AS mapping_updated_at_unix,
                   tokens.access_token, tokens.refresh_token,
                   tokens.refresh_token_expires_at_unix,
                   tokens.access_expires_at_unix,
                   tokens.updated_at_unix AS real_updated_at_unix
            FROM oauth_mappings AS mappings
            JOIN credentials
              ON credentials.id = mappings.credential_id
            JOIN oauth_tokens AS tokens
              ON tokens.credential_id = mappings.credential_id
            WHERE mappings.client_id = ? AND mappings.credential_id = ?
              AND credentials.provider_id = ?
            ",
            client_id,
            credential_id,
            provider_id,
        )
        .fetch_optional(&mut *self.connection.lock().await)
        .await?
        .ok_or_else(|| StorageError::MissingOauthPair {
            credential: credential.clone(),
            provider: provider.clone(),
        })?;
        let stored_client =
            ClientId::try_from(record.client_id).map_err(|_| StorageError::StoredIdentity {
                credential: credential.clone(),
            })?;
        let stored_credential = CredentialId::try_from(record.credential_id).map_err(|_| {
            StorageError::StoredIdentity {
                credential: credential.clone(),
            }
        })?;
        let stored_provider =
            ProviderId::try_from(record.provider_id).map_err(|error| StorageError::StoredId {
                kind: "provider",
                value: error.into_name(),
            })?;
        if stored_client != *client
            || stored_credential != *credential
            || stored_provider != *provider
            || record.mapping_updated_at_unix != record.real_updated_at_unix
        {
            return Err(StorageError::StoredIdentity {
                credential: credential.clone(),
            });
        }
        let generation = record
            .generation
            .try_into()
            .map_err(|_| StorageError::Integrity {
                path: self.database_path.clone(),
            })?;
        Ok(OauthPairRecord {
            client: stored_client,
            credential: stored_credential,
            fake_access_token: TokenMaterial::new(record.fake_access_token)?,
            fake_access_expires_at_unix: record.fake_access_expires_at_unix,
            fake_refresh_token: TokenMaterial::new(record.fake_refresh_token)?,
            generation,
            real_access_token: TokenMaterial::new(record.access_token)?,
            real_access_expires_at_unix: record.access_expires_at_unix,
            real_refresh_token: TokenMaterial::new(record.refresh_token)?,
            real_refresh_expires_at_unix: record.refresh_token_expires_at_unix,
            updated_at_unix: record.mapping_updated_at_unix,
        })
    }

    /// Retires a matching managed OAuth pair.
    ///
    /// # Errors
    ///
    /// Returns input, missing-pair, concurrent-generation, or SQLite errors.
    pub async fn retire_oauth_pair(
        &self,
        retirement: OauthPairRetirement,
    ) -> Result<(), StorageError> {
        let expected =
            i64::try_from(retirement.expected_generation).map_err(|_| StorageError::Input {
                field: "OAuth generation is too large",
            })?;
        if expected <= 0 {
            return Err(StorageError::Input {
                field: "OAuth retirement generation must be positive",
            });
        }
        let client_id = retirement.client.as_ref();
        let credential_id = retirement.credential.as_ref();
        let provider_id = retirement.provider.as_ref();
        let fake_refresh_token = retirement.fake_refresh_token.as_str();
        let mut connection = self.connection.lock().await;
        let mut transaction = connection.begin().await?;
        let owned = sqlx::query!(
            r"
            SELECT mappings.generation, mappings.fake_refresh_token
            FROM oauth_mappings AS mappings
            JOIN credentials ON credentials.id = mappings.credential_id
            WHERE mappings.client_id = ? AND mappings.credential_id = ?
              AND credentials.provider_id = ?
            ",
            client_id,
            credential_id,
            provider_id,
        )
        .fetch_optional(&mut *transaction)
        .await?;
        let Some(owned) = owned else {
            return Err(StorageError::MissingOauthPair {
                credential: retirement.credential.clone(),
                provider: retirement.provider.clone(),
            });
        };
        let stored_refresh = TokenMaterial::new(owned.fake_refresh_token)?;
        if owned.generation != expected || !stored_refresh.matches(fake_refresh_token.as_bytes()) {
            return Err(StorageError::ConcurrentOauth {
                credential: retirement.credential.clone(),
            });
        }
        sqlx::query!(
            "DELETE FROM oauth_mappings WHERE client_id = ? AND credential_id = ?",
            client_id,
            credential_id,
        )
        .execute(&mut *transaction)
        .await?;
        sqlx::query!(
            "DELETE FROM oauth_tokens WHERE credential_id = ?",
            credential_id,
        )
        .execute(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(())
    }

    /// Appends one request event through the bounded usage worker.
    ///
    /// # Errors
    ///
    /// Returns input errors, `UsageUnavailable` for queue or worker contention, or the durable write result.
    pub async fn try_append_request_event(&self, event: RequestEvent) -> Result<(), StorageError> {
        validate_request_event(&event)?;
        let (acknowledgement, receipt) = tokio::sync::oneshot::channel();
        self.usage_sender
            .try_send((event, acknowledgement))
            .map_err(|_| StorageError::UsageUnavailable)?;
        receipt.await.map_err(|_| StorageError::UsageUnavailable)?
    }

    /// Returns bounded request-usage aggregates for a group and time range.
    ///
    /// # Errors
    ///
    /// Returns input, aggregate-bound, integrity, or SQLite errors.
    pub async fn request_usage(
        &self,
        query: RequestUsageQuery,
    ) -> Result<Vec<RequestUsageAggregate>, StorageError> {
        let mut connection = self.connection.lock().await;
        read_request_usage(&mut connection, &self.database_path, query).await
    }

    /// Returns the lifetime total of dropped request events.
    ///
    /// # Errors
    ///
    /// Returns integrity or SQLite errors.
    pub async fn request_usage_loss_total(&self) -> Result<u64, StorageError> {
        let row = sqlx::query!(
            r#"SELECT COALESCE(SUM(dropped_events), 0) AS "total!: i64" FROM request_events"#
        )
        .fetch_one(&mut *self.connection.lock().await)
        .await?;
        stored_count(row.total, &self.database_path)
    }

    /// Appends one typed provider snapshot.
    ///
    /// # Errors
    ///
    /// Returns input, integrity, or SQLite errors.
    pub async fn append_provider_snapshot(
        &self,
        snapshot: ProviderSnapshot,
    ) -> Result<(), StorageError> {
        append_provider_snapshot_to(&self.connection, snapshot).await
    }

    /// Returns bounded provider-snapshot history.
    ///
    /// # Errors
    ///
    /// Returns input, history-bound, integrity, or SQLite errors.
    pub async fn provider_snapshots(
        &self,
        query: SnapshotQuery,
    ) -> Result<Vec<ProviderSnapshot>, StorageError> {
        let mut connection = self.connection.lock().await;
        read_provider_snapshots(&mut connection, &self.database_path, query).await
    }
}

fn add_snapshot_loss(pending: &AtomicU64) {
    let _ = pending.try_update(Ordering::Relaxed, Ordering::Relaxed, |count| {
        Some(count.saturating_add(1).min(i64::MAX.unsigned_abs()))
    });
}

async fn flush_snapshot_losses(
    connection: &Arc<tokio::sync::Mutex<SqliteConnection>>,
    pending: &AtomicU64,
    flush_lock: &tokio::sync::Mutex<()>,
    at_unix: i64,
) {
    let _flush_guard = flush_lock.lock().await;
    let count = pending.load(Ordering::Acquire);
    if count == 0 {
        return;
    }
    if record_snapshot_losses_to(connection, count, at_unix)
        .await
        .is_ok()
    {
        pending.fetch_sub(count, Ordering::AcqRel);
    } else {
        tracing::warn!("usage snapshot loss signal could not be persisted");
    }
}

async fn record_snapshot_losses_to(
    connection: &Arc<tokio::sync::Mutex<SqliteConnection>>,
    count: u64,
    at_unix: i64,
) -> Result<(), StorageError> {
    validate_time(at_unix, "provider loss time")?;
    let count = i64::try_from(count).map_err(|_| StorageError::Input {
        field: "provider loss count",
    })?;
    sqlx::query!(
        "INSERT INTO provider_snapshot_losses (id, lost_snapshots, last_loss_at_unix) VALUES (1, ?, ?) \
         ON CONFLICT(id) DO UPDATE SET lost_snapshots = CASE \
           WHEN lost_snapshots > 9223372036854775807 - excluded.lost_snapshots THEN 9223372036854775807 \
           ELSE lost_snapshots + excluded.lost_snapshots END, \
         last_loss_at_unix = excluded.last_loss_at_unix",
        count,
        at_unix,
    )
    .execute(&mut *connection.lock().await)
    .await?;
    Ok(())
}

async fn append_provider_snapshot_to(
    connection: &Arc<tokio::sync::Mutex<SqliteConnection>>,
    snapshot: ProviderSnapshot,
) -> Result<(), StorageError> {
    let mut held = connection.lock().await;
    append_provider_snapshot_with_connection(&mut held, snapshot).await
}

async fn append_provider_snapshot_with_connection(
    connection: &mut SqliteConnection,
    snapshot: ProviderSnapshot,
) -> Result<(), StorageError> {
    validate_time(snapshot.fetched_at_unix, "snapshot time")?;
    validate_label(&snapshot.account_id, "account ID")?;
    validate_provider_snapshot(&snapshot)?;
    let provider_id = snapshot.provider.as_ref();
    let fetch_status = snapshot.fetch_status.as_storage();
    let mut transaction = connection.begin().await?;
    let client_id = snapshot.client.as_ref().map(AsRef::as_ref);
    let group_id = snapshot.group.as_ref().map(AsRef::as_ref);
    let credential_id = snapshot.credential.as_ref();
    let source = snapshot.source.as_storage();
    let surface = snapshot.surface.as_storage();
    sqlx::query!(
        r"
            INSERT INTO provider_snapshots
              (fetched_at_unix, provider_id, client_id, group_id, credential_id,
               account_id, source, surface, fetch_status, gap_reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ",
        snapshot.fetched_at_unix,
        provider_id,
        client_id,
        group_id,
        credential_id,
        snapshot.account_id,
        source,
        surface,
        fetch_status,
        snapshot.gap_reason,
    )
    .execute(&mut *transaction)
    .await?;
    let snapshot_id = sqlx::query!("SELECT last_insert_rowid() AS id")
        .fetch_one(&mut *transaction)
        .await?
        .id;

    insert_quota_pools(&mut transaction, snapshot_id, &snapshot.pools).await?;
    insert_credit_pools(&mut transaction, snapshot_id, &snapshot.credits).await?;
    insert_quota_metrics(&mut transaction, snapshot_id, &snapshot.metrics).await?;
    insert_claude_limits(&mut transaction, snapshot_id, &snapshot.claude_limits).await?;
    insert_response_windows(&mut transaction, snapshot_id, &snapshot.header_windows).await?;
    transaction.commit().await?;
    Ok(())
}

#[expect(
    clippy::too_many_lines,
    reason = "compile-checked aggregate SQL and its validated projection share this boundary"
)]
async fn read_request_usage(
    connection: &mut SqliteConnection,
    database_path: &Path,
    query: RequestUsageQuery,
) -> Result<Vec<RequestUsageAggregate>, StorageError> {
    validate_time(query.since_unix, "usage range start")?;
    validate_time(query.until_unix, "usage range end")?;
    if query.since_unix >= query.until_unix {
        return Err(StorageError::Input {
            field: "usage range start must precede end",
        });
    }
    let bucket_seconds =
        i64::try_from(query.bucket_seconds.get()).map_err(|_| StorageError::Input {
            field: "usage bucket seconds is too large",
        })?;
    let group_id = query.group.as_ref();
    let aggregate_limit =
        i64::try_from(MAX_AGGREGATE_ROWS + 1).map_err(|_| StorageError::Input {
            field: "usage aggregate limit is too large",
        })?;
    let rows = sqlx::query!(
        r#"
            SELECT credentials.provider_id AS provider_id, request_events.client_id,
                   request_events.credential_id,
                   CAST(occurred_at_unix / ? AS INTEGER) * ? AS "bucket_start_unix!: i64",
                   model_id, outcome, COUNT(*) AS "events!: i64",
                   SUM(CASE WHEN usage_complete THEN 1 ELSE 0 END)
                     AS "complete_events!: i64",
                   SUM(CASE WHEN status_code >= 400 THEN 1 ELSE 0 END)
                     AS "error_events!: i64",
                   SUM(CASE WHEN status_code BETWEEN 200 AND 299 THEN 1 ELSE 0 END)
                     AS "successful_events!: i64",
                   SUM(request_bytes) AS "request_bytes!: i64",
                   SUM(response_bytes) AS "response_bytes!: i64",
                   SUM(latency_ms) AS "latency_ms!: i64",
                   SUM(input_tokens) AS "input_tokens?: i64",
                   SUM(output_tokens) AS "output_tokens?: i64",
                   SUM(cache_read_tokens) AS "cache_read_tokens?: i64",
                   SUM(cache_write_tokens) AS "cache_write_tokens?: i64",
                   SUM(CASE WHEN input_tokens IS NULL THEN 1 ELSE 0 END)
                     AS "missing_input_tokens!: i64",
                   SUM(CASE WHEN output_tokens IS NULL THEN 1 ELSE 0 END)
                     AS "missing_output_tokens!: i64",
                   SUM(CASE WHEN cache_read_tokens IS NULL THEN 1 ELSE 0 END)
                     AS "missing_cache_read_tokens!: i64",
                   SUM(CASE WHEN cache_write_tokens IS NULL THEN 1 ELSE 0 END)
                     AS "missing_cache_write_tokens!: i64"
            FROM request_events
            JOIN credentials ON credentials.id = request_events.credential_id
            WHERE group_id = ? AND occurred_at_unix >= ? AND occurred_at_unix < ?
            GROUP BY credentials.provider_id, request_events.client_id,
                     request_events.credential_id,
                     CAST(occurred_at_unix / ? AS INTEGER) * ?, model_id, outcome
            ORDER BY credentials.provider_id, request_events.client_id,
                     request_events.credential_id,
                     CAST(occurred_at_unix / ? AS INTEGER) * ?, model_id, outcome
            LIMIT ?
            "#,
        bucket_seconds,
        bucket_seconds,
        group_id,
        query.since_unix,
        query.until_unix,
        bucket_seconds,
        bucket_seconds,
        bucket_seconds,
        bucket_seconds,
        aggregate_limit,
    )
    .fetch_all(&mut *connection)
    .await?;
    if rows.len() > MAX_AGGREGATE_ROWS {
        return Err(StorageError::UsageRangeIncomplete);
    }

    let mut aggregates = Vec::with_capacity(rows.len());
    for row in rows {
        let credential =
            CredentialId::try_from(row.credential_id).map_err(|error| StorageError::StoredId {
                kind: "credential",
                value: error.into_name(),
            })?;
        let client = row
            .client_id
            .map(|id| {
                ClientId::try_from(id).map_err(|error| StorageError::StoredId {
                    kind: "client",
                    value: error.into_name(),
                })
            })
            .transpose()?;
        let provider =
            ProviderId::try_from(row.provider_id).map_err(|error| StorageError::StoredId {
                kind: "provider",
                value: error.into_name(),
            })?;
        let outcome =
            RequestOutcome::from_storage(&row.outcome).ok_or_else(|| StorageError::Integrity {
                path: database_path.to_owned(),
            })?;
        aggregates.push(RequestUsageAggregate {
            bucket_start_unix: if row.bucket_start_unix >= 0 {
                row.bucket_start_unix
            } else {
                return Err(StorageError::Integrity {
                    path: database_path.to_owned(),
                });
            },
            cache_read_tokens: complete_sum(
                row.cache_read_tokens,
                row.missing_cache_read_tokens,
                database_path,
            )?,
            cache_write_tokens: complete_sum(
                row.cache_write_tokens,
                row.missing_cache_write_tokens,
                database_path,
            )?,
            client,
            complete_events: stored_count(row.complete_events, database_path)?,
            credential,
            error_events: stored_count(row.error_events, database_path)?,
            events: stored_count(row.events, database_path)?,
            input_tokens: complete_sum(row.input_tokens, row.missing_input_tokens, database_path)?,
            latency_ms: stored_count(row.latency_ms, database_path)?,
            model: row.model_id,
            outcome,
            output_tokens: complete_sum(
                row.output_tokens,
                row.missing_output_tokens,
                database_path,
            )?,
            provider,
            request_bytes: stored_count(row.request_bytes, database_path)?,
            response_bytes: stored_count(row.response_bytes, database_path)?,
            successful_events: stored_count(row.successful_events, database_path)?,
        });
    }
    Ok(aggregates)
}

async fn control_metadata(
    connection: &mut SqliteConnection,
    database_path: &Path,
) -> Result<ControlMetadata, StorageError> {
    let request_loss_total = sqlx::query!(
        r#"SELECT COALESCE(SUM(dropped_events), 0) AS "total!: i64" FROM request_events"#
    )
    .fetch_one(&mut *connection)
    .await?;
    let provider_loss_total =
        sqlx::query_scalar!("SELECT lost_snapshots FROM provider_snapshot_losses WHERE id = 1")
            .fetch_optional(&mut *connection)
            .await?;
    Ok(ControlMetadata {
        provider_snapshot_loss_total: stored_count(
            provider_loss_total.unwrap_or(0),
            database_path,
        )?,
        request_loss_total: stored_count(request_loss_total.total, database_path)?,
    })
}

#[expect(
    clippy::too_many_lines,
    reason = "compile-checked aggregate SQL and its validated projection share this boundary"
)]
async fn read_request_series_transaction(
    connection: &mut SqliteConnection,
    database_path: &Path,
    query: RequestSeriesQuery,
) -> Result<RequestSeriesPage, StorageError> {
    let bucket_seconds =
        i64::try_from(query.bucket_seconds.get()).map_err(|_| StorageError::Input {
            field: "request bucket seconds is too large",
        })?;
    let aggregate_limit =
        i64::try_from(MAX_AGGREGATE_ROWS + 1).map_err(|_| StorageError::Input {
            field: "usage aggregate limit is too large",
        })?;
    let client_filter = query.client.is_some();
    let client_value = query.client.flatten().map(|id| id.as_ref().to_owned());
    let client_value = client_value.as_deref();
    let credential = query.credential.as_ref().map(AsRef::as_ref);
    let group = query.group.as_ref().map(AsRef::as_ref);
    let model = query.model.as_deref();
    let outcome = query.outcome.map(RequestOutcome::as_storage);
    let provider = query.provider.as_ref().map(AsRef::as_ref);
    let mut transaction = connection.begin().await?;
    let rows = sqlx::query!(
        r#"
        SELECT group_id, credentials.provider_id AS provider_id, request_events.client_id,
               request_events.credential_id,
               CAST(occurred_at_unix / ? AS INTEGER) * ? AS "bucket_start_unix!: i64",
               model_id, outcome, COUNT(*) AS "events!: i64",
               SUM(CASE WHEN usage_complete THEN 1 ELSE 0 END)
                 AS "complete_events!: i64",
               SUM(CASE WHEN status_code >= 400 THEN 1 ELSE 0 END)
                 AS "error_events!: i64",
               SUM(CASE WHEN status_code BETWEEN 200 AND 299 THEN 1 ELSE 0 END)
                 AS "successful_events!: i64",
               SUM(request_bytes) AS "request_bytes!: i64",
               SUM(response_bytes) AS "response_bytes!: i64",
               SUM(latency_ms) AS "latency_ms!: i64",
               SUM(input_tokens) AS "input_tokens?: i64",
               SUM(output_tokens) AS "output_tokens?: i64",
               SUM(cache_read_tokens) AS "cache_read_tokens?: i64",
               SUM(cache_write_tokens) AS "cache_write_tokens?: i64",
               SUM(CASE WHEN input_tokens IS NULL THEN 1 ELSE 0 END)
                 AS "missing_input_tokens!: i64",
               SUM(CASE WHEN output_tokens IS NULL THEN 1 ELSE 0 END)
                 AS "missing_output_tokens!: i64",
               SUM(CASE WHEN cache_read_tokens IS NULL THEN 1 ELSE 0 END)
                 AS "missing_cache_read_tokens!: i64",
               SUM(CASE WHEN cache_write_tokens IS NULL THEN 1 ELSE 0 END)
                 AS "missing_cache_write_tokens!: i64"
        FROM request_events
        JOIN credentials ON credentials.id = request_events.credential_id
        WHERE occurred_at_unix >= ? AND occurred_at_unix < ?
          AND (? = 0 OR client_id IS ?)
          AND (? IS NULL OR credential_id = ?)
          AND (? IS NULL OR group_id = ?)
          AND (? IS NULL OR model_id = ?)
          AND (? IS NULL OR outcome = ?)
          AND (? IS NULL OR credentials.provider_id = ?)
        GROUP BY group_id, credentials.provider_id, request_events.client_id,
                 request_events.credential_id,
                 CAST(occurred_at_unix / ? AS INTEGER) * ?, model_id, outcome
        ORDER BY group_id, credentials.provider_id, request_events.client_id,
                 request_events.credential_id,
                 CAST(occurred_at_unix / ? AS INTEGER) * ?, model_id, outcome
        LIMIT ?
        "#,
        bucket_seconds,
        bucket_seconds,
        query.since_unix,
        query.until_unix,
        client_filter,
        client_value,
        credential,
        credential,
        group,
        group,
        model,
        model,
        outcome,
        outcome,
        provider,
        provider,
        bucket_seconds,
        bucket_seconds,
        bucket_seconds,
        bucket_seconds,
        aggregate_limit,
    )
    .fetch_all(&mut *transaction)
    .await?;
    if rows.len() > MAX_AGGREGATE_ROWS {
        return Err(StorageError::UsageRangeIncomplete);
    }
    let mut aggregates = Vec::with_capacity(rows.len());
    for row in rows {
        let credential =
            CredentialId::try_from(row.credential_id).map_err(|error| StorageError::StoredId {
                kind: "credential",
                value: error.into_name(),
            })?;
        let client = row
            .client_id
            .map(|id| {
                ClientId::try_from(id).map_err(|error| StorageError::StoredId {
                    kind: "client",
                    value: error.into_name(),
                })
            })
            .transpose()?;
        let group = GroupId::try_from(row.group_id).map_err(|error| StorageError::StoredId {
            kind: "group",
            value: error.into_name(),
        })?;
        let provider =
            ProviderId::try_from(row.provider_id).map_err(|error| StorageError::StoredId {
                kind: "provider",
                value: error.into_name(),
            })?;
        let outcome =
            RequestOutcome::from_storage(&row.outcome).ok_or_else(|| StorageError::Integrity {
                path: database_path.to_owned(),
            })?;
        let aggregate = RequestUsageAggregate {
            bucket_start_unix: if row.bucket_start_unix >= 0 {
                row.bucket_start_unix
            } else {
                return Err(StorageError::Integrity {
                    path: database_path.to_owned(),
                });
            },
            cache_read_tokens: complete_sum(
                row.cache_read_tokens,
                row.missing_cache_read_tokens,
                database_path,
            )?,
            cache_write_tokens: complete_sum(
                row.cache_write_tokens,
                row.missing_cache_write_tokens,
                database_path,
            )?,
            client,
            complete_events: stored_count(row.complete_events, database_path)?,
            credential,
            error_events: stored_count(row.error_events, database_path)?,
            events: stored_count(row.events, database_path)?,
            input_tokens: complete_sum(row.input_tokens, row.missing_input_tokens, database_path)?,
            latency_ms: stored_count(row.latency_ms, database_path)?,
            model: row.model_id,
            outcome,
            output_tokens: complete_sum(
                row.output_tokens,
                row.missing_output_tokens,
                database_path,
            )?,
            provider,
            request_bytes: stored_count(row.request_bytes, database_path)?,
            response_bytes: stored_count(row.response_bytes, database_path)?,
            successful_events: stored_count(row.successful_events, database_path)?,
        };
        aggregates.push(RequestSeriesAggregate { aggregate, group });
    }
    let metadata = control_metadata(&mut transaction, database_path).await?;
    transaction.rollback().await?;
    Ok(RequestSeriesPage {
        aggregates,
        metadata,
    })
}

async fn read_overview_transaction(
    connection: &mut SqliteConnection,
    database_path: &Path,
    credentials: Vec<OverviewCredentialQuery>,
) -> Result<OverviewPage, StorageError> {
    let mut transaction = connection.begin().await?;
    let mut views = Vec::with_capacity(credentials.len());
    for credential in credentials {
        let query = SnapshotQuery {
            limit: NonZeroU64::MIN,
            provider: credential.provider,
            since_unix: 1,
        };
        let latest_fetch = read_provider_snapshot_page(
            &mut transaction,
            database_path,
            query.clone(),
            Some((
                credential.credential.clone(),
                credential.fetch_source,
                credential.fetch_surface,
            )),
        )
        .await?
        .snapshots
        .into_iter()
        .next();
        let latest_header = read_provider_snapshot_page(
            &mut transaction,
            database_path,
            query,
            Some((
                credential.credential.clone(),
                SnapshotSource::ResponseHeaders,
                credential.header_surface,
            )),
        )
        .await?
        .snapshots
        .into_iter()
        .next();
        views.push(OverviewCredentialSnapshots {
            credential: credential.credential,
            latest_fetch,
            latest_header,
        });
    }
    let metadata = control_metadata(&mut transaction, database_path).await?;
    transaction.rollback().await?;
    Ok(OverviewPage {
        credentials: views,
        metadata,
    })
}

#[allow(clippy::too_many_arguments)]
fn provider_snapshot_from_header(
    fetched_at_unix: i64,
    provider_id: String,
    client_id: Option<String>,
    group_id: Option<String>,
    credential_id: String,
    account_id: String,
    source: &str,
    surface: &str,
    fetch_status: &str,
    gap_reason: Option<String>,
    pools: Vec<QuotaPool>,
    credits: Vec<CreditPool>,
    metrics: Vec<QuotaMetric>,
    claude_limits: Vec<ClaudeLimit>,
    header_windows: Vec<ResponseHeaderWindow>,
    database_path: &Path,
) -> Result<ProviderSnapshot, StorageError> {
    let provider = ProviderId::try_from(provider_id).map_err(|error| StorageError::StoredId {
        kind: "provider",
        value: error.into_name(),
    })?;
    let client = client_id
        .map(ClientId::try_from)
        .transpose()
        .map_err(|error| StorageError::StoredId {
            kind: "client",
            value: error.into_name(),
        })?;
    let group = group_id
        .map(GroupId::try_from)
        .transpose()
        .map_err(|error| StorageError::StoredId {
            kind: "group",
            value: error.into_name(),
        })?;
    let credential =
        CredentialId::try_from(credential_id).map_err(|error| StorageError::StoredId {
            kind: "credential",
            value: error.into_name(),
        })?;
    let source = SnapshotSource::from_storage(source).ok_or_else(|| StorageError::Integrity {
        path: database_path.to_owned(),
    })?;
    let surface =
        SnapshotSurface::from_storage(surface).ok_or_else(|| StorageError::Integrity {
            path: database_path.to_owned(),
        })?;
    let fetch_status =
        SnapshotFetchStatus::from_storage(fetch_status).ok_or_else(|| StorageError::Integrity {
            path: database_path.to_owned(),
        })?;
    Ok(ProviderSnapshot {
        account_id,
        client,
        claude_limits,
        credential,
        credits,
        fetched_at_unix,
        fetch_status,
        gap_reason,
        group,
        header_windows,
        metrics,
        pools,
        provider,
        source,
        surface,
    })
}

#[allow(clippy::too_many_arguments)]
fn request_row_from_header(
    id: i64,
    occurred_at_unix: i64,
    client_id: Option<String>,
    group_id: String,
    credential_id: String,
    provider_id: String,
    model_id: String,
    outcome: &str,
    status_code: i64,
    latency_ms: i64,
    request_bytes: i64,
    response_bytes: i64,
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
    cache_read_tokens: Option<i64>,
    cache_write_tokens: Option<i64>,
    usage_complete: i64,
    database_path: &Path,
) -> Result<RequestRow, StorageError> {
    let client = client_id
        .map(ClientId::try_from)
        .transpose()
        .map_err(|error| StorageError::StoredId {
            kind: "client",
            value: error.into_name(),
        })?;
    let group = GroupId::try_from(group_id).map_err(|error| StorageError::StoredId {
        kind: "group",
        value: error.into_name(),
    })?;
    let credential =
        CredentialId::try_from(credential_id).map_err(|error| StorageError::StoredId {
            kind: "credential",
            value: error.into_name(),
        })?;
    let provider = ProviderId::try_from(provider_id).map_err(|error| StorageError::StoredId {
        kind: "provider",
        value: error.into_name(),
    })?;
    let outcome = RequestOutcome::from_storage(outcome).ok_or_else(|| StorageError::Integrity {
        path: database_path.to_owned(),
    })?;
    if !(0..=65535).contains(&status_code) {
        return Err(StorageError::Integrity {
            path: database_path.to_owned(),
        });
    }
    Ok(RequestRow {
        cache_read_tokens: stored_optional_count(cache_read_tokens, database_path)?,
        cache_write_tokens: stored_optional_count(cache_write_tokens, database_path)?,
        client,
        credential,
        group,
        id,
        input_tokens: stored_optional_count(input_tokens, database_path)?,
        latency_ms: stored_count(latency_ms, database_path)?,
        model: model_id,
        occurred_at_unix,
        outcome,
        output_tokens: stored_optional_count(output_tokens, database_path)?,
        provider,
        request_bytes: stored_count(request_bytes, database_path)?,
        response_bytes: stored_count(response_bytes, database_path)?,
        status_code: u16::try_from(status_code).map_err(|_| StorageError::Integrity {
            path: database_path.to_owned(),
        })?,
        usage_complete: usage_complete != 0,
    })
}

async fn read_identified_snapshot_transaction(
    connection: &mut SqliteConnection,
    database_path: &Path,
    query: SnapshotQuery,
    until_unix: i64,
    filter: (CredentialId, SnapshotSource, SnapshotSurface),
) -> Result<IdentifiedSnapshotPage, StorageError> {
    let mut transaction = connection.begin().await?;
    let limit = usize::try_from(query.limit.get()).map_err(|_| StorageError::Input {
        field: "snapshot history limit is too large",
    })?;
    let fetch_limit = i64::try_from(limit.saturating_add(1)).map_err(|_| StorageError::Input {
        field: "snapshot history limit is too large",
    })?;
    let (credential, source, surface) = filter;
    let provider_id = query.provider.as_ref();
    let credential_id = credential.as_ref();
    let source_id = source.as_storage();
    let surface_id = surface.as_storage();
    let mut headers = sqlx::query!(
        r#"
        SELECT id AS "id!: i64", fetched_at_unix, provider_id, client_id, group_id,
               credential_id, account_id, source, surface, fetch_status, gap_reason
        FROM provider_snapshots
        WHERE provider_id = ? AND fetched_at_unix < ?
          AND credential_id = ? AND source = ? AND surface = ?
        ORDER BY fetched_at_unix DESC, id DESC
        LIMIT ?
        "#,
        provider_id,
        until_unix,
        credential_id,
        source_id,
        surface_id,
        fetch_limit,
    )
    .fetch_all(&mut *transaction)
    .await?;
    let visible = headers
        .iter()
        .take(limit)
        .take_while(|header| header.fetched_at_unix >= query.since_unix)
        .count();
    let truncated = headers
        .get(limit)
        .is_some_and(|header| header.fetched_at_unix >= query.since_unix);
    headers.truncate(visible + usize::from(headers.len() > visible));
    let ids = headers.iter().map(|header| header.id).collect::<Vec<_>>();
    let mut quota_pools = quota_pools_many(&mut transaction, &ids, database_path).await?;
    let mut credit_pools = credit_pools_many(&mut transaction, &ids, database_path).await?;
    let mut quota_metrics = quota_metrics_many(&mut transaction, &ids, database_path).await?;
    let mut claude_limits = claude_limits_many(&mut transaction, &ids, database_path).await?;
    let mut response_windows = response_windows_many(&mut transaction, &ids, database_path).await?;
    let mut snapshots = Vec::with_capacity(headers.len());
    for header in headers {
        let pools = quota_pools.remove(&header.id).unwrap_or_default();
        let credits = credit_pools.remove(&header.id).unwrap_or_default();
        let metrics = quota_metrics.remove(&header.id).unwrap_or_default();
        let claude_limits = claude_limits.remove(&header.id).unwrap_or_default();
        let header_windows = response_windows.remove(&header.id).unwrap_or_default();
        snapshots.push(IdentifiedSnapshot {
            id: header.id,
            snapshot: provider_snapshot_from_header(
                header.fetched_at_unix,
                header.provider_id,
                header.client_id,
                header.group_id,
                header.credential_id,
                header.account_id,
                &header.source,
                &header.surface,
                &header.fetch_status,
                header.gap_reason,
                pools,
                credits,
                metrics,
                claude_limits,
                header_windows,
                database_path,
            )?,
        });
    }
    let metadata = control_metadata(&mut transaction, database_path).await?;
    transaction.rollback().await?;
    let predecessor = if snapshots.len() > visible {
        snapshots.pop()
    } else {
        None
    };
    snapshots.reverse();
    Ok(IdentifiedSnapshotPage {
        metadata,
        snapshots,
        predecessor,
        truncated,
    })
}

#[expect(
    clippy::too_many_lines,
    reason = "one transaction loads request rows and freezes the page cursor together"
)]
async fn read_request_row_transaction(
    connection: &mut SqliteConnection,
    database_path: &Path,
    query: RequestRowQuery,
) -> Result<RequestRowPage, StorageError> {
    if query.limit == 0 || query.limit > 200 {
        return Err(StorageError::Input {
            field: "request page limit must be 1..=200",
        });
    }
    let mut transaction = connection.begin().await?;
    let limit = usize::try_from(query.limit).map_err(|_| StorageError::Input {
        field: "request page limit is too large",
    })?;
    let fetch_limit = i64::try_from(limit.saturating_add(1)).map_err(|_| StorageError::Input {
        field: "request page limit is too large",
    })?;
    let client_filter = query.client.is_some();
    let client_value = query.client.flatten().map(|id| id.as_ref().to_owned());
    let client_value = client_value.as_deref();
    let credential = query.credential.as_ref().map(AsRef::as_ref);
    let group = query.group.as_ref().map(AsRef::as_ref);
    let model = query.model.as_deref();
    let outcome = query.outcome.map(RequestOutcome::as_storage);
    let provider = query.provider.as_ref().map(AsRef::as_ref);
    let cursor = query.before;
    let committed_cutoff =
        sqlx::query!(r#"SELECT COALESCE(MAX(id), 0) AS "cutoff!: i64" FROM request_events"#)
            .fetch_one(&mut *transaction)
            .await?
            .cutoff;
    let cursor_cutoff = cursor.map(|value| value.cutoff_id.max(value.row_id));
    let cursor_time = cursor.map(|value| value.occurred_at_unix);
    let cursor_id = cursor.map(|value| value.row_id);
    let rows = sqlx::query!(
        r#"
        SELECT request_events.id AS "id!: i64", occurred_at_unix, client_id, group_id,
               credential_id, credentials.provider_id AS "provider_id!: String", model_id,
               outcome, status_code AS "status_code!: i64", latency_ms AS "latency_ms!: i64",
               request_bytes AS "request_bytes!: i64", response_bytes AS "response_bytes!: i64",
               input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
               usage_complete AS "usage_complete!: i64"
        FROM request_events
        JOIN credentials ON credentials.id = request_events.credential_id
        WHERE occurred_at_unix >= ? AND occurred_at_unix < ?
          AND (? = 0 OR client_id IS ?)
          AND (? IS NULL OR credential_id = ?)
          AND (? IS NULL OR group_id = ?)
          AND (? IS NULL OR model_id = ?)
          AND (? IS NULL OR outcome = ?)
          AND (? IS NULL OR credentials.provider_id = ?)
          AND (? IS NULL OR request_events.id <= ?)
          AND (? IS NULL OR occurred_at_unix < ? OR (occurred_at_unix = ? AND request_events.id < ?))
        ORDER BY occurred_at_unix DESC, request_events.id DESC
        LIMIT ?
        "#,
        query.since_unix,
        query.until_unix,
        client_filter,
        client_value,
        credential,
        credential,
        group,
        group,
        model,
        model,
        outcome,
        outcome,
        provider,
        provider,
        cursor_cutoff,
        cursor_cutoff,
        cursor_time,
        cursor_time,
        cursor_time,
        cursor_id,
        fetch_limit,
    )
    .fetch_all(&mut *transaction)
    .await?;
    let metadata = control_metadata(&mut transaction, database_path).await?;
    transaction.rollback().await?;
    let has_more = rows.len() > limit;
    let mut records = rows;
    records.truncate(limit);
    let next_before = records.last().map(|row| RequestRowCursor {
        cutoff_id: cursor.map_or(committed_cutoff, |value| value.cutoff_id.max(value.row_id)),
        occurred_at_unix: row.occurred_at_unix,
        row_id: row.id,
    });
    let mut mapped = Vec::with_capacity(records.len());
    for row in records {
        mapped.push(request_row_from_header(
            row.id,
            row.occurred_at_unix,
            row.client_id,
            row.group_id,
            row.credential_id,
            row.provider_id,
            row.model_id,
            &row.outcome,
            row.status_code,
            row.latency_ms,
            row.request_bytes,
            row.response_bytes,
            row.input_tokens,
            row.output_tokens,
            row.cache_read_tokens,
            row.cache_write_tokens,
            row.usage_complete,
            database_path,
        )?);
    }
    Ok(RequestRowPage {
        metadata,
        rows: mapped,
        next_before,
        has_more,
    })
}

async fn read_provider_snapshots(
    connection: &mut SqliteConnection,
    database_path: &Path,
    query: SnapshotQuery,
) -> Result<Vec<ProviderSnapshot>, StorageError> {
    Ok(
        read_provider_snapshot_page(connection, database_path, query, None)
            .await?
            .snapshots,
    )
}

async fn read_provider_snapshot_page(
    connection: &mut SqliteConnection,
    database_path: &Path,
    query: SnapshotQuery,
    filter: Option<(CredentialId, SnapshotSource, SnapshotSurface)>,
) -> Result<SnapshotPage, StorageError> {
    validate_time(query.since_unix, "snapshot history start")?;
    let limit = if query.limit.get() > MAX_SNAPSHOT_HISTORY {
        return Err(StorageError::Input {
            field: "snapshot history limit exceeds 1000",
        });
    } else {
        i64::try_from(query.limit.get()).map_err(|_| StorageError::Input {
            field: "snapshot history limit is too large",
        })?
    };
    let fetch_limit = limit + 1;
    let provider_id = query.provider.as_ref();
    let credential_filter = filter
        .as_ref()
        .map(|(credential, _, _)| credential.as_ref());
    let source_filter = filter.as_ref().map(|(_, source, _)| source.as_storage());
    let surface_filter = filter.as_ref().map(|(_, _, surface)| surface.as_storage());
    let mut headers = sqlx::query!(
        r#"
            SELECT id AS "id!: i64", fetched_at_unix, provider_id, client_id, group_id,
                   credential_id, account_id, source, surface, fetch_status, gap_reason
            FROM provider_snapshots
            WHERE provider_id = ? AND fetched_at_unix >= ?
              AND (? IS NULL OR credential_id = ?)
              AND (? IS NULL OR source = ?)
              AND (? IS NULL OR surface = ?)
            ORDER BY fetched_at_unix DESC, id DESC
            LIMIT ?
            "#,
        provider_id,
        query.since_unix,
        credential_filter,
        credential_filter,
        source_filter,
        source_filter,
        surface_filter,
        surface_filter,
        fetch_limit,
    )
    .fetch_all(&mut *connection)
    .await?;
    let limit_usize = usize::try_from(query.limit.get()).map_err(|_| StorageError::Input {
        field: "snapshot history limit is too large",
    })?;
    let truncated = headers.len() > limit_usize;
    headers.truncate(limit_usize);
    let ids = headers.iter().map(|header| header.id).collect::<Vec<_>>();
    let mut quota_pools = quota_pools_many(connection, &ids, database_path).await?;
    let mut credit_pools = credit_pools_many(connection, &ids, database_path).await?;
    let mut quota_metrics = quota_metrics_many(connection, &ids, database_path).await?;
    let mut claude_limits = claude_limits_many(connection, &ids, database_path).await?;
    let mut response_windows = response_windows_many(connection, &ids, database_path).await?;
    let mut snapshots = Vec::with_capacity(headers.len());
    for header in headers {
        let pools = quota_pools.remove(&header.id).unwrap_or_default();
        let credits = credit_pools.remove(&header.id).unwrap_or_default();
        let metrics = quota_metrics.remove(&header.id).unwrap_or_default();
        let claude_limits = claude_limits.remove(&header.id).unwrap_or_default();
        let header_windows = response_windows.remove(&header.id).unwrap_or_default();
        snapshots.push(provider_snapshot_from_header(
            header.fetched_at_unix,
            header.provider_id,
            header.client_id,
            header.group_id,
            header.credential_id,
            header.account_id,
            &header.source,
            &header.surface,
            &header.fetch_status,
            header.gap_reason,
            pools,
            credits,
            metrics,
            claude_limits,
            header_windows,
            database_path,
        )?);
    }
    snapshots.reverse();
    Ok(SnapshotPage {
        snapshots,
        truncated,
    })
}
async fn persist_oauth_pair(
    mut transaction: Transaction<'_, Sqlite>,
    replacement: &OauthPairReplacement,
    expected: i64,
    exists: bool,
) -> Result<u64, StorageError> {
    let credential_id = replacement.credential.as_ref();
    let real_access_token = replacement.real_access_token.as_str();
    let real_refresh_token = replacement.real_refresh_token.as_str();
    let fake_access_token = replacement.fake_access_token.as_str();
    let fake_refresh_token = replacement.fake_refresh_token.as_str();
    let client_id = replacement.client.as_ref();
    sqlx::query!(
        r"
        INSERT INTO oauth_tokens
          (credential_id, access_token, refresh_token, refresh_token_expires_at_unix,
           access_expires_at_unix, updated_at_unix)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (credential_id) DO UPDATE SET
          access_token = excluded.access_token,
          refresh_token = excluded.refresh_token,
          refresh_token_expires_at_unix = excluded.refresh_token_expires_at_unix,
          access_expires_at_unix = excluded.access_expires_at_unix,
          updated_at_unix = excluded.updated_at_unix
        ",
        credential_id,
        real_access_token,
        real_refresh_token,
        replacement.real_refresh_expires_at_unix,
        replacement.real_access_expires_at_unix,
        replacement.updated_at_unix,
    )
    .execute(&mut *transaction)
    .await?;

    let generation = expected.checked_add(1).ok_or(StorageError::Input {
        field: "OAuth generation overflow",
    })?;
    if exists {
        let updated = sqlx::query!(
            r"
            UPDATE oauth_mappings
            SET generation = ?, fake_access_token = ?, fake_refresh_token = ?,
                fake_access_expires_at_unix = ?, updated_at_unix = ?
            WHERE client_id = ? AND credential_id = ? AND generation = ?
            ",
            generation,
            fake_access_token,
            fake_refresh_token,
            replacement.fake_access_expires_at_unix,
            replacement.updated_at_unix,
            client_id,
            credential_id,
            expected,
        )
        .execute(&mut *transaction)
        .await?;
        if updated.rows_affected() != 1 {
            return Err(StorageError::ConcurrentOauth {
                credential: replacement.credential.clone(),
            });
        }
    } else {
        sqlx::query!(
            r"
            INSERT INTO oauth_mappings
              (client_id, credential_id, generation, fake_access_token, fake_refresh_token,
               fake_access_expires_at_unix, updated_at_unix)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ",
            client_id,
            credential_id,
            generation,
            fake_access_token,
            fake_refresh_token,
            replacement.fake_access_expires_at_unix,
            replacement.updated_at_unix,
        )
        .execute(&mut *transaction)
        .await?;
    }
    transaction.commit().await?;
    u64::try_from(generation).map_err(|_| StorageError::Input {
        field: "OAuth generation overflow",
    })
}

async fn insert_quota_pools(
    transaction: &mut Transaction<'_, Sqlite>,
    snapshot_id: i64,
    pools: &[QuotaPool],
) -> Result<(), StorageError> {
    for (ordinal, pool) in pools.iter().enumerate() {
        validate_time_optional(pool.reset_at_unix, "quota reset time")?;
        let ordinal = i64::try_from(ordinal).map_err(|_| StorageError::Input {
            field: "quota pool ordinal",
        })?;
        let utilized = i64::try_from(pool.utilized).map_err(|_| StorageError::Input {
            field: "quota utilization",
        })?;
        let limit = i64::try_from(pool.limit).map_err(|_| StorageError::Input {
            field: "quota limit",
        })?;
        sqlx::query!(
            r"
            INSERT INTO quota_pools
              (snapshot_id, ordinal, label, utilized, limit_value, reset_at_unix)
            VALUES (?, ?, ?, ?, ?, ?)
            ",
            snapshot_id,
            ordinal,
            pool.label,
            utilized,
            limit,
            pool.reset_at_unix,
        )
        .execute(&mut **transaction)
        .await?;
    }
    Ok(())
}

async fn insert_credit_pools(
    transaction: &mut Transaction<'_, Sqlite>,
    snapshot_id: i64,
    credits: &[CreditPool],
) -> Result<(), StorageError> {
    for (ordinal, credit) in credits.iter().enumerate() {
        validate_time_optional(credit.reset_at_unix, "credit reset time")?;
        let ordinal = i64::try_from(ordinal).map_err(|_| StorageError::Input {
            field: "credit pool ordinal",
        })?;
        let used = i64::try_from(credit.used_minor_units).map_err(|_| StorageError::Input {
            field: "credit used",
        })?;
        let remaining =
            i64::try_from(credit.remaining_minor_units).map_err(|_| StorageError::Input {
                field: "credit remaining",
            })?;
        let limit = i64::try_from(credit.limit_minor_units).map_err(|_| StorageError::Input {
            field: "credit limit",
        })?;
        sqlx::query!(
            r"
            INSERT INTO credit_pools
              (snapshot_id, ordinal, label, used_minor_units, remaining_minor_units,
               limit_minor_units, reset_at_unix)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ",
            snapshot_id,
            ordinal,
            credit.label,
            used,
            remaining,
            limit,
            credit.reset_at_unix,
        )
        .execute(&mut **transaction)
        .await?;
    }
    Ok(())
}

async fn insert_quota_metrics(
    transaction: &mut Transaction<'_, Sqlite>,
    snapshot_id: i64,
    metrics: &[QuotaMetric],
) -> Result<(), StorageError> {
    for (ordinal, metric) in metrics.iter().enumerate() {
        let ordinal = i64::try_from(ordinal).map_err(|_| StorageError::Input {
            field: "quota metric ordinal",
        })?;
        let value = i64::try_from(metric.value).map_err(|_| StorageError::Input {
            field: "quota metric value",
        })?;
        sqlx::query!(
            r"
            INSERT INTO quota_metrics (snapshot_id, ordinal, label, value, unit)
            VALUES (?, ?, ?, ?, ?)
            ",
            snapshot_id,
            ordinal,
            metric.label,
            value,
            metric.unit,
        )
        .execute(&mut **transaction)
        .await?;
    }
    Ok(())
}

async fn insert_claude_limits(
    transaction: &mut Transaction<'_, Sqlite>,
    snapshot_id: i64,
    limits: &[ClaudeLimit],
) -> Result<(), StorageError> {
    for (ordinal, limit) in limits.iter().enumerate() {
        let ordinal = i64::try_from(ordinal).map_err(|_| StorageError::Input {
            field: "Claude limit ordinal",
        })?;
        let percent_milli =
            i64::try_from(limit.percent_milli).map_err(|_| StorageError::Input {
                field: "Claude limit percent",
            })?;
        let is_active = i64::from(limit.is_active);
        sqlx::query!(
            r"
            INSERT INTO claude_limits
              (snapshot_id, ordinal, kind, group_name, percent_milli, reset_at_unix,
               severity, is_active, model_display_name, surface_display_name)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ",
            snapshot_id,
            ordinal,
            limit.kind,
            limit.group,
            percent_milli,
            limit.reset_at_unix,
            limit.severity,
            is_active,
            limit.model_display_name,
            limit.surface_display_name,
        )
        .execute(&mut **transaction)
        .await?;
    }
    Ok(())
}

async fn insert_response_windows(
    transaction: &mut Transaction<'_, Sqlite>,
    snapshot_id: i64,
    windows: &[ResponseHeaderWindow],
) -> Result<(), StorageError> {
    for window in windows {
        let utilization = i64::from(window.utilization_milli);
        let label = window.label.as_storage();
        let status = window.status.map(ResponseWindowStatus::as_storage);
        sqlx::query!(
            r"
            INSERT INTO response_header_windows
              (snapshot_id, label, utilization_milli, reset_at_unix, status)
            VALUES (?, ?, ?, ?, ?)
            ",
            snapshot_id,
            label,
            utilization,
            window.reset_at_unix,
            status,
        )
        .execute(&mut **transaction)
        .await?;
    }
    Ok(())
}

async fn quota_pools_many(
    connection: &mut SqliteConnection,
    snapshot_ids: &[i64],
    path: &Path,
) -> Result<BTreeMap<i64, Vec<QuotaPool>>, StorageError> {
    let (snapshot_ids, fetch_limit) = snapshot_child_query(snapshot_ids, MAX_SNAPSHOT_CHILDREN);
    let rows = sqlx::query!(
        r"
        SELECT snapshot_id, label, utilized, limit_value, reset_at_unix FROM quota_pools
        WHERE snapshot_id IN (SELECT value FROM json_each(?))
        ORDER BY snapshot_id, ordinal LIMIT ?
        ",
        snapshot_ids,
        fetch_limit,
    )
    .fetch_all(connection)
    .await?;
    let values = rows
        .into_iter()
        .map(|row| {
            Ok((
                row.snapshot_id,
                QuotaPool {
                    label: row.label,
                    limit: stored_count(row.limit_value, path)?,
                    reset_at_unix: row.reset_at_unix,
                    utilized: stored_count(row.utilized, path)?,
                },
            ))
        })
        .collect::<Result<Vec<_>, StorageError>>()?;
    bounded_grouped_children(values, MAX_SNAPSHOT_CHILDREN, path)
}

async fn credit_pools_many(
    connection: &mut SqliteConnection,
    snapshot_ids: &[i64],
    path: &Path,
) -> Result<BTreeMap<i64, Vec<CreditPool>>, StorageError> {
    let (snapshot_ids, fetch_limit) = snapshot_child_query(snapshot_ids, MAX_SNAPSHOT_CHILDREN);
    let rows = sqlx::query!(
        r"
        SELECT snapshot_id, label, used_minor_units, remaining_minor_units, limit_minor_units, reset_at_unix
        FROM credit_pools
        WHERE snapshot_id IN (SELECT value FROM json_each(?))
        ORDER BY snapshot_id, ordinal LIMIT ?
        ",
        snapshot_ids,
        fetch_limit,
    )
    .fetch_all(connection)
    .await?;
    let values = rows
        .into_iter()
        .map(|row| {
            Ok((
                row.snapshot_id,
                CreditPool {
                    label: row.label,
                    limit_minor_units: stored_count(row.limit_minor_units, path)?,
                    remaining_minor_units: stored_count(row.remaining_minor_units, path)?,
                    reset_at_unix: row.reset_at_unix,
                    used_minor_units: stored_count(row.used_minor_units, path)?,
                },
            ))
        })
        .collect::<Result<Vec<_>, StorageError>>()?;
    bounded_grouped_children(values, MAX_SNAPSHOT_CHILDREN, path)
}

async fn quota_metrics_many(
    connection: &mut SqliteConnection,
    snapshot_ids: &[i64],
    path: &Path,
) -> Result<BTreeMap<i64, Vec<QuotaMetric>>, StorageError> {
    let (snapshot_ids, fetch_limit) = snapshot_child_query(snapshot_ids, MAX_SNAPSHOT_CHILDREN);
    let rows = sqlx::query!(
        r"
        SELECT snapshot_id, label, value, unit FROM quota_metrics
        WHERE snapshot_id IN (SELECT value FROM json_each(?))
        ORDER BY snapshot_id, ordinal LIMIT ?
        ",
        snapshot_ids,
        fetch_limit,
    )
    .fetch_all(connection)
    .await?;
    let values = rows
        .into_iter()
        .map(|row| {
            Ok((
                row.snapshot_id,
                QuotaMetric {
                    label: row.label,
                    unit: row.unit,
                    value: stored_count(row.value, path)?,
                },
            ))
        })
        .collect::<Result<Vec<_>, StorageError>>()?;
    bounded_grouped_children(values, MAX_SNAPSHOT_CHILDREN, path)
}

async fn claude_limits_many(
    connection: &mut SqliteConnection,
    snapshot_ids: &[i64],
    path: &Path,
) -> Result<BTreeMap<i64, Vec<ClaudeLimit>>, StorageError> {
    let (snapshot_ids, fetch_limit) = snapshot_child_query(snapshot_ids, MAX_SNAPSHOT_CHILDREN);
    let rows = sqlx::query!(
        r"
        SELECT snapshot_id, kind, group_name, percent_milli, reset_at_unix, severity, is_active,
               model_display_name, surface_display_name
        FROM claude_limits WHERE snapshot_id IN (SELECT value FROM json_each(?)) ORDER BY snapshot_id, ordinal LIMIT ?
        ",
        snapshot_ids,
        fetch_limit,
    )
    .fetch_all(connection)
    .await?;
    let values = rows
        .into_iter()
        .map(|row| {
            Ok((
                row.snapshot_id,
                ClaudeLimit {
                    kind: row.kind,
                    group: row.group_name,
                    percent_milli: stored_count(row.percent_milli, path)?,
                    reset_at_unix: row.reset_at_unix,
                    severity: row.severity,
                    is_active: row.is_active != 0,
                    model_display_name: row.model_display_name,
                    surface_display_name: row.surface_display_name,
                },
            ))
        })
        .collect::<Result<Vec<_>, StorageError>>()?;
    bounded_grouped_children(values, MAX_SNAPSHOT_CHILDREN, path)
}

async fn response_windows_many(
    connection: &mut SqliteConnection,
    snapshot_ids: &[i64],
    path: &Path,
) -> Result<BTreeMap<i64, Vec<ResponseHeaderWindow>>, StorageError> {
    let (snapshot_ids, fetch_limit) = snapshot_child_query(snapshot_ids, MAX_RESPONSE_WINDOWS);
    let rows = sqlx::query!(
        r"
        SELECT snapshot_id, label, utilization_milli, reset_at_unix, status FROM response_header_windows
        WHERE snapshot_id IN (SELECT value FROM json_each(?))
        ORDER BY snapshot_id, label LIMIT ?
        ",
        snapshot_ids,
        fetch_limit,
    )
    .fetch_all(connection)
    .await?;
    let values = rows
        .into_iter()
        .map(|row| {
            let integrity = || StorageError::Integrity {
                path: path.to_owned(),
            };
            let label = ResponseWindowLabel::from_storage(&row.label).ok_or_else(integrity)?;
            let status = row
                .status
                .map(|value| {
                    ResponseWindowStatus::from_storage(value.as_str()).ok_or_else(integrity)
                })
                .transpose()?;
            Ok((
                row.snapshot_id,
                ResponseHeaderWindow {
                    label,
                    reset_at_unix: row.reset_at_unix,
                    status,
                    utilization_milli: u32::try_from(row.utilization_milli)
                        .map_err(|_| integrity())?,
                },
            ))
        })
        .collect::<Result<Vec<_>, StorageError>>()?;
    bounded_grouped_children(values, MAX_RESPONSE_WINDOWS, path)
}

fn snapshot_child_query(snapshot_ids: &[i64], max: usize) -> (String, i64) {
    let ids = snapshot_ids
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(",");
    // Fetching one beyond the page-wide maximum guarantees that any corrupt
    // per-snapshot excess is visible to bounded_grouped_children.
    (
        format!("[{ids}]"),
        child_query_limit(snapshot_ids.len().saturating_mul(max)),
    )
}

fn bounded_grouped_children<T>(
    values: Vec<(i64, T)>,
    max: usize,
    path: &Path,
) -> Result<BTreeMap<i64, Vec<T>>, StorageError> {
    let mut grouped = BTreeMap::<i64, Vec<T>>::new();
    for (snapshot_id, value) in values {
        let children = grouped.entry(snapshot_id).or_default();
        children.push(value);
        if children.len() > max {
            return Err(StorageError::Integrity {
                path: path.to_owned(),
            });
        }
    }
    Ok(grouped)
}

fn child_query_limit(max: usize) -> i64 {
    i64::try_from(max.saturating_add(1)).unwrap_or(i64::MAX)
}

async fn request_usage_worker(
    connection: std::sync::Arc<tokio::sync::Mutex<SqliteConnection>>,
    mut work: tokio::sync::mpsc::Receiver<UsageWork>,
) {
    while let Some((event, acknowledgement)) = work.recv().await {
        let Ok(mut connection) = connection.try_lock() else {
            let _ = acknowledgement.send(Err(StorageError::UsageUnavailable));
            continue;
        };
        let result = append_request_event(&event, &mut connection).await;
        drop(connection);
        let _ = acknowledgement.send(result);
    }
}

fn validate_request_event(event: &RequestEvent) -> Result<(), StorageError> {
    validate_time(event.occurred_at_unix, "request time")?;
    validate_model(&event.model)?;
    validate_count(event.request_bytes, "request bytes")?;
    validate_count(event.response_bytes, "response bytes")?;
    validate_count(event.latency_ms, "latency")?;
    validate_count(event.dropped_events, "dropped usage events")?;
    validate_optional_count(event.input_tokens, "input tokens")?;
    validate_optional_count(event.output_tokens, "output tokens")?;
    validate_optional_count(event.cache_read_tokens, "cache read tokens")?;
    validate_optional_count(event.cache_write_tokens, "cache write tokens")?;
    if !(100..=599).contains(&event.status_code) {
        return Err(StorageError::Input {
            field: "request status must be 100..=599",
        });
    }
    Ok(())
}

async fn append_request_event(
    event: &RequestEvent,
    connection: &mut SqliteConnection,
) -> Result<(), StorageError> {
    let client_id = event.client.as_ref();
    let group_id = event.group.as_ref();
    let credential_id = event.credential.as_ref();
    let model_id = event.model.as_str();
    let outcome = event.outcome.as_storage();
    let request_bytes = i64::try_from(event.request_bytes).map_err(|_| StorageError::Input {
        field: "request bytes",
    })?;
    let response_bytes = i64::try_from(event.response_bytes).map_err(|_| StorageError::Input {
        field: "response bytes",
    })?;
    let latency_ms =
        i64::try_from(event.latency_ms).map_err(|_| StorageError::Input { field: "latency" })?;
    let dropped_events = i64::try_from(event.dropped_events).map_err(|_| StorageError::Input {
        field: "dropped usage events",
    })?;
    let input_tokens = event
        .input_tokens
        .map(|value| {
            i64::try_from(value).map_err(|_| StorageError::Input {
                field: "input tokens",
            })
        })
        .transpose()?;
    let output_tokens = event
        .output_tokens
        .map(|value| {
            i64::try_from(value).map_err(|_| StorageError::Input {
                field: "output tokens",
            })
        })
        .transpose()?;
    let cache_read_tokens = event
        .cache_read_tokens
        .map(|value| {
            i64::try_from(value).map_err(|_| StorageError::Input {
                field: "cache read tokens",
            })
        })
        .transpose()?;
    let cache_write_tokens = event
        .cache_write_tokens
        .map(|value| {
            i64::try_from(value).map_err(|_| StorageError::Input {
                field: "cache write tokens",
            })
        })
        .transpose()?;
    let mut transaction = connection.begin().await?;
    sqlx::query!(
        r"
        INSERT INTO request_events
          (occurred_at_unix, client_id, group_id, credential_id, model_id, outcome,
           status_code, request_bytes, response_bytes, latency_ms, input_tokens,
           output_tokens, cache_read_tokens, cache_write_tokens, usage_complete,
           dropped_events)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ",
        event.occurred_at_unix,
        client_id,
        group_id,
        credential_id,
        model_id,
        outcome,
        event.status_code,
        request_bytes,
        response_bytes,
        latency_ms,
        input_tokens,
        output_tokens,
        cache_read_tokens,
        cache_write_tokens,
        event.usage_complete,
        dropped_events,
    )
    .execute(&mut *transaction)
    .await?;
    update_request_chart_daily(&mut transaction).await?;
    transaction.commit().await?;
    Ok(())
}

// Consume the just-inserted raw event on this transaction's connection.
async fn update_request_chart_daily(connection: &mut SqliteConnection) -> Result<(), StorageError> {
    sqlx::query!(
        r"
        INSERT INTO request_chart_daily
        SELECT
          (r.occurred_at_unix / 86400) * 86400,
          c.provider_id,
          COALESCE(r.client_id, ''),
          r.model_id,
          1,
          r.usage_complete,
          r.status_code >= 400,
          COALESCE(r.input_tokens, 0),
          r.input_tokens IS NULL,
          COALESCE(r.output_tokens, 0),
          r.output_tokens IS NULL,
          COALESCE(r.cache_read_tokens, 0),
          r.cache_read_tokens IS NULL,
          COALESCE(r.cache_write_tokens, 0),
          r.cache_write_tokens IS NULL
        FROM request_events r
        JOIN credentials c ON c.id = r.credential_id
        WHERE r.id = last_insert_rowid()
        ON CONFLICT (day_unix, provider_id, client_key, model_id) DO UPDATE SET
          events = request_chart_daily.events + excluded.events,
          complete_events = request_chart_daily.complete_events + excluded.complete_events,
          error_events = request_chart_daily.error_events + excluded.error_events,
          input_tokens = request_chart_daily.input_tokens + excluded.input_tokens,
          input_tokens_unknown = request_chart_daily.input_tokens_unknown + excluded.input_tokens_unknown,
          output_tokens = request_chart_daily.output_tokens + excluded.output_tokens,
          output_tokens_unknown = request_chart_daily.output_tokens_unknown + excluded.output_tokens_unknown,
          cache_read_tokens = request_chart_daily.cache_read_tokens + excluded.cache_read_tokens,
          cache_read_tokens_unknown = request_chart_daily.cache_read_tokens_unknown + excluded.cache_read_tokens_unknown,
          cache_write_tokens = request_chart_daily.cache_write_tokens + excluded.cache_write_tokens,
          cache_write_tokens_unknown = request_chart_daily.cache_write_tokens_unknown + excluded.cache_write_tokens_unknown
        "
    )
    .execute(connection)
    .await?;
    Ok(())
}

fn complete_sum(
    value: Option<i64>,
    missing: i64,
    path: &Path,
) -> Result<Option<u64>, StorageError> {
    if missing > 0 {
        return Ok(None);
    }
    value.map(|value| stored_count(value, path)).transpose()
}

fn stored_optional_count(value: Option<i64>, path: &Path) -> Result<Option<u64>, StorageError> {
    value.map(|value| stored_count(value, path)).transpose()
}

fn stored_count(value: i64, path: &Path) -> Result<u64, StorageError> {
    u64::try_from(value).map_err(|_| StorageError::Integrity {
        path: path.to_owned(),
    })
}

async fn quick_check(connection: &mut SqliteConnection, path: &Path) -> Result<(), StorageError> {
    let results = sqlx::query_scalar::<_, String>("PRAGMA quick_check")
        .fetch_all(&mut *connection)
        .await?;
    if results.len() != 1 || results[0] != "ok" {
        return Err(StorageError::Integrity {
            path: path.to_owned(),
        });
    }
    Ok(())
}

async fn ensure_foreign_keys(
    connection: &mut SqliteConnection,
    path: &Path,
) -> Result<(), StorageError> {
    let foreign_keys = sqlx::query_scalar::<_, i64>("PRAGMA foreign_keys")
        .fetch_one(&mut *connection)
        .await?;
    if foreign_keys == 0 {
        return Err(StorageError::Integrity {
            path: path.to_owned(),
        });
    }
    Ok(())
}

async fn seed_identities(
    connection: &mut SqliteConnection,
    identities: StorageIdentities,
) -> Result<(), StorageError> {
    let mut transaction = connection.begin().await?;
    for client in identities.clients {
        let client_id = client.as_ref();
        sqlx::query!(
            "INSERT INTO clients (id, inserted_at_unix) VALUES (?, ?) ON CONFLICT (id) DO NOTHING",
            client_id,
            identities.inserted_at_unix,
        )
        .execute(&mut *transaction)
        .await?;
    }
    for provider in identities.providers {
        let provider_id = provider.as_ref();
        sqlx::query!(
            "INSERT INTO providers (id, inserted_at_unix) VALUES (?, ?) ON CONFLICT (id) DO NOTHING",
            provider_id,
            identities.inserted_at_unix,
        )
        .execute(&mut *transaction)
        .await?;
    }
    for (credential, provider) in identities.credentials {
        let credential_id = credential.as_ref();
        let provider_id = provider.as_ref();
        sqlx::query!(
            "INSERT INTO credentials (id, provider_id, inserted_at_unix) VALUES (?, ?, ?) ON CONFLICT (id) DO NOTHING",
            credential_id,
            provider_id,
            identities.inserted_at_unix,
        )
        .execute(&mut *transaction)
        .await?;
        let stored = sqlx::query!(
            "SELECT provider_id FROM credentials WHERE id = ?",
            credential_id,
        )
        .fetch_one(&mut *transaction)
        .await?;
        if stored.provider_id != provider.as_ref() {
            return Err(StorageError::StoredIdentity {
                credential: credential.clone(),
            });
        }
    }
    for group in identities.groups {
        let group_id = group.as_ref();
        sqlx::query!(
            "INSERT INTO groups (id, inserted_at_unix) VALUES (?, ?) ON CONFLICT (id) DO NOTHING",
            group_id,
            identities.inserted_at_unix,
        )
        .execute(&mut *transaction)
        .await?;
    }
    for (group, credential) in identities.group_members {
        let group_id = group.as_ref();
        let credential_id = credential.as_ref();
        sqlx::query!(
            r"
            INSERT INTO group_members (group_id, credential_id)
            VALUES (?, ?) ON CONFLICT (group_id, credential_id) DO NOTHING
            ",
            group_id,
            credential_id,
        )
        .execute(&mut *transaction)
        .await?;
    }
    transaction.commit().await?;
    Ok(())
}

fn validate_oauth_replacement(replacement: &OauthPairReplacement) -> Result<(), StorageError> {
    validate_time(replacement.updated_at_unix, "OAuth update time")?;
    validate_time(
        replacement.real_access_expires_at_unix,
        "real access expiry",
    )?;
    validate_time(
        replacement.fake_access_expires_at_unix,
        "fake access expiry",
    )?;
    validate_time_optional(
        replacement.real_refresh_expires_at_unix,
        "real refresh expiry",
    )?;
    if replacement.expected_generation > i64::MAX.unsigned_abs() {
        return Err(StorageError::Input {
            field: "OAuth generation is too large",
        });
    }
    Ok(())
}

fn validate_identities(identities: &StorageIdentities) -> Result<(), StorageError> {
    validate_time(identities.inserted_at_unix, "identity time")?;
    for (_, credential) in &identities.group_members {
        if !identities.credentials.contains_key(credential) {
            return Err(StorageError::Input {
                field: "group member references an unregistered credential",
            });
        }
    }
    if identities
        .credentials
        .values()
        .any(|provider| !identities.providers.contains(provider))
        || identities
            .group_members
            .iter()
            .any(|(group, _)| !identities.groups.contains(group))
    {
        return Err(StorageError::Input {
            field: "identity references an unregistered provider or group",
        });
    }
    Ok(())
}

fn validate_label(value: &str, field: &'static str) -> Result<(), StorageError> {
    if value.is_empty() || value.len() > 128 {
        return Err(StorageError::Input { field });
    }
    Ok(())
}

fn validate_model(value: &str) -> Result<(), StorageError> {
    if value.is_empty() || value.len() > 128 {
        return Err(StorageError::Input {
            field: "model must be 1..=128 bytes",
        });
    }
    Ok(())
}

fn validate_time(value: i64, field: &'static str) -> Result<(), StorageError> {
    if value <= 0 {
        return Err(StorageError::Input { field });
    }
    Ok(())
}

fn validate_time_optional(value: Option<i64>, field: &'static str) -> Result<(), StorageError> {
    if value.is_some_and(|time| time <= 0) {
        return Err(StorageError::Input { field });
    }
    Ok(())
}

fn validate_count(value: u64, field: &'static str) -> Result<(), StorageError> {
    if value > i64::MAX as u64 {
        return Err(StorageError::Input { field });
    }
    Ok(())
}

fn validate_optional_count(value: Option<u64>, field: &'static str) -> Result<(), StorageError> {
    if let Some(value) = value {
        validate_count(value, field)?;
    }
    Ok(())
}

/// Checks every typed dimension before a snapshot is admitted to a transaction.
///
/// # Errors
/// Rejects invalid source, labels, numeric domains, or success/gap combinations.
#[expect(
    clippy::too_many_lines,
    reason = "one validation boundary covers all snapshot dimensions"
)]
pub fn validate_provider_snapshot(snapshot: &ProviderSnapshot) -> Result<(), StorageError> {
    if (snapshot.source == SnapshotSource::ResponseHeaders)
        != (snapshot.surface == SnapshotSurface::ResponseHeaders)
    {
        return Err(StorageError::Input {
            field: "snapshot source and surface disagree",
        });
    }
    if snapshot.pools.len() > MAX_SNAPSHOT_CHILDREN
        || snapshot.credits.len() > MAX_SNAPSHOT_CHILDREN
        || snapshot.metrics.len() > MAX_SNAPSHOT_CHILDREN
        || snapshot.claude_limits.len() > MAX_SNAPSHOT_CHILDREN
        || snapshot.header_windows.len() > MAX_RESPONSE_WINDOWS
        || snapshot
            .pools
            .iter()
            .any(|pool| pool.limit == 0 || pool.utilized > pool.limit)
        || snapshot.credits.iter().any(|credit| {
            credit.limit_minor_units == 0
                || credit.remaining_minor_units > credit.limit_minor_units
                || credit.used_minor_units > credit.limit_minor_units
        })
    {
        return Err(StorageError::Input {
            field: "snapshot dimensions and numeric domains are invalid",
        });
    }
    for pool in &snapshot.pools {
        validate_label(&pool.label, "quota pool label")?;
        validate_count(pool.utilized, "quota utilization")?;
        validate_count(pool.limit, "quota limit")?;
    }
    for credit in &snapshot.credits {
        validate_label(&credit.label, "credit pool label")?;
        validate_count(credit.used_minor_units, "credit used")?;
        validate_count(credit.remaining_minor_units, "credit remaining")?;
        validate_count(credit.limit_minor_units, "credit limit")?;
    }
    for metric in &snapshot.metrics {
        validate_label(&metric.label, "quota metric label")?;
        validate_label(&metric.unit, "quota metric unit")?;
        validate_count(metric.value, "quota metric value")?;
    }
    for limit in &snapshot.claude_limits {
        validate_label(&limit.kind, "Claude limit kind")?;
        for value in [
            limit.group.as_deref(),
            limit.severity.as_deref(),
            limit.model_display_name.as_deref(),
            limit.surface_display_name.as_deref(),
        ]
        .into_iter()
        .flatten()
        {
            validate_label(value, "Claude limit scope")?;
        }
        if limit.percent_milli > 100_000 {
            return Err(StorageError::Input {
                field: "Claude limit percent",
            });
        }
        validate_time_optional(limit.reset_at_unix, "Claude limit reset time")?;
    }
    for labels in [
        snapshot
            .pools
            .iter()
            .map(|item| item.label.as_str())
            .collect::<Vec<_>>(),
        snapshot
            .credits
            .iter()
            .map(|item| item.label.as_str())
            .collect::<Vec<_>>(),
        snapshot
            .metrics
            .iter()
            .map(|item| item.label.as_str())
            .collect::<Vec<_>>(),
    ] {
        if labels.iter().collect::<BTreeSet<_>>().len() != labels.len() {
            return Err(StorageError::Input {
                field: "duplicate snapshot label",
            });
        }
    }
    let mut labels = BTreeSet::new();
    for window in &snapshot.header_windows {
        if !labels.insert(window.label) || window.utilization_milli > 10_000_000 {
            return Err(StorageError::Input {
                field: "response header windows are invalid",
            });
        }
        validate_time_optional(window.reset_at_unix, "response window reset time")?;
    }
    let has_typed_data = snapshot.has_typed_data();
    match snapshot.fetch_status {
        SnapshotFetchStatus::Gap => {
            if snapshot
                .gap_reason
                .as_ref()
                .is_none_or(|reason| reason.is_empty() || reason.len() > 256)
            {
                return Err(StorageError::Input {
                    field: "gap snapshots require a 1..=256 byte reason",
                });
            }
            if has_typed_data {
                return Err(StorageError::Input {
                    field: "gap snapshots cannot contain quota dimensions",
                });
            }
        }
        SnapshotFetchStatus::Success if snapshot.gap_reason.is_some() => {
            return Err(StorageError::Input {
                field: "successful snapshots cannot carry a gap reason",
            });
        }
        SnapshotFetchStatus::Success
            if snapshot.source == SnapshotSource::OutOfBandFetch && !has_typed_data =>
        {
            return Err(StorageError::Input {
                field: "out-of-band success snapshots require typed quota data",
            });
        }
        SnapshotFetchStatus::Success => {}
    }
    Ok(())
}

fn create_private_directory(path: &Path) -> Result<(), StorageError> {
    if !path.is_absolute() {
        return Err(StorageError::NotPrivateDirectory {
            path: path.to_owned(),
        });
    }
    let mut created = PathBuf::new();
    for component in path.components() {
        created.push(component);
        match fs::symlink_metadata(&created) {
            Ok(metadata) if metadata.is_dir() => {}
            Ok(_) => {
                return Err(StorageError::NotPrivateDirectory { path: created });
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                DirBuilder::new()
                    .mode(0o700)
                    .create(&created)
                    .map_err(|source| StorageError::Io {
                        path: created.clone(),
                        source,
                    })?;
            }
            Err(source) => {
                return Err(StorageError::Io {
                    path: created.clone(),
                    source,
                });
            }
        }
    }
    check_private_directory(path)
}

fn check_private_directory(path: &Path) -> Result<(), StorageError> {
    if !path.is_absolute() {
        return Err(StorageError::NotPrivateDirectory {
            path: path.to_owned(),
        });
    }
    let metadata = fs::symlink_metadata(path).map_err(|source| StorageError::Io {
        path: path.to_owned(),
        source,
    })?;
    if metadata.is_dir() && metadata.uid() == getuid().as_raw() && metadata.mode() & 0o777 == 0o700
    {
        Ok(())
    } else {
        Err(StorageError::NotPrivateDirectory {
            path: path.to_owned(),
        })
    }
}

fn prepare_database_file(path: &Path) -> Result<(), StorageError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() => {}
        Ok(_) => {
            return Err(StorageError::NotPrivateFile {
                path: path.to_owned(),
            });
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(path)
                .map_err(|source| StorageError::Io {
                    path: path.to_owned(),
                    source,
                })?;
        }
        Err(source) => {
            return Err(StorageError::Io {
                path: path.to_owned(),
                source,
            });
        }
    }
    private_file(path)
}

fn private_file(path: &Path) -> Result<(), StorageError> {
    let metadata = fs::symlink_metadata(path).map_err(|source| StorageError::Io {
        path: path.to_owned(),
        source,
    })?;
    let mode = metadata.mode();
    if metadata.is_file() && metadata.uid() == getuid().as_raw() && mode & 0o777 == 0o600 {
        Ok(())
    } else {
        Err(StorageError::NotPrivateFile {
            path: path.to_owned(),
        })
    }
}

fn check_private_companions(database_path: &Path) -> Result<(), StorageError> {
    for suffix in ["-journal", "-shm", "-wal"] {
        let path = PathBuf::from(format!("{}{suffix}", database_path.display()));
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.is_file() => private_file(&path)?,
            Ok(_) => return Err(StorageError::NotPrivateFile { path }),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(source) => {
                return Err(StorageError::Io {
                    path: path.clone(),
                    source,
                });
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{
        fs::{self, OpenOptions},
        io::{Seek, SeekFrom, Write},
        num::NonZeroU64,
        os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
    };

    use super::*;
    use sqlx::Connection;
    use std::{
        io::Write as IoWrite,
        sync::{Arc, Mutex},
    };
    use tracing_subscriber::util::SubscriberInitExt as _;

    const LOG_CAPTURE_MARKER: &str = "airlock storage log capture is active";

    #[derive(Clone)]
    struct CapturedLogWriter(Arc<Mutex<Vec<u8>>>);

    impl IoWrite for CapturedLogWriter {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0
                .lock()
                .expect("captured log lock")
                .extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[derive(Clone)]
    struct CapturedLogMaker(Arc<Mutex<Vec<u8>>>);

    impl tracing_subscriber::fmt::writer::MakeWriter<'_> for CapturedLogMaker {
        type Writer = CapturedLogWriter;

        fn make_writer(&self) -> Self::Writer {
            CapturedLogWriter(Arc::clone(&self.0))
        }
    }

    async fn with_captured_logs<F>(future: F) -> (F::Output, String)
    where
        F: Future,
    {
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let subscriber = tracing_subscriber::fmt()
            .with_ansi(false)
            .with_max_level(tracing_subscriber::filter::LevelFilter::TRACE)
            .with_writer(CapturedLogMaker(Arc::clone(&bytes)))
            .finish();
        let guard = subscriber.set_default();
        let output = future.await;
        drop(guard);
        let rendered =
            String::from_utf8_lossy(&bytes.lock().expect("captured log lock")).into_owned();
        (output, rendered)
    }

    fn provider(value: &'static str) -> ProviderId {
        ProviderId::try_from(value).expect("provider ID")
    }

    fn credential(value: &'static str) -> CredentialId {
        CredentialId::try_from(value).expect("credential ID")
    }

    fn group(value: &'static str) -> GroupId {
        GroupId::try_from(value).expect("group ID")
    }

    fn client(value: &'static str) -> ClientId {
        ClientId::try_from(value).expect("client ID")
    }

    fn identities() -> StorageIdentities {
        let credentials = BTreeMap::from([
            (credential("claude"), provider("claude")),
            (credential("zai"), provider("zai")),
        ]);
        let groups = BTreeSet::from([group("anthropic"), group("openai")]);
        StorageIdentities {
            clients: BTreeSet::from([client("claude"), client("harness")]),
            credentials,
            group_members: BTreeSet::from([
                (group("anthropic"), credential("claude")),
                (group("openai"), credential("zai")),
            ]),
            groups,
            inserted_at_unix: 1,
            providers: BTreeSet::from([provider("claude"), provider("zai")]),
        }
    }

    fn token(value: &str) -> TokenMaterial {
        TokenMaterial::new(format!("fake-{value}-token")).expect("fake token")
    }

    fn oauth(credential: CredentialId, expected_generation: u64) -> OauthPairReplacement {
        let suffix = credential.to_string();
        OauthPairReplacement {
            client: ClientId::try_from("claude").expect("client ID"),
            credential,
            expected_generation,
            fake_access_token: token(&format!("{suffix}-fake-access")),
            fake_access_expires_at_unix: 3_600,
            fake_refresh_token: token(&format!("{suffix}-fake-refresh")),
            real_access_token: token(&format!("{suffix}-real-access")),
            real_access_expires_at_unix: 3_600,
            real_refresh_token: token(&format!("{suffix}-real-refresh")),
            real_refresh_expires_at_unix: Some(86_400),
            updated_at_unix: 1,
        }
    }

    fn request(outcome: RequestOutcome, timestamp: i64) -> RequestEvent {
        RequestEvent {
            cache_read_tokens: Some(7),
            cache_write_tokens: None,
            client: client("harness"),
            credential: credential("claude"),
            dropped_events: 0,
            group: group("anthropic"),
            input_tokens: if outcome == RequestOutcome::Completed {
                Some(11)
            } else {
                None
            },
            latency_ms: 25,
            model: "claude-sonnet-4-5".to_owned(),
            occurred_at_unix: timestamp,
            outcome,
            output_tokens: Some(13),
            request_bytes: 100,
            response_bytes: 200,
            status_code: 200,
            usage_complete: true,
        }
    }

    fn oauth_sentinels(pair: &OauthPairReplacement) -> [Zeroizing<String>; 4] {
        [
            pair.fake_access_token.as_str(),
            pair.fake_refresh_token.as_str(),
            pair.real_access_token.as_str(),
            pair.real_refresh_token.as_str(),
        ]
        .map(|secret| Zeroizing::new(secret.to_owned()))
    }

    fn snapshot(timestamp: i64) -> ProviderSnapshot {
        ProviderSnapshot {
            account_id: "account".to_owned(),
            client: Some(client("harness")),
            claude_limits: vec![],
            credential: credential("claude"),
            credits: vec![CreditPool {
                label: "credits".to_owned(),
                limit_minor_units: 100,
                remaining_minor_units: 70,
                reset_at_unix: Some(7_200),
                used_minor_units: 30,
            }],
            fetched_at_unix: timestamp,
            fetch_status: SnapshotFetchStatus::Success,
            gap_reason: None,
            group: Some(group("anthropic")),
            header_windows: vec![],
            metrics: vec![QuotaMetric {
                label: "events".to_owned(),
                unit: "count".to_owned(),
                value: 4,
            }],
            pools: vec![QuotaPool {
                label: "messages".to_owned(),
                limit: 40,
                reset_at_unix: Some(7_200),
                utilized: 12,
            }],
            provider: provider("claude"),
            source: SnapshotSource::OutOfBandFetch,
            surface: SnapshotSurface::ClaudeSubscription,
        }
    }

    async fn open(directory: &Path) -> SqliteStorage {
        fs::set_permissions(directory, PermissionsExt::from_mode(0o700))
            .expect("private test state directory");
        SqliteStorage::open(directory, identities())
            .await
            .expect("private storage")
    }

    async fn close(storage: SqliteStorage) {
        storage.close().await.expect("close storage");
    }

    async fn test_connection(path: &Path) -> SqliteConnection {
        let options = SqliteConnectOptions::new()
            .filename(path)
            .foreign_keys(true)
            .pragma("secure_delete", "ON");
        options.connect().await.expect("test connection")
    }

    fn mode(path: &Path) -> u32 {
        fs::symlink_metadata(path).expect("file metadata").mode() & 0o777
    }

    #[tokio::test]
    async fn records_round_trip_after_reopen_and_state_is_private() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        storage
            .replace_oauth_pair(oauth(credential("claude"), 0))
            .await
            .expect("OAuth replacement");
        let mut event = request(RequestOutcome::Completed, 10);
        event.dropped_events = 2;
        storage
            .try_append_request_event(event)
            .await
            .expect("request event");
        storage
            .append_provider_snapshot(snapshot(10))
            .await
            .expect("provider snapshot");
        assert_eq!(mode(directory.path()), 0o700);
        assert_eq!(mode(&directory.path().join(DATABASE_FILE)), 0o600);
        close(storage).await;

        let storage = open(directory.path()).await;
        let mapping = storage
            .oauth_pair(
                &ClientId::try_from("claude").expect("client ID"),
                &credential("claude"),
                &provider("claude"),
            )
            .await
            .expect("OAuth pair");
        assert_eq!(mapping.credential, credential("claude"));
        assert_eq!(mapping.generation, 1);
        assert_eq!(
            mapping.fake_access_token.as_str(),
            "fake-claude-fake-access-token"
        );

        let usage = storage
            .request_usage(RequestUsageQuery {
                group: group("anthropic"),
                bucket_seconds: NonZeroU64::new(60).expect("bucket seconds"),
                since_unix: 1,
                until_unix: 20,
            })
            .await
            .expect("usage");
        assert_eq!(usage.len(), 1);
        assert_eq!(usage[0].events, 1);
        assert_eq!(usage[0].bucket_start_unix, 0);
        assert_eq!(usage[0].client, Some(client("harness")));
        assert_eq!(usage[0].provider, provider("claude"));
        assert_eq!(usage[0].complete_events, 1);
        assert_eq!(usage[0].successful_events, 1);
        assert_eq!(usage[0].error_events, 0);
        assert_eq!(
            storage
                .request_usage_loss_total()
                .await
                .expect("global losses"),
            2
        );
        assert_eq!(usage[0].request_bytes, 100);
        assert_eq!(usage[0].response_bytes, 200);
        assert_eq!(usage[0].latency_ms, 25);
        assert_eq!(usage[0].input_tokens, Some(11));
        assert_eq!(usage[0].output_tokens, Some(13));
        assert_eq!(usage[0].cache_read_tokens, Some(7));
        assert_eq!(usage[0].cache_write_tokens, None);

        let snapshots = storage
            .provider_snapshots(SnapshotQuery {
                limit: NonZeroU64::new(10).expect("limit"),
                provider: provider("claude"),
                since_unix: 1,
            })
            .await
            .expect("snapshots");
        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0].account_id, "account");
        assert_eq!(snapshots[0].pools.len(), 1);
        assert_eq!(snapshots[0].credits.len(), 1);
        assert_eq!(snapshots[0].metrics.len(), 1);
        close(storage).await;
    }

    #[tokio::test]
    async fn daily_rollup_preserves_independent_unknowns_and_http_errors_after_restart() {
        type DailyRow = (
            i64,
            String,
            String,
            String,
            i64,
            i64,
            i64,
            i64,
            i64,
            i64,
            i64,
            i64,
            i64,
            i64,
            i64,
        );
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        for missing in 0..4 {
            let mut event = request(RequestOutcome::Failed, 86_401 + missing);
            event.input_tokens = Some(11);
            event.cache_write_tokens = Some(17);
            // Outcome deliberately disagrees: only HTTP status defines chart errors.
            event.status_code = if missing == 0 { 500 } else { 200 };
            event.usage_complete = missing != 1;
            match missing {
                0 => event.input_tokens = None,
                1 => event.output_tokens = None,
                2 => event.cache_read_tokens = None,
                _ => event.cache_write_tokens = None,
            }
            storage
                .try_append_request_event(event)
                .await
                .expect("append");
        }
        close(storage).await;
        let storage = open(directory.path()).await;
        let row: DailyRow = sqlx::query_as("SELECT * FROM request_chart_daily")
            .fetch_one(&mut test_connection(&storage.database_path).await)
            .await
            .expect("daily row");
        assert_eq!(
            (row.0, row.1.as_str(), row.2.as_str(), row.3.as_str()),
            (86_400, "claude", "harness", "claude-sonnet-4-5")
        );
        assert_eq!(
            [
                row.4, row.5, row.6, row.7, row.8, row.9, row.10, row.11, row.12, row.13, row.14
            ],
            [4, 3, 1, 33, 1, 39, 1, 21, 1, 51, 1]
        );
        close(storage).await;
    }

    #[tokio::test]
    async fn daily_upsert_failure_rolls_back_raw_insert_and_exact_integer_overflow() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let mut event = request(RequestOutcome::Completed, 10);
        event.input_tokens = Some(i64::MAX as u64);
        storage
            .try_append_request_event(event.clone())
            .await
            .expect("exact maximum");
        let mut connection = test_connection(&storage.database_path).await;
        sqlx::query("CREATE TRIGGER reject_daily BEFORE UPDATE ON request_chart_daily BEGIN SELECT RAISE(ABORT, 'test daily failure'); END")
            .execute(&mut connection).await.expect("failure injection");
        assert!(matches!(
            storage.try_append_request_event(event.clone()).await,
            Err(StorageError::Database(_))
        ));
        sqlx::query("DROP TRIGGER reject_daily")
            .execute(&mut connection)
            .await
            .expect("remove injection");
        event.input_tokens = Some(1);
        assert!(matches!(
            storage.try_append_request_event(event).await,
            Err(StorageError::Database(_))
        ));
        let raw: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM request_events")
            .fetch_one(&mut connection)
            .await
            .expect("raw count");
        let daily: (i64, i64) =
            sqlx::query_as("SELECT events, input_tokens FROM request_chart_daily")
                .fetch_one(&mut connection)
                .await
                .expect("daily count");
        assert_eq!(raw, 1);
        assert_eq!(daily, (1, i64::MAX));
        connection.close().await.expect("close test connection");
        close(storage).await;
    }

    #[tokio::test]
    async fn daily_migration_interruption_rolls_back_and_restart_backfills_once() {
        type BackfillRow = (i64, String, i64, i64, i64, i64, i64, i64);
        let directory = tempfile::tempdir().expect("state directory");
        let path = directory.path().join(DATABASE_FILE);
        let mut connection = SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(true)
            .foreign_keys(true)
            .connect()
            .await
            .expect("legacy connection");
        let mut legacy = sqlx::migrate!("./migrations");
        legacy.migrations = legacy
            .iter()
            .filter(|migration| migration.version < 3)
            .cloned()
            .collect::<Vec<_>>()
            .into();
        legacy
            .run(&mut connection)
            .await
            .expect("legacy migrations");
        seed_identities(&mut connection, identities())
            .await
            .expect("legacy identities");
        sqlx::query(
            "WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 2000)
             INSERT INTO request_events (occurred_at_unix, client_id, group_id, credential_id, model_id, outcome, status_code, request_bytes, response_bytes, latency_ms, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, usage_complete, dropped_events)
             SELECT value * 100, CASE WHEN value % 2 = 0 THEN NULL ELSE 'harness' END, 'anthropic', 'claude', 'model', 'completed', 500, 0, 0, 0, 1, NULL, 3, 4, 0, 0 FROM n",
        ).execute(&mut connection).await.expect("legacy events");
        let mut callbacks = 0;
        connection
            .lock_handle()
            .await
            .expect("handle")
            .set_progress_handler(1000, move || {
                callbacks += 1;
                callbacks < 20
            });
        let interrupted = sqlx::migrate!("./migrations")
            .run(&mut connection)
            .await
            .expect_err("interrupt backfill");
        assert!(
            matches!(interrupted,
            sqlx::migrate::MigrateError::ExecuteMigration(sqlx::Error::Database(ref error), 3)
                if error.code().as_deref() == Some("9")),
            "{interrupted}"
        );
        connection
            .lock_handle()
            .await
            .expect("handle")
            .remove_progress_handler();
        connection
            .close()
            .await
            .expect("close interrupted connection");
        let mut connection = test_connection(&path).await;
        let absent: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'request_chart_daily'",
        )
        .fetch_one(&mut connection)
        .await
        .expect("rolled back table");
        let versions: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM _sqlx_migrations WHERE version = 3")
                .fetch_one(&mut connection)
                .await
                .expect("rolled back version");
        assert_eq!((absent, versions), (0, 0));
        sqlx::migrate!("./migrations")
            .run(&mut connection)
            .await
            .expect("retry migration");
        // The NULL key remains distinct, and all sufficient statistics match raw data.
        let rows: Vec<BackfillRow> = sqlx::query_as(
            "SELECT day_unix, client_key, events, complete_events, error_events, input_tokens, output_tokens_unknown, cache_read_tokens FROM request_chart_daily ORDER BY day_unix, client_key",
        ).fetch_all(&mut connection).await.expect("backfilled rows");
        let raw: Vec<BackfillRow> = sqlx::query_as(
            "SELECT (occurred_at_unix / 86400) * 86400, COALESCE(client_id, ''), COUNT(*), SUM(usage_complete), SUM(status_code >= 400), SUM(input_tokens), SUM(output_tokens IS NULL), SUM(cache_read_tokens) FROM request_events GROUP BY 1, 2 ORDER BY 1, 2",
        ).fetch_all(&mut connection).await.expect("raw reference");
        assert_eq!(rows, raw);
        assert_eq!(rows.iter().map(|row| row.2).sum::<i64>(), 2000);
        connection.close().await.expect("close migrated connection");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("private database");
        let storage = open(directory.path()).await;
        let mut connection = test_connection(&path).await;
        let total: i64 = sqlx::query_scalar("SELECT SUM(events) FROM request_chart_daily")
            .fetch_one(&mut connection)
            .await
            .expect("no duplicate backfill");
        assert_eq!(total, 2000);
        connection.close().await.expect("close test connection");
        close(storage).await;
    }

    #[tokio::test]
    async fn unattributed_request_event_stays_distinct_from_named_client() {
        let directory = tempfile::tempdir().expect("state directory");
        let path = directory.path().join(DATABASE_FILE);
        let mut connection = SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(true)
            .foreign_keys(true)
            .connect()
            .await
            .expect("legacy connection");
        sqlx::migrate!("./migrations")
            .run(&mut connection)
            .await
            .expect("final schema");
        for statement in [
            "INSERT INTO providers VALUES ('claude', 1)",
            "INSERT INTO credentials VALUES ('claude', 'claude', 1)",
            "INSERT INTO groups VALUES ('anthropic', 1)",
            "INSERT INTO group_members VALUES ('anthropic', 'claude')",
            "INSERT INTO request_events (occurred_at_unix, group_id, credential_id, model_id, outcome, status_code, request_bytes, response_bytes, latency_ms, input_tokens, output_tokens, usage_complete, dropped_events) VALUES (10, 'anthropic', 'claude', 'claude-sonnet-5', 'completed', 200, 12, 34, 56, 7, 8, 0, 0)",
        ] {
            sqlx::query(statement)
                .execute(&mut connection)
                .await
                .expect("legacy fixture");
        }
        connection.close().await.expect("close legacy connection");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .expect("private legacy database");
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700))
            .expect("private test state directory");
        let mut seeded = identities();
        seeded.clients.insert(client("legacy-unknown"));
        let storage = SqliteStorage::open(directory.path(), seeded)
            .await
            .expect("migrated private storage");
        let mut current = request(RequestOutcome::Completed, 10);
        current.client = client("legacy-unknown");
        current.model = "claude-sonnet-5".to_owned();
        storage
            .try_append_request_event(current)
            .await
            .expect("real client usage");
        let rows = storage
            .request_usage(RequestUsageQuery {
                bucket_seconds: NonZeroU64::new(60).expect("bucket"),
                group: group("anthropic"),
                since_unix: 1,
                until_unix: 20,
            })
            .await
            .expect("migrated usage");
        assert_eq!(rows.len(), 2);
        let legacy = rows
            .iter()
            .find(|row| row.client.is_none())
            .expect("legacy");
        assert_eq!(legacy.complete_events, 0);
        assert_eq!(legacy.input_tokens, Some(7));
        assert_eq!(legacy.output_tokens, Some(8));
        let current = rows
            .iter()
            .find(|row| row.client == Some(client("legacy-unknown")))
            .expect("real client");
        assert_eq!(current.complete_events, 1);
        assert_eq!(current.events, 1);
        close(storage).await;
    }

    #[tokio::test]
    async fn all_application_tables_are_strict_and_sql_domains_are_enforced() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let tables: Vec<(String, i64)> = sqlx::query_as(
            "SELECT name, strict FROM pragma_table_list WHERE schema = 'main' AND name NOT LIKE 'sqlite_%' AND name != '_sqlx_migrations'",
        )
        .fetch_all(&mut test_connection(&storage.database_path).await)
        .await
        .expect("table list");
        assert!(tables.len() >= 11);
        assert!(tables.iter().all(|(_, strict)| *strict == 1), "{tables:?}");

        assert!(
            sqlx::query("INSERT INTO credentials VALUES ('missing', 'missing-provider', 1)")
                .execute(&mut test_connection(&storage.database_path).await)
                .await
                .is_err(),
            "dangling provider must fail"
        );

        assert!(
            sqlx::query(
                r"
                INSERT INTO request_events
                  (occurred_at_unix, group_id, credential_id, model_id, outcome, status_code,
                   request_bytes, response_bytes, latency_ms, usage_complete, dropped_events)
                VALUES (1, 'anthropic', 'claude', 'model', 'bogus', 200, 1, 1, 1, 1, 0)
                ",
            )
            .execute(&mut test_connection(&storage.database_path).await)
            .await
            .is_err(),
            "invalid enum must fail"
        );

        assert!(
            sqlx::query(
                r"
                INSERT INTO oauth_tokens
                  (credential_id, access_token, refresh_token, access_expires_at_unix, updated_at_unix)
                VALUES (NULL, 'one', 'two', 1, 1)
                ",
            )
            .execute(&mut test_connection(&storage.database_path).await)
            .await
            .is_err(),
            "required NULL must fail"
        );

        assert!(
            sqlx::query(
                r"
                INSERT INTO request_events
                  (occurred_at_unix, group_id, credential_id, model_id, outcome, status_code,
                   request_bytes, response_bytes, latency_ms, usage_complete, dropped_events)
                VALUES (1, 'anthropic', 'claude', 'model', 'completed', 200, 'text', 1, 1, 1, 0)
                ",
            )
            .execute(&mut test_connection(&storage.database_path).await)
            .await
            .is_err(),
            "wrong SQLite storage class must fail"
        );

        assert!(
            sqlx::query(
                r"
                INSERT INTO request_events
                  (occurred_at_unix, group_id, credential_id, model_id, outcome, status_code,
                   request_bytes, response_bytes, latency_ms, usage_complete, dropped_events)
                VALUES (1, 'openai', 'claude', 'model', 'completed', 200, 1, 1, 1, 1, 0)
                ",
            )
            .execute(&mut test_connection(&storage.database_path).await)
            .await
            .is_err(),
            "credential must belong to the request group"
        );

        let foreign_keys: i64 = sqlx::query_scalar("PRAGMA foreign_keys")
            .fetch_one(&mut test_connection(&storage.database_path).await)
            .await
            .expect("foreign keys");
        assert_eq!(foreign_keys, 1);
        let secure_delete: i64 = sqlx::query_scalar("PRAGMA secure_delete")
            .fetch_one(&mut test_connection(&storage.database_path).await)
            .await
            .expect("secure delete");
        assert_eq!(secure_delete, 1);
        close(storage).await;
    }

    #[tokio::test]
    async fn corrupt_startup_is_fatal_and_no_raw_content_columns_exist() {
        let directory = tempfile::tempdir().expect("state directory");
        let database = directory.path().join(DATABASE_FILE);
        let storage = open(directory.path()).await;
        let definitions: Vec<(String, String)> =
            sqlx::query_as("SELECT name, sql FROM sqlite_schema WHERE type = 'table'")
                .fetch_all(&mut test_connection(&storage.database_path).await)
                .await
                .expect("schema");
        for (name, sql) in definitions {
            let lower = sql.to_ascii_lowercase();
            assert!(
                !lower.contains(" body")
                    && !lower.contains(" header")
                    && !lower.contains("prompt")
                    && !lower.contains("tool_argument")
                    && !lower.contains("raw_json"),
                "forbidden raw content storage in {name}: {sql}"
            );
        }
        storage
            .close()
            .await
            .expect("close storage before corruption");
        let mut checkpoint = test_connection(&database).await;
        sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
            .execute(&mut checkpoint)
            .await
            .expect("checkpoint");
        checkpoint.close().await.expect("close checkpoint");

        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&database)
            .expect("database");
        file.seek(SeekFrom::Start(20)).expect("database offset");
        file.write_all(&[0, 0xff]).expect("corrupt database");
        drop(file);
        let Err(error) = SqliteStorage::open(directory.path(), identities()).await else {
            panic!("corrupt database returned a serving handle")
        };
        assert!(
            matches!(
                error,
                StorageError::Database(_) | StorageError::Integrity { .. }
            ),
            "{error}"
        );
    }

    #[tokio::test]
    async fn oauth_operations_do_not_log_token_material() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let replacement = oauth(credential("claude"), 0);
        let sentinels = oauth_sentinels(&replacement);
        let result = async {
            let record = storage
                .replace_oauth_pair(replacement)
                .await
                .expect("OAuth replacement");
            storage
                .oauth_pair(
                    &ClientId::try_from("claude").expect("client ID"),
                    &credential("claude"),
                    &provider("claude"),
                )
                .await
                .expect("OAuth pair");
            tracing::info!(target: "airlock::storage_tests", "{LOG_CAPTURE_MARKER}");
            record
        };
        let (_, logs) = with_captured_logs(result).await;
        assert!(
            logs.contains(LOG_CAPTURE_MARKER),
            "capture was not active: {logs}"
        );
        for secret in sentinels {
            assert!(!logs.contains(secret.as_str()), "logs leaked token");
        }
        close(storage).await;
    }

    #[tokio::test]
    async fn oauth_unique_failure_rolls_back_and_never_exposes_fake_tokens() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let existing = oauth(credential("claude"), 0);
        let existing_sentinels = oauth_sentinels(&existing);
        storage
            .replace_oauth_pair(existing)
            .await
            .expect("first OAuth pair");

        let mut replacement = oauth(credential("zai"), 0);
        replacement.fake_access_token =
            TokenMaterial::new(existing_sentinels[0].as_str().to_owned())
                .expect("duplicate fake token");
        let replacement_sentinels = oauth_sentinels(&replacement);
        let operation = async {
            let result = storage.replace_oauth_pair(replacement).await;
            tracing::error!(target: "airlock::storage_tests", "{LOG_CAPTURE_MARKER}");
            result
        };
        let (result, logs) = with_captured_logs(operation).await;
        let error = result.expect_err("duplicate fake mapping");
        let rendered = error.to_string();
        let debug = format!("{error:?}");
        assert!(
            logs.contains(LOG_CAPTURE_MARKER),
            "capture was not active: {logs}"
        );
        for secrets in [&existing_sentinels, &replacement_sentinels] {
            for secret in secrets {
                assert!(!rendered.contains(secret.as_str()), "error leaked token");
                assert!(!debug.contains(secret.as_str()), "Debug leaked token");
                assert!(!logs.contains(secret.as_str()), "logs leaked token");
            }
        }
        let rows: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM oauth_tokens WHERE credential_id = 'zai'")
                .fetch_one(&mut test_connection(&storage.database_path).await)
                .await
                .expect("token count");
        assert_eq!(rows, 0, "real token insertion must roll back");
        close(storage).await;
    }

    #[tokio::test]
    async fn concurrent_generation_checked_replacement_has_one_winner() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let first = storage.replace_oauth_pair(oauth(credential("claude"), 0));
        let second = storage.replace_oauth_pair(oauth(credential("claude"), 0));
        let (first, second) = tokio::join!(first, second);
        let successes = [first.is_ok(), second.is_ok()]
            .into_iter()
            .filter(|success| *success)
            .count();
        let concurrent = [first.err(), second.err()]
            .into_iter()
            .flatten()
            .filter(|error| matches!(error, StorageError::ConcurrentOauth { .. }))
            .count();
        assert_eq!(successes, 1);
        assert_eq!(concurrent, 1);
        let mapping = storage
            .oauth_pair(
                &ClientId::try_from("claude").expect("client ID"),
                &credential("claude"),
                &provider("claude"),
            )
            .await
            .expect("winner pair");
        assert_eq!(mapping.generation, 1);
        close(storage).await;
    }

    #[tokio::test]
    async fn oauth_pair_lookup_is_client_and_provider_scoped() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let replacement = oauth(credential("claude"), 0);
        let sentinels = oauth_sentinels(&replacement);
        let record = storage
            .replace_oauth_pair(replacement)
            .await
            .expect("OAuth pair");
        let operation = async {
            let result = storage
                .oauth_pair(
                    &ClientId::try_from("claude").expect("client ID"),
                    &credential("claude"),
                    &provider("zai"),
                )
                .await;
            tracing::warn!(target: "airlock::storage_tests", "{LOG_CAPTURE_MARKER}");
            result
        };
        let (result, logs) = with_captured_logs(operation).await;
        let error = result.expect_err("wrong provider");
        let debug = format!("{error:?}");
        assert!(
            logs.contains(LOG_CAPTURE_MARKER),
            "capture was not active: {logs}"
        );
        for secret in sentinels {
            assert!(
                !error.to_string().contains(secret.as_str()),
                "error leaked token"
            );
            assert!(!debug.contains(secret.as_str()), "Debug leaked token");
            assert!(!logs.contains(secret.as_str()), "logs leaked token");
        }

        let wrong_client = storage
            .oauth_pair(
                &ClientId::try_from("other-client").expect("client ID"),
                &credential("claude"),
                &provider("claude"),
            )
            .await
            .expect_err("wrong client cannot read the OAuth pair");
        assert!(matches!(
            wrong_client,
            StorageError::MissingOauthPair { .. }
        ));

        let pair = storage
            .oauth_pair(
                &ClientId::try_from("claude").expect("client ID"),
                &credential("claude"),
                &provider("claude"),
            )
            .await
            .expect("joined OAuth pair");
        assert_eq!(pair.credential, credential("claude"));
        assert_eq!(pair.generation, 1);
        assert_eq!(
            pair.fake_access_token.as_str(),
            record.fake_access_token.as_str()
        );
        assert_eq!(
            pair.real_access_token.as_str(),
            record.real_access_token.as_str()
        );
        assert_eq!(pair.fake_access_expires_at_unix, 3_600);
        assert_eq!(pair.real_access_expires_at_unix, 3_600);
        assert_eq!(pair.real_refresh_expires_at_unix, Some(86_400));
        close(storage).await;
    }

    #[tokio::test]
    async fn absent_oauth_pair_requires_generation_zero() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let error = storage
            .replace_oauth_pair(oauth(credential("zai"), 5))
            .await
            .expect_err("nonzero generation for absent mapping");
        assert!(
            matches!(error, StorageError::ConcurrentOauth { .. }),
            "{error}"
        );

        let mut connection = test_connection(&storage.database_path).await;
        let mappings: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM oauth_mappings WHERE credential_id = 'zai'")
                .fetch_one(&mut connection)
                .await
                .expect("mapping count");
        let tokens: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM oauth_tokens WHERE credential_id = 'zai'")
                .fetch_one(&mut connection)
                .await
                .expect("token count");
        assert_eq!(mappings, 0);
        assert_eq!(tokens, 0);
        connection.close().await.expect("close test connection");
        close(storage).await;
    }

    #[tokio::test]
    async fn request_usage_fails_fast_when_local_pool_is_busy() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let mut held_connection = storage.connection.lock().await;
        let held = held_connection.begin().await.expect("held transaction");

        let error = storage
            .try_append_request_event(request(RequestOutcome::Completed, 10))
            .await
            .expect_err("pool unavailable");
        assert!(matches!(error, StorageError::UsageUnavailable), "{error}");

        held.commit().await.expect("release transaction");
        drop(held_connection);
        storage
            .try_append_request_event(request(RequestOutcome::Completed, 10))
            .await
            .expect("append after release");
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM request_events")
            .fetch_one(&mut test_connection(&storage.database_path).await)
            .await
            .expect("request count");
        assert_eq!(rows, 1);
        close(storage).await;
    }

    #[tokio::test]
    async fn request_usage_fails_fast_when_database_writer_is_busy() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let options = SqliteConnectOptions::new()
            .filename(&storage.database_path)
            .foreign_keys(true);
        let mut external = SqliteConnection::connect_with(&options)
            .await
            .expect("external writer");
        sqlx::query("BEGIN IMMEDIATE")
            .execute(&mut external)
            .await
            .expect("external write lock");

        let error = storage
            .try_append_request_event(request(RequestOutcome::Completed, 10))
            .await
            .expect_err("busy database");
        assert!(
            matches!(error, StorageError::Database(_))
                && !matches!(error, StorageError::UsageUnavailable),
            "{error}"
        );
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM request_events")
            .fetch_one(&mut test_connection(&storage.database_path).await)
            .await
            .expect("request count");
        assert_eq!(rows, 0, "failed append must not be acknowledged");

        sqlx::query("ROLLBACK")
            .execute(&mut external)
            .await
            .expect("release external writer");
        drop(external);
        storage
            .try_append_request_event(request(RequestOutcome::Completed, 10))
            .await
            .expect("append after release");
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM request_events")
            .fetch_one(&mut test_connection(&storage.database_path).await)
            .await
            .expect("request count");
        assert_eq!(rows, 1);
        close(storage).await;
    }

    #[tokio::test]
    async fn usage_ranges_larger_than_the_aggregate_bound_fail_explicitly() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        for ordinal in 0..=(MAX_AGGREGATE_ROWS + 1) {
            let mut event = request(RequestOutcome::Completed, 10);
            event.model = format!("model-{ordinal}");
            storage
                .try_append_request_event(event)
                .await
                .expect("usage event");
        }

        let error = storage
            .request_usage(RequestUsageQuery {
                group: group("anthropic"),
                bucket_seconds: NonZeroU64::new(60).expect("bucket seconds"),
                since_unix: 1,
                until_unix: 20,
            })
            .await
            .expect_err("over-bound aggregate");
        assert!(
            matches!(error, StorageError::UsageRangeIncomplete),
            "{error}"
        );
        close(storage).await;
    }

    #[tokio::test]
    async fn nullable_token_dimensions_stay_unknown_in_aggregates() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        storage
            .try_append_request_event(request(RequestOutcome::Completed, 10))
            .await
            .expect("known usage");
        let mut unknown_input = request(RequestOutcome::Completed, 11);
        unknown_input.input_tokens = None;
        unknown_input.output_tokens = Some(17);
        unknown_input.request_bytes = 20;
        unknown_input.response_bytes = 30;
        unknown_input.latency_ms = 5;
        storage
            .try_append_request_event(unknown_input)
            .await
            .expect("unknown usage");

        let usage = storage
            .request_usage(RequestUsageQuery {
                group: group("anthropic"),
                bucket_seconds: NonZeroU64::new(60).expect("bucket seconds"),
                since_unix: 1,
                until_unix: 20,
            })
            .await
            .expect("aggregate");
        assert_eq!(usage.len(), 1);
        assert_eq!(usage[0].events, 2);
        assert_eq!(usage[0].input_tokens, None);
        assert_eq!(usage[0].output_tokens, Some(30));
        assert_eq!(usage[0].request_bytes, 120);
        assert_eq!(usage[0].response_bytes, 230);
        assert_eq!(usage[0].latency_ms, 30);
        close(storage).await;
    }

    #[tokio::test]
    async fn snapshot_history_keeps_children_with_their_headers() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let mut first = snapshot(10);
        first.pools[0].label = "first".to_owned();
        storage
            .append_provider_snapshot(first)
            .await
            .expect("first");
        let mut second = snapshot(20);
        second.pools[0].label = "second".to_owned();
        second.metrics.clear();
        storage
            .append_provider_snapshot(second)
            .await
            .expect("second");
        let mut gap = snapshot(30);
        gap.fetch_status = SnapshotFetchStatus::Gap;
        gap.gap_reason = Some("fake provider unavailable".to_owned());
        gap.credits.clear();
        gap.metrics.clear();
        gap.pools.clear();
        storage.append_provider_snapshot(gap).await.expect("gap");

        let history = storage
            .provider_snapshots(SnapshotQuery {
                limit: NonZeroU64::new(2).expect("limit"),
                provider: provider("claude"),
                since_unix: 1,
            })
            .await
            .expect("bounded history");
        assert_eq!(history.len(), 2);
        assert_eq!(history[0].pools[0].label, "second");
        assert_eq!(history[0].metrics, []);
        assert_eq!(history[1].fetch_status, SnapshotFetchStatus::Gap);
        assert_eq!(
            history[1].gap_reason.as_deref(),
            Some("fake provider unavailable")
        );
        assert_eq!(history[1].pools, []);
        assert_eq!(history[1].metrics, []);

        let all = storage
            .provider_snapshots(SnapshotQuery {
                limit: NonZeroU64::new(3).expect("limit"),
                provider: provider("claude"),
                since_unix: 1,
            })
            .await
            .expect("history");
        assert_eq!(all.len(), 3);
        assert_eq!(all[2].fetch_status, SnapshotFetchStatus::Gap);
        assert_eq!(
            all[2].gap_reason.as_deref(),
            Some("fake provider unavailable")
        );
        assert_eq!(all[2].pools, []);

        let error = storage
            .provider_snapshots(SnapshotQuery {
                limit: NonZeroU64::new(1_001).expect("limit"),
                provider: provider("claude"),
                since_unix: 1,
            })
            .await
            .expect_err("unbounded history");
        assert!(matches!(error, StorageError::Input { .. }));
        close(storage).await;
    }

    #[tokio::test]
    async fn identified_history_bounds_windows_and_predecessor_follows_filter() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        for timestamp in [10, 11, 12, 13, 14, 15] {
            storage
                .append_provider_snapshot(snapshot(timestamp))
                .await
                .expect("target snapshot");
        }
        let mut noisy = snapshot(11);
        noisy.source = SnapshotSource::ResponseHeaders;
        noisy.surface = SnapshotSurface::ResponseHeaders;
        storage
            .append_provider_snapshot(noisy)
            .await
            .expect("other surface");

        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("read-only storage")
            .into_control_reader();
        let page = reader
            .identified_snapshot_page(
                SnapshotQuery {
                    limit: NonZeroU64::new(2).expect("limit"),
                    provider: provider("claude"),
                    since_unix: 1,
                },
                13,
                credential("claude"),
                SnapshotSource::OutOfBandFetch,
                SnapshotSurface::ClaudeSubscription,
            )
            .await
            .expect("filtered page");
        let timestamps = page
            .snapshots
            .iter()
            .map(|snapshot| snapshot.snapshot.fetched_at_unix)
            .collect::<Vec<_>>();
        assert_eq!(timestamps, [11, 12]);
        let predecessor = page.predecessor.expect("same-filter predecessor");
        assert_eq!(predecessor.snapshot.fetched_at_unix, 10);
        assert!(page.truncated);
        let boundary = reader
            .identified_snapshot_page(
                SnapshotQuery {
                    limit: NonZeroU64::new(10).expect("limit"),
                    provider: provider("claude"),
                    since_unix: 11,
                },
                13,
                credential("claude"),
                SnapshotSource::OutOfBandFetch,
                SnapshotSurface::ClaudeSubscription,
            )
            .await
            .expect("boundary page");
        assert_eq!(
            boundary
                .snapshots
                .iter()
                .map(|row| row.snapshot.fetched_at_unix)
                .collect::<Vec<_>>(),
            [11, 12]
        );
        assert_eq!(
            boundary
                .predecessor
                .expect("outside-window predecessor")
                .snapshot
                .fetched_at_unix,
            10
        );
        assert!(!boundary.truncated);
        reader
            .connection
            .close()
            .await
            .expect("close control reader");
        close(storage).await;
    }

    async fn persisted_control_budget_directory() -> tempfile::TempDir {
        const SNAPSHOTS: i64 = 1_001;
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        for timestamp in 1..=SNAPSHOTS {
            storage
                .append_provider_snapshot(snapshot(timestamp))
                .await
                .expect("bounded provider history");
        }
        let mut connection = test_connection(&directory.path().join(DATABASE_FILE)).await;
        sqlx::query(
            r"
            WITH RECURSIVE sequence(value) AS (
                SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < 2000000
            )
            INSERT INTO request_events (
              occurred_at_unix, client_id, group_id, credential_id, model_id, outcome,
              status_code, request_bytes, response_bytes, latency_ms, input_tokens,
              output_tokens, cache_read_tokens, cache_write_tokens, usage_complete,
              dropped_events
            )
            SELECT value, 'harness', 'anthropic', 'claude', 'model-' || value, 'completed',
                   200, 100, 200, 25, 11, 13, 7, NULL, 1, 0
            FROM sequence
            ",
        )
        .execute(&mut connection)
        .await
        .expect("persisted request history");
        connection.close().await.expect("close fixture connection");
        close(storage).await;
        directory
    }

    #[tokio::test]
    async fn persisted_large_history_measures_control_view_query_budgets() {
        use sqlx::Row as _;

        const REQUEST_ROWS: i64 = 2_000_000;
        const SNAPSHOTS: i64 = 1_001;
        let directory = persisted_control_budget_directory().await;
        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("control reader storage")
            .into_control_reader();
        let request_started = std::time::Instant::now();
        let request_error = reader
            .request_series(RequestSeriesQuery {
                bucket_seconds: NonZeroU64::new(60).expect("bucket"),
                client: None,
                credential: None,
                group: None,
                model: None,
                outcome: None,
                provider: None,
                since_unix: 1,
                until_unix: REQUEST_ROWS + 1,
            })
            .await
            .expect_err("large aggregate is bounded");
        let request_elapsed = request_started.elapsed();
        assert!(
            matches!(request_error, StorageError::QueryBudgetExceeded),
            "request aggregate error: {request_error}"
        );

        let table_started = std::time::Instant::now();
        let table_page = reader
            .request_row_page(RequestRowQuery {
                before: None,
                client: None,
                credential: None,
                group: None,
                limit: 200,
                model: None,
                outcome: None,
                provider: None,
                since_unix: 1,
                until_unix: REQUEST_ROWS + 1,
            })
            .await
            .expect("bounded request table view");
        let table_elapsed = table_started.elapsed();
        assert_eq!(table_page.rows.len(), 200);

        let mut plan = test_connection(&directory.path().join(DATABASE_FILE)).await;
        let query_plan = sqlx::query(
            "EXPLAIN QUERY PLAN SELECT COALESCE(SUM(dropped_events), 0) FROM request_events",
        )
        .fetch_all(&mut plan)
        .await
        .expect("request loss query plan");
        let rendered_plan = query_plan
            .iter()
            .map(|row| row.get::<String, _>("detail"))
            .collect::<Vec<_>>()
            .join("; ");
        plan.close().await.expect("close plan connection");
        assert!(
            rendered_plan.contains("COVERING INDEX request_events_dropped_cover_idx"),
            "request loss sum must use the covering index: {rendered_plan}"
        );

        let provider_started = std::time::Instant::now();
        let provider_page = reader
            .identified_snapshot_page(
                SnapshotQuery {
                    limit: NonZeroU64::new(1_000).expect("provider limit"),
                    provider: provider("claude"),
                    since_unix: 1,
                },
                SNAPSHOTS + 1,
                credential("claude"),
                SnapshotSource::OutOfBandFetch,
                SnapshotSurface::ClaudeSubscription,
            )
            .await
            .expect("bounded provider view");
        let provider_elapsed = provider_started.elapsed();
        assert_eq!(provider_page.snapshots.len(), 1_000);

        println!(
            "persisted control budgets: full aggregate {request_elapsed:?} (refused), request table {table_elapsed:?}, provider view {provider_elapsed:?}"
        );
        assert!(
            table_elapsed < ControlReader::QUERY_BUDGET,
            "request table view exceeded its budget: {table_elapsed:?}"
        );
        assert!(
            provider_elapsed < ControlReader::QUERY_BUDGET,
            "provider view exceeded its budget: {provider_elapsed:?}"
        );
        reader
            .connection
            .close()
            .await
            .expect("close control reader");
    }
    #[tokio::test]
    async fn cancelled_control_sql_and_queued_acquisition_allow_immediate_reuse() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("reader")
            .into_control_reader();
        let started = std::time::Instant::now();
        {
            let mut report = reader.report_transaction().await.expect("HTTP transaction");
            let heavy = sqlx::query("WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v+1 FROM n WHERE v<200000000) SELECT SUM(v) FROM n")
                .fetch_all(&mut *report.transaction);
            assert!(
                tokio::time::timeout(std::time::Duration::from_millis(10), heavy)
                    .await
                    .is_err()
            );
            // Dropping the HTTP view cancels executing SQL and queues transaction rollback.
        }
        tokio::time::timeout(
            std::time::Duration::from_millis(100),
            reader.overview(vec![]),
        )
        .await
        .expect("WS immediately reuses reader")
        .expect("fresh WS budget");
        let mut report = reader
            .report_transaction()
            .await
            .expect("HTTP immediately reuses reader");
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT 42")
                .fetch_one(&mut *report.transaction)
                .await
                .expect("live HTTP transaction"),
            42
        );
        report.finish(Ok(())).await.expect("HTTP cleanup");
        assert!(
            started.elapsed() < ControlReader::QUERY_BUDGET,
            "cancelled SQL must not run until its original budget"
        );
        assert!(!reader.connection.is_in_transaction());

        let shared_reader = Arc::new(tokio::sync::Mutex::new(reader));
        let held = shared_reader.lock().await;
        let pending_reader = Arc::clone(&shared_reader);
        let queued =
            tokio::spawn(async move { pending_reader.lock().await.overview(vec![]).await });
        tokio::task::yield_now().await;
        queued.abort();
        assert!(
            queued
                .await
                .expect_err("cancelled queued reader")
                .is_cancelled()
        );
        drop(held);
        let mut reader = shared_reader.lock().await;
        tokio::time::timeout(
            std::time::Duration::from_millis(100),
            reader.overview(vec![]),
        )
        .await
        .expect("WS after queued cancellation")
        .expect("WS page");
        let report = reader
            .report_transaction()
            .await
            .expect("HTTP after queued cancellation");
        report
            .finish(Ok(()))
            .await
            .expect("HTTP cleanup after queued cancellation");
        drop(reader);
        let reader = Arc::try_unwrap(shared_reader)
            .ok()
            .expect("sole reader owner")
            .into_inner();
        tokio::time::timeout(
            std::time::Duration::from_millis(100),
            reader.connection.close(),
        )
        .await
        .expect("bounded reader shutdown")
        .expect("reader closes");
        close(storage).await;
    }

    #[tokio::test]
    async fn http_report_sections_share_one_sqlite_snapshot() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("reader")
            .into_control_reader();
        let mut report = reader
            .report_transaction()
            .await
            .expect("report transaction");
        assert_eq!(
            report
                .report_request_usage_loss_total()
                .await
                .expect("first section"),
            0
        );
        let mut event = request(RequestOutcome::Completed, 10);
        event.dropped_events = 3;
        storage
            .try_append_request_event(event)
            .await
            .expect("concurrent durable writer");
        assert_eq!(
            report
                .report_request_usage_loss_total()
                .await
                .expect("second section"),
            0
        );
        report.finish(Ok(())).await.expect("finish report");
        let mut next = reader.report_transaction().await.expect("next report");
        assert_eq!(
            next.report_request_usage_loss_total()
                .await
                .expect("next snapshot"),
            3
        );
        next.finish(Ok(())).await.expect("finish next report");
        close(storage).await;
    }

    #[tokio::test]
    async fn control_progress_deadline_interrupts_work_and_clears_afterward() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("read-only storage")
            .into_control_reader();
        let heavy_fixture = r"
            WITH RECURSIVE sequence(value) AS (
                SELECT 1
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < 20000000
            )
            SELECT COUNT(*), SUM(value) FROM sequence
        ";

        let deadline = reader.deadline().await.expect("install progress handler");
        let interrupted = sqlx::query(heavy_fixture)
            .fetch_all(&mut reader.connection)
            .await;
        assert!(
            matches!(
                ControlReader::bounded(&deadline, interrupted.map_err(StorageError::from)),
                Err(StorageError::QueryBudgetExceeded)
            ),
            "the progress handler must interrupt after 250 milliseconds"
        );
        reader
            .clear_deadline()
            .await
            .expect("clear progress handler");
        sqlx::query(heavy_fixture)
            .fetch_all(&mut reader.connection)
            .await
            .expect("same synthetic fixture completes without the deadline");
        reader
            .connection
            .close()
            .await
            .expect("close control reader");
        close(storage).await;
    }

    #[tokio::test]
    async fn child_reads_reject_quick_check_clean_rows_above_each_bound() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        storage
            .append_provider_snapshot(snapshot(20))
            .await
            .expect("bounded fixture");
        let mut connection = test_connection(&storage.database_path).await;
        let snapshot_id: i64 = sqlx::query_scalar("SELECT id FROM provider_snapshots LIMIT 1")
            .fetch_one(&mut connection)
            .await
            .expect("snapshot id");
        for ordinal in 1_i64..=64 {
            let label = format!("pool-{ordinal}");
            sqlx::query("INSERT INTO quota_pools (snapshot_id, ordinal, label, utilized, limit_value) VALUES (?, ?, ?, 1, 100)")
                .bind(snapshot_id).bind(ordinal).bind(&label).execute(&mut connection).await.expect("extra pool");
            sqlx::query("INSERT INTO credit_pools (snapshot_id, ordinal, label, used_minor_units, remaining_minor_units, limit_minor_units) VALUES (?, ?, ?, 1, 99, 100)")
                .bind(snapshot_id).bind(ordinal).bind(&label).execute(&mut connection).await.expect("extra credit");
            sqlx::query("INSERT INTO quota_metrics (snapshot_id, ordinal, label, value, unit) VALUES (?, ?, ?, 1, 'count')")
                .bind(snapshot_id).bind(ordinal).bind(&label).execute(&mut connection).await.expect("extra metric");
        }
        for ordinal in 0_i64..=64 {
            sqlx::query("INSERT INTO claude_limits (snapshot_id, ordinal, kind, percent_milli, is_active) VALUES (?, ?, 'rate', 1000, 1)")
                .bind(snapshot_id).bind(ordinal).execute(&mut connection).await.expect("extra limit");
        }
        quick_check(&mut connection, &storage.database_path)
            .await
            .expect("structurally valid SQLite");
        for excess_result in [
            quota_pools_many(&mut connection, &[snapshot_id], &storage.database_path)
                .await
                .map(|_| ()),
            credit_pools_many(&mut connection, &[snapshot_id], &storage.database_path)
                .await
                .map(|_| ()),
            quota_metrics_many(&mut connection, &[snapshot_id], &storage.database_path)
                .await
                .map(|_| ()),
            claude_limits_many(&mut connection, &[snapshot_id], &storage.database_path)
                .await
                .map(|_| ()),
            bounded_grouped_children(
                vec![(1, 0), (1, 1), (1, 2)],
                MAX_RESPONSE_WINDOWS,
                &storage.database_path,
            )
            .map(|_| ()),
        ] {
            assert!(matches!(excess_result, Err(StorageError::Integrity { .. })));
        }
        connection.close().await.expect("close fixture connection");
        close(storage).await;
    }

    #[tokio::test]
    async fn snapshot_write_loss_recovers_after_sqlite_contention() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let mut blocker = test_connection(&storage.database_path).await;
        sqlx::query("BEGIN IMMEDIATE")
            .execute(&mut blocker)
            .await
            .expect("writer lock");
        storage
            .append_provider_snapshot_observed(snapshot(20))
            .await;
        sqlx::query("ROLLBACK")
            .execute(&mut blocker)
            .await
            .expect("release writer lock");
        storage
            .append_provider_snapshot_observed(snapshot(21))
            .await;
        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("read-only report state");
        assert_eq!(
            reader.provider_snapshot_loss_total().await.expect("loss"),
            1
        );
        let snapshots = reader
            .provider_snapshots(SnapshotQuery {
                limit: NonZeroU64::new(2).expect("limit"),
                provider: provider("claude"),
                since_unix: 1,
            })
            .await
            .expect("history");
        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0].fetched_at_unix, 21);
        blocker.close().await.expect("close blocker");
        close(storage).await;
    }

    #[tokio::test]
    async fn close_persists_pending_snapshot_loss_without_another_observation() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        storage.record_provider_snapshot_loss();
        close(storage).await;
        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("read-only report state");
        assert_eq!(
            reader.provider_snapshot_loss_total().await.expect("loss"),
            1
        );
    }

    #[tokio::test]
    async fn cancelled_loss_flush_keeps_pending_count_for_close() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = Arc::new(open(directory.path()).await);
        storage.record_provider_snapshot_loss();
        let connection_guard = storage.connection.lock().await;
        let flushing = Arc::clone(&storage);
        let task = tokio::spawn(async move {
            flushing.flush_provider_snapshot_losses(20).await;
        });
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if storage.snapshot_loss_flush_lock.try_lock().is_err() {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("flush must begin before cancellation");
        task.abort();
        let _ = task.await;
        drop(connection_guard);
        Arc::try_unwrap(storage)
            .ok()
            .expect("sole storage owner")
            .close()
            .await
            .expect("close and recover loss");
        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("read-only report state");
        assert_eq!(
            reader.provider_snapshot_loss_total().await.expect("loss"),
            1
        );
    }

    #[tokio::test]
    async fn unsafe_paths_and_permissions_are_refused() {
        let parent = tempfile::tempdir().expect("parent");
        let target = parent.path().join("target");
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&target)
            .expect("target state");
        let link = parent.path().join("state-link");
        symlink(&target, &link).expect("state symlink");
        assert!(matches!(
            SqliteStorage::open(&link, identities()).await,
            Err(StorageError::NotPrivateDirectory { .. })
        ));

        let directory = tempfile::tempdir().expect("state");
        let storage = open(directory.path()).await;
        close(storage).await;
        let database = directory.path().join(DATABASE_FILE);
        fs::set_permissions(&database, PermissionsExt::from_mode(0o640)).expect("database mode");
        assert!(matches!(
            SqliteStorage::open(directory.path(), identities()).await,
            Err(StorageError::NotPrivateFile { .. })
        ));
        fs::set_permissions(&database, PermissionsExt::from_mode(0o600)).expect("database mode");

        fs::remove_file(&database).expect("database");
        let database_target = directory.path().join("database-target");
        fs::write(&database_target, b"unused").expect("database target");
        symlink(&database_target, &database).expect("database symlink");
        assert!(matches!(
            SqliteStorage::open(directory.path(), identities()).await,
            Err(StorageError::NotPrivateFile { .. })
        ));
        fs::remove_file(&database).expect("database symlink");
        fs::copy(&database_target, &database).expect("restore database");
        fs::set_permissions(&database, PermissionsExt::from_mode(0o600)).expect("database mode");

        let journal = directory.path().join(format!("{DATABASE_FILE}-journal"));
        fs::write(&journal, b"journal").expect("journal");
        fs::set_permissions(&journal, PermissionsExt::from_mode(0o640)).expect("journal mode");
        let Err(StorageError::NotPrivateFile { path }) =
            SqliteStorage::open(directory.path(), identities()).await
        else {
            panic!("unsafe journal mode returned a serving handle");
        };
        assert_eq!(path, journal);
        fs::remove_file(&journal).expect("journal");
        fs::write(&database_target, b"journal").expect("journal target");
        symlink(&database_target, &journal).expect("journal symlink");
        let Err(StorageError::NotPrivateFile { path }) =
            SqliteStorage::open(directory.path(), identities()).await
        else {
            panic!("journal symlink returned a serving handle");
        };
        assert_eq!(path, journal);
        fs::remove_file(&journal).expect("journal symlink");

        let companion = directory.path().join(format!("{DATABASE_FILE}-wal"));
        fs::write(&companion, b"wal").expect("companion");
        fs::set_permissions(&companion, PermissionsExt::from_mode(0o640)).expect("companion mode");
        let Err(StorageError::NotPrivateFile { path }) =
            SqliteStorage::open(directory.path(), identities()).await
        else {
            panic!("unsafe WAL mode returned a serving handle");
        };
        assert_eq!(path, companion);
        fs::remove_file(&companion).expect("companion");
        fs::write(&database_target, b"wal").expect("companion target");
        symlink(&database_target, &companion).expect("companion symlink");
        let Err(StorageError::NotPrivateFile { path }) =
            SqliteStorage::open(directory.path(), identities()).await
        else {
            panic!("WAL symlink returned a serving handle");
        };
        assert_eq!(path, companion);
    }

    #[test]
    fn token_material_redacts_debug_and_zeroizes_rejected_values_by_construction() {
        let secret = "x".repeat(8193);
        let error = TokenMaterial::new(secret.clone()).expect_err("oversized token");
        assert!(!error.to_string().contains(&secret));
        let visible = token("visible");
        assert!(!format!("{visible:?}").contains("fake-visible-token"));
    }

    #[tokio::test]
    async fn storage_input_validation_refuses_unbounded_and_invalid_values() {
        let directory = tempfile::tempdir().expect("state");
        let storage = open(directory.path()).await;
        let mut invalid_time = request(RequestOutcome::Completed, 10);
        invalid_time.occurred_at_unix = 0;
        assert!(
            storage
                .try_append_request_event(invalid_time)
                .await
                .is_err()
        );

        let mut invalid_status = request(RequestOutcome::Completed, 10);
        invalid_status.status_code = 99;
        assert!(
            storage
                .try_append_request_event(invalid_status)
                .await
                .is_err()
        );

        let mut invalid_model = request(RequestOutcome::Completed, 10);
        invalid_model.model = String::new();
        assert!(
            storage
                .try_append_request_event(invalid_model)
                .await
                .is_err()
        );

        let mut invalid_snapshot = snapshot(10);
        invalid_snapshot.pools = (0..65)
            .map(|ordinal| QuotaPool {
                label: format!("pool-{ordinal}"),
                limit: 10,
                reset_at_unix: None,
                utilized: 1,
            })
            .collect();
        assert!(
            storage
                .append_provider_snapshot(invalid_snapshot)
                .await
                .is_err()
        );

        let mut invalid_gap = snapshot(10);
        invalid_gap.fetch_status = SnapshotFetchStatus::Gap;
        assert!(storage.append_provider_snapshot(invalid_gap).await.is_err());

        let mut invalid_label = snapshot(10);
        invalid_label.pools[0].label = String::new();
        assert!(
            storage
                .append_provider_snapshot(invalid_label)
                .await
                .is_err()
        );

        let mut invalid_unit = snapshot(10);
        invalid_unit.metrics[0].unit = "much-too-long-unit-value".to_owned();
        assert!(
            storage
                .append_provider_snapshot(invalid_unit)
                .await
                .is_err()
        );
        close(storage).await;
    }
    #[tokio::test]
    async fn reviewer_cancelled_observation_must_be_counted() {
        let directory = tempfile::tempdir().expect("fake state");
        let storage = open(directory.path()).await;
        {
            let _guard = storage.connection.lock().await;
            let mut observation =
                std::pin::pin!(storage.append_provider_snapshot_observed(snapshot(20)));
            std::future::poll_fn(|cx| {
                assert!(observation.as_mut().poll(cx).is_pending());
                std::task::Poll::Ready(())
            })
            .await;
        }
        close(storage).await;
        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("fake history");
        let history = reader
            .provider_snapshots(SnapshotQuery {
                limit: NonZeroU64::MIN,
                provider: provider("claude"),
                since_unix: 1,
            })
            .await
            .expect("history");
        let lost = reader
            .provider_snapshot_loss_total()
            .await
            .expect("loss total");
        assert!(
            history.is_empty(),
            "a cancelled pending observation must not append"
        );
        assert_eq!(lost, 1);
    }
    #[tokio::test]
    async fn caller_cancellation_never_counts_a_committed_observation_twice() {
        let directory = tempfile::tempdir().expect("fake state");
        let storage = open(directory.path()).await;
        for at in 20..52 {
            let mut observation =
                std::pin::pin!(storage.append_provider_snapshot_observed(snapshot(at)));
            std::future::poll_fn(|cx| {
                let _ = observation.as_mut().poll(cx);
                std::task::Poll::Ready(())
            })
            .await;
            tokio::task::yield_now().await;
        }
        close(storage).await;
        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("fake history");
        let history = reader
            .provider_snapshots(SnapshotQuery {
                limit: NonZeroU64::new(32).expect("limit"),
                provider: provider("claude"),
                since_unix: 1,
            })
            .await
            .expect("history");
        let lost = reader
            .provider_snapshot_loss_total()
            .await
            .expect("loss total");
        assert_eq!(
            history.len() + usize::try_from(lost).expect("bounded loss"),
            32
        );
    }

    #[tokio::test]
    async fn committed_observation_survives_cancelled_ack_without_loss() {
        let directory = tempfile::tempdir().expect("fake state");
        let storage = open(directory.path()).await;
        let (committed_sender, committed_receiver) = tokio::sync::oneshot::channel();
        let (release_sender, release_receiver) = tokio::sync::oneshot::channel();
        *storage.observation_after_commit.lock().expect("test hook") =
            Some((committed_sender, release_receiver));
        {
            let mut observation =
                std::pin::pin!(storage.append_provider_snapshot_observed(snapshot(20)));
            std::future::poll_fn(|cx| {
                assert!(observation.as_mut().poll(cx).is_pending());
                std::task::Poll::Ready(())
            })
            .await;
            committed_receiver
                .await
                .expect("row committed before acknowledgement");
        }
        release_sender.send(()).expect("release writer");
        close(storage).await;
        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("fake history");
        let history = reader
            .provider_snapshots(SnapshotQuery {
                limit: NonZeroU64::MIN,
                provider: provider("claude"),
                since_unix: 1,
            })
            .await
            .expect("history");
        assert_eq!(history.len(), 1);
        assert_eq!(
            reader
                .provider_snapshot_loss_total()
                .await
                .expect("loss total"),
            0
        );
    }

    #[tokio::test]
    async fn control_client_null_filter_differs_from_omitted_filter() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        let known = request(RequestOutcome::Completed, 10);
        storage
            .try_append_request_event(known.clone())
            .await
            .expect("known client event");
        storage
            .try_append_request_event(known)
            .await
            .expect("second known client event");
        let mut connection = test_connection(&directory.path().join(DATABASE_FILE)).await;
        sqlx::query("UPDATE request_events SET client_id = NULL WHERE rowid = (SELECT MAX(id) FROM request_events)")
            .execute(&mut connection)
            .await
            .expect("historical unknown fixture");
        connection.close().await.expect("close fixture connection");
        close(storage).await;

        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("control reader storage")
            .into_control_reader();
        let base_series = RequestSeriesQuery {
            bucket_seconds: NonZeroU64::new(60).expect("bucket"),
            client: None,
            credential: None,
            group: None,
            model: None,
            outcome: None,
            provider: None,
            since_unix: 1,
            until_unix: 20,
        };
        let omitted = reader
            .request_series(base_series.clone())
            .await
            .expect("omitted client series");
        assert_eq!(omitted.aggregates.len(), 2);
        let unknown_series = reader
            .request_series(RequestSeriesQuery {
                client: Some(None),
                ..base_series.clone()
            })
            .await
            .expect("explicit unknown client series");
        assert_eq!(unknown_series.aggregates.len(), 1);
        assert!(unknown_series.aggregates[0].aggregate.client.is_none());

        let base_rows = RequestRowQuery {
            before: None,
            client: None,
            credential: None,
            group: None,
            limit: 200,
            model: None,
            outcome: None,
            provider: None,
            since_unix: 1,
            until_unix: 20,
        };
        let omitted_rows = reader
            .request_row_page(base_rows.clone())
            .await
            .expect("omitted client rows");
        assert_eq!(omitted_rows.rows.len(), 2);
        let unknown_rows = reader
            .request_row_page(RequestRowQuery {
                client: Some(None),
                ..base_rows
            })
            .await
            .expect("explicit unknown client rows");
        assert_eq!(unknown_rows.rows.len(), 1);
        assert!(unknown_rows.rows[0].client.is_none());
    }

    #[tokio::test]
    async fn late_backdated_event_cannot_cross_frozen_request_cutoff() {
        let directory = tempfile::tempdir().expect("state directory");
        let storage = open(directory.path()).await;
        storage
            .try_append_request_event(request(RequestOutcome::Completed, 10))
            .await
            .expect("first historical event");
        storage
            .try_append_request_event(request(RequestOutcome::Completed, 10))
            .await
            .expect("second historical event");

        let mut reader = ReadOnlyStorage::open(directory.path())
            .await
            .expect("control reader storage")
            .into_control_reader();
        let first = reader
            .request_row_page(RequestRowQuery {
                before: None,
                client: None,
                credential: None,
                group: None,
                limit: 1,
                model: None,
                outcome: None,
                provider: None,
                since_unix: 1,
                until_unix: 20,
            })
            .await
            .expect("first page");
        assert_eq!(first.rows.len(), 1);
        assert_eq!(first.rows[0].id, 2);
        let frozen = first.next_before.expect("first page cursor").cutoff_id;
        assert_eq!(frozen, 2);

        storage
            .try_append_request_event(request(RequestOutcome::Completed, 10))
            .await
            .expect("late backdated event");
        let second = reader
            .request_row_page(RequestRowQuery {
                before: Some(RequestRowCursor {
                    cutoff_id: frozen,
                    occurred_at_unix: 10,
                    row_id: 2,
                }),
                client: None,
                credential: None,
                group: None,
                limit: 1,
                model: None,
                outcome: None,
                provider: None,
                since_unix: 1,
                until_unix: 20,
            })
            .await
            .expect("frozen historical page");
        assert_eq!(second.rows.len(), 1);
        assert_eq!(second.rows[0].id, 1);
        close(storage).await;
    }
}

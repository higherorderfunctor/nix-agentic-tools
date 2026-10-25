//! Guarded SQLite persistence for airlock daemon state.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, DirBuilder, OpenOptions},
    future::Future,
    io,
    num::NonZeroU64,
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SnapshotFetchStatus {
    Gap,
    Success,
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

#[derive(Debug, PartialEq, Eq)]
pub struct QuotaPool {
    pub label: String,
    pub limit: u64,
    pub reset_at_unix: Option<i64>,
    pub utilized: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub struct CreditPool {
    pub label: String,
    pub limit_minor_units: u64,
    pub remaining_minor_units: u64,
    pub reset_at_unix: Option<i64>,
    pub used_minor_units: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub struct QuotaMetric {
    pub label: String,
    pub unit: String,
    pub value: u64,
}

#[derive(Debug)]
pub struct ProviderSnapshot {
    pub account_id: String,
    pub credits: Vec<CreditPool>,
    pub fetched_at_unix: i64,
    pub fetch_status: SnapshotFetchStatus,
    pub gap_reason: Option<String>,
    pub metrics: Vec<QuotaMetric>,
    pub pools: Vec<QuotaPool>,
    pub provider: ProviderId,
}

#[derive(Debug)]
pub struct SnapshotQuery {
    pub limit: NonZeroU64,
    pub provider: ProviderId,
    pub since_unix: i64,
}

pub trait Storage {
    fn replace_oauth_pair(
        &self,
        replacement: OauthPairReplacement,
    ) -> impl Future<Output = Result<OauthPairRecord, StorageError>> + Send;

    fn oauth_pair(
        &self,
        client: &ClientId,
        credential: &CredentialId,
        provider: &ProviderId,
    ) -> impl Future<Output = Result<OauthPairRecord, StorageError>> + Send;

    fn retire_oauth_pair(
        &self,
        retirement: OauthPairRetirement,
    ) -> impl Future<Output = Result<(), StorageError>> + Send;

    fn try_append_request_event(
        &self,
        event: RequestEvent,
    ) -> impl Future<Output = Result<(), StorageError>> + Send;

    fn request_usage(
        &self,
        query: RequestUsageQuery,
    ) -> impl Future<Output = Result<Vec<RequestUsageAggregate>, StorageError>> + Send;

    fn request_usage_loss_total(&self) -> impl Future<Output = Result<u64, StorageError>> + Send;

    fn append_provider_snapshot(
        &self,
        snapshot: ProviderSnapshot,
    ) -> impl Future<Output = Result<(), StorageError>> + Send;

    fn provider_snapshots(
        &self,
        query: SnapshotQuery,
    ) -> impl Future<Output = Result<Vec<ProviderSnapshot>, StorageError>> + Send;
}

type UsageWork = (
    RequestEvent,
    tokio::sync::oneshot::Sender<Result<(), StorageError>>,
);

pub struct SqliteStorage {
    connection: std::sync::Arc<tokio::sync::Mutex<SqliteConnection>>,
    database_path: PathBuf,
    usage_sender: tokio::sync::mpsc::Sender<UsageWork>,
    usage_worker: tokio::task::JoinHandle<()>,
}

impl SqliteStorage {
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
        let Self {
            connection,
            database_path,
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

impl Storage for SqliteStorage {
    async fn replace_oauth_pair(
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

    async fn oauth_pair(
        &self,
        client: &ClientId,
        credential: &CredentialId,
        provider: &ProviderId,
    ) -> Result<OauthPairRecord, StorageError> {
        let client_id = client.as_ref();
        let credential_id = credential.as_ref();
        let provider_id = provider.as_ref();
        let record = sqlx::query!(
            r#"
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
            "#,
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

    async fn retire_oauth_pair(&self, retirement: OauthPairRetirement) -> Result<(), StorageError> {
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
            r#"
            SELECT mappings.generation, mappings.fake_refresh_token
            FROM oauth_mappings AS mappings
            JOIN credentials ON credentials.id = mappings.credential_id
            WHERE mappings.client_id = ? AND mappings.credential_id = ?
              AND credentials.provider_id = ?
            "#,
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

    async fn try_append_request_event(&self, event: RequestEvent) -> Result<(), StorageError> {
        validate_request_event(&event)?;
        let (acknowledgement, receipt) = tokio::sync::oneshot::channel();
        self.usage_sender
            .try_send((event, acknowledgement))
            .map_err(|_| StorageError::UsageUnavailable)?;
        receipt.await.map_err(|_| StorageError::UsageUnavailable)?
    }

    #[expect(
        clippy::too_many_lines,
        reason = "compile-checked aggregate SQL and its validated projection share this boundary"
    )]
    async fn request_usage(
        &self,
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
        .fetch_all(&mut *self.connection.lock().await)
        .await?;
        if rows.len() > MAX_AGGREGATE_ROWS {
            return Err(StorageError::UsageRangeIncomplete);
        }

        let mut aggregates = Vec::with_capacity(rows.len());
        for row in rows {
            let credential = CredentialId::try_from(row.credential_id).map_err(|error| {
                StorageError::StoredId {
                    kind: "credential",
                    value: error.into_name(),
                }
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
            let outcome = RequestOutcome::from_storage(&row.outcome).ok_or_else(|| {
                StorageError::Integrity {
                    path: self.database_path.clone(),
                }
            })?;
            aggregates.push(RequestUsageAggregate {
                bucket_start_unix: if row.bucket_start_unix >= 0 {
                    row.bucket_start_unix
                } else {
                    return Err(StorageError::Integrity {
                        path: self.database_path.clone(),
                    });
                },
                cache_read_tokens: complete_sum(
                    row.cache_read_tokens,
                    row.missing_cache_read_tokens,
                    &self.database_path,
                )?,
                cache_write_tokens: complete_sum(
                    row.cache_write_tokens,
                    row.missing_cache_write_tokens,
                    &self.database_path,
                )?,
                client,
                complete_events: stored_count(row.complete_events, &self.database_path)?,
                credential,
                error_events: stored_count(row.error_events, &self.database_path)?,
                events: stored_count(row.events, &self.database_path)?,
                input_tokens: complete_sum(
                    row.input_tokens,
                    row.missing_input_tokens,
                    &self.database_path,
                )?,
                latency_ms: stored_count(row.latency_ms, &self.database_path)?,
                model: row.model_id,
                outcome,
                output_tokens: complete_sum(
                    row.output_tokens,
                    row.missing_output_tokens,
                    &self.database_path,
                )?,
                provider,
                request_bytes: stored_count(row.request_bytes, &self.database_path)?,
                response_bytes: stored_count(row.response_bytes, &self.database_path)?,
                successful_events: stored_count(row.successful_events, &self.database_path)?,
            });
        }
        Ok(aggregates)
    }

    async fn request_usage_loss_total(&self) -> Result<u64, StorageError> {
        let row = sqlx::query!(
            r#"SELECT COALESCE(SUM(dropped_events), 0) AS "total!: i64" FROM request_events"#
        )
        .fetch_one(&mut *self.connection.lock().await)
        .await?;
        stored_count(row.total, &self.database_path)
    }

    async fn append_provider_snapshot(
        &self,
        snapshot: ProviderSnapshot,
    ) -> Result<(), StorageError> {
        validate_time(snapshot.fetched_at_unix, "snapshot time")?;
        validate_label(&snapshot.account_id, "account ID")?;
        validate_snapshot_collections(&snapshot)?;
        let provider_id = snapshot.provider.as_ref();
        let fetch_status = snapshot.fetch_status.as_storage();
        let mut connection = self.connection.lock().await;
        let mut transaction = connection.begin().await?;
        sqlx::query!(
            r"
            INSERT INTO provider_snapshots
              (fetched_at_unix, provider_id, account_id, fetch_status, gap_reason)
            VALUES (?, ?, ?, ?, ?)
            ",
            snapshot.fetched_at_unix,
            provider_id,
            snapshot.account_id,
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
        transaction.commit().await?;
        Ok(())
    }

    async fn provider_snapshots(
        &self,
        query: SnapshotQuery,
    ) -> Result<Vec<ProviderSnapshot>, StorageError> {
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
        let provider_id = query.provider.as_ref();
        let mut connection = self.connection.lock().await;
        let headers = sqlx::query!(
            r#"
            SELECT id AS "id!: i64", fetched_at_unix, provider_id, account_id, fetch_status, gap_reason
            FROM provider_snapshots
            WHERE provider_id = ? AND fetched_at_unix >= ?
            ORDER BY fetched_at_unix DESC, id DESC
            LIMIT ?
            "#,
            provider_id,
            query.since_unix,
            limit,
        )
        .fetch_all(&mut *connection)
        .await?;
        let mut snapshots = Vec::with_capacity(headers.len());
        for header in headers {
            let pools = quota_pools(&mut connection, header.id, &self.database_path).await?;
            let credits = credit_pools(&mut connection, header.id, &self.database_path).await?;
            let metrics = quota_metrics(&mut connection, header.id, &self.database_path).await?;
            let provider = ProviderId::try_from(header.provider_id).map_err(|error| {
                StorageError::StoredId {
                    kind: "provider",
                    value: error.into_name(),
                }
            })?;
            snapshots.push(ProviderSnapshot {
                account_id: header.account_id,
                credits,
                fetched_at_unix: header.fetched_at_unix,
                fetch_status: SnapshotFetchStatus::from_storage(&header.fetch_status).ok_or_else(
                    || StorageError::Integrity {
                        path: self.database_path.clone(),
                    },
                )?,
                gap_reason: header.gap_reason,
                metrics,
                pools,
                provider,
            });
        }
        drop(connection);
        snapshots.reverse();
        Ok(snapshots)
    }
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
            r#"
            UPDATE oauth_mappings
            SET generation = ?, fake_access_token = ?, fake_refresh_token = ?,
                fake_access_expires_at_unix = ?, updated_at_unix = ?
            WHERE client_id = ? AND credential_id = ? AND generation = ?
            "#,
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

async fn quota_pools(
    connection: &mut SqliteConnection,
    snapshot_id: i64,
    path: &Path,
) -> Result<Vec<QuotaPool>, StorageError> {
    let rows = sqlx::query!(
        r#"
        SELECT label, utilized, limit_value, reset_at_unix FROM quota_pools
        WHERE snapshot_id = ?
        ORDER BY ordinal
        "#,
        snapshot_id,
    )
    .fetch_all(connection)
    .await?;
    rows.into_iter()
        .map(|row| {
            Ok(QuotaPool {
                label: row.label,
                limit: stored_count(row.limit_value, path)?,
                reset_at_unix: row.reset_at_unix,
                utilized: stored_count(row.utilized, path)?,
            })
        })
        .collect()
}

async fn credit_pools(
    connection: &mut SqliteConnection,
    snapshot_id: i64,
    path: &Path,
) -> Result<Vec<CreditPool>, StorageError> {
    let rows = sqlx::query!(
        r#"
        SELECT label, used_minor_units, remaining_minor_units, limit_minor_units, reset_at_unix
        FROM credit_pools
        WHERE snapshot_id = ?
        ORDER BY ordinal
        "#,
        snapshot_id,
    )
    .fetch_all(connection)
    .await?;
    rows.into_iter()
        .map(|row| {
            Ok(CreditPool {
                label: row.label,
                limit_minor_units: stored_count(row.limit_minor_units, path)?,
                remaining_minor_units: stored_count(row.remaining_minor_units, path)?,
                reset_at_unix: row.reset_at_unix,
                used_minor_units: stored_count(row.used_minor_units, path)?,
            })
        })
        .collect()
}

async fn quota_metrics(
    connection: &mut SqliteConnection,
    snapshot_id: i64,
    path: &Path,
) -> Result<Vec<QuotaMetric>, StorageError> {
    let rows = sqlx::query!(
        r#"
        SELECT label, value, unit FROM quota_metrics
        WHERE snapshot_id = ?
        ORDER BY ordinal
        "#,
        snapshot_id,
    )
    .fetch_all(connection)
    .await?;
    rows.into_iter()
        .map(|row| {
            Ok(QuotaMetric {
                label: row.label,
                unit: row.unit,
                value: stored_count(row.value, path)?,
            })
        })
        .collect()
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
    .execute(&mut *connection)
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

fn validate_snapshot_collections(snapshot: &ProviderSnapshot) -> Result<(), StorageError> {
    if snapshot.pools.len() > 64
        || snapshot.credits.len() > 64
        || snapshot.metrics.len() > 64
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
        }
        SnapshotFetchStatus::Success => {
            if snapshot.gap_reason.is_some() {
                return Err(StorageError::Input {
                    field: "successful snapshots cannot carry a gap reason",
                });
            }
        }
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
}

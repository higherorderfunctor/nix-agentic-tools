CREATE TABLE providers (
  id TEXT PRIMARY KEY,
  inserted_at_unix INTEGER NOT NULL CHECK (inserted_at_unix > 0)
) STRICT, WITHOUT ROWID;

CREATE TABLE credentials (
  id TEXT PRIMARY KEY,
  provider_id TEXT NOT NULL REFERENCES providers (id),
  inserted_at_unix INTEGER NOT NULL CHECK (inserted_at_unix > 0)
) STRICT, WITHOUT ROWID;

CREATE TABLE groups (
  id TEXT PRIMARY KEY,
  inserted_at_unix INTEGER NOT NULL CHECK (inserted_at_unix > 0)
) STRICT, WITHOUT ROWID;

CREATE TABLE group_members (
  group_id TEXT NOT NULL REFERENCES groups (id),
  credential_id TEXT NOT NULL REFERENCES credentials (id),
  PRIMARY KEY (group_id, credential_id)
) STRICT, WITHOUT ROWID;

CREATE TABLE oauth_tokens (
  credential_id TEXT PRIMARY KEY REFERENCES credentials (id),
  access_token TEXT NOT NULL,
  refresh_token TEXT NOT NULL,
  access_expires_at_unix INTEGER NOT NULL CHECK (access_expires_at_unix > 0),
  updated_at_unix INTEGER NOT NULL CHECK (updated_at_unix > 0)
) STRICT, WITHOUT ROWID;

CREATE TABLE oauth_mappings (
  credential_id TEXT PRIMARY KEY REFERENCES credentials (id),
  generation INTEGER NOT NULL CHECK (generation > 0),
  fake_access_token TEXT NOT NULL UNIQUE,
  fake_refresh_token TEXT NOT NULL UNIQUE,
  fake_access_expires_at_unix INTEGER NOT NULL CHECK (fake_access_expires_at_unix > 0),
  updated_at_unix INTEGER NOT NULL CHECK (updated_at_unix > 0)
) STRICT, WITHOUT ROWID;

CREATE TABLE request_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  occurred_at_unix INTEGER NOT NULL CHECK (occurred_at_unix > 0),
  group_id TEXT NOT NULL REFERENCES groups (id),
  credential_id TEXT NOT NULL REFERENCES credentials (id),
  model_id TEXT NOT NULL CHECK (length(model_id) > 0 AND length(model_id) <= 128),
  outcome TEXT NOT NULL CHECK (outcome IN ('completed', 'failed', 'rejected')),
  status_code INTEGER NOT NULL CHECK (status_code BETWEEN 100 AND 599),
  request_bytes INTEGER NOT NULL CHECK (request_bytes >= 0),
  response_bytes INTEGER NOT NULL CHECK (response_bytes >= 0),
  latency_ms INTEGER NOT NULL CHECK (latency_ms >= 0),
  input_tokens INTEGER CHECK (input_tokens IS NULL OR input_tokens >= 0),
  output_tokens INTEGER CHECK (output_tokens IS NULL OR output_tokens >= 0),
  cache_read_tokens INTEGER CHECK (cache_read_tokens IS NULL OR cache_read_tokens >= 0),
  cache_write_tokens INTEGER CHECK (cache_write_tokens IS NULL OR cache_write_tokens >= 0),
  FOREIGN KEY (group_id, credential_id) REFERENCES group_members (group_id, credential_id)
) STRICT;

CREATE INDEX request_events_time_idx ON request_events (occurred_at_unix, id);

CREATE TABLE provider_snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fetched_at_unix INTEGER NOT NULL CHECK (fetched_at_unix > 0),
  provider_id TEXT NOT NULL REFERENCES providers (id),
  account_id TEXT NOT NULL CHECK (length(account_id) > 0 AND length(account_id) <= 128),
  fetch_status TEXT NOT NULL CHECK (fetch_status IN ('success', 'gap')),
  gap_reason TEXT CHECK (gap_reason IS NULL OR (length(gap_reason) > 0 AND length(gap_reason) <= 256))
) STRICT;

CREATE INDEX provider_snapshots_time_idx
  ON provider_snapshots (fetched_at_unix, id);

CREATE TABLE quota_pools (
  snapshot_id INTEGER NOT NULL REFERENCES provider_snapshots (id),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  label TEXT NOT NULL CHECK (length(label) > 0 AND length(label) <= 128),
  utilized INTEGER NOT NULL CHECK (utilized >= 0),
  limit_value INTEGER NOT NULL CHECK (limit_value > 0),
  reset_at_unix INTEGER CHECK (reset_at_unix IS NULL OR reset_at_unix > 0),
  PRIMARY KEY (snapshot_id, ordinal),
  UNIQUE (snapshot_id, label)
) STRICT, WITHOUT ROWID;

CREATE TABLE credit_pools (
  snapshot_id INTEGER NOT NULL REFERENCES provider_snapshots (id),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  label TEXT NOT NULL CHECK (length(label) > 0 AND length(label) <= 128),
  used_minor_units INTEGER NOT NULL CHECK (used_minor_units >= 0),
  remaining_minor_units INTEGER NOT NULL CHECK (remaining_minor_units >= 0),
  limit_minor_units INTEGER NOT NULL CHECK (limit_minor_units > 0),
  reset_at_unix INTEGER CHECK (reset_at_unix IS NULL OR reset_at_unix > 0),
  PRIMARY KEY (snapshot_id, ordinal),
  UNIQUE (snapshot_id, label)
) STRICT, WITHOUT ROWID;

CREATE TABLE quota_metrics (
  snapshot_id INTEGER NOT NULL REFERENCES provider_snapshots (id),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  label TEXT NOT NULL CHECK (length(label) > 0 AND length(label) <= 128),
  value INTEGER NOT NULL CHECK (value >= 0),
  unit TEXT NOT NULL CHECK (length(unit) > 0 AND length(unit) <= 16),
  PRIMARY KEY (snapshot_id, ordinal),
  UNIQUE (snapshot_id, label)
) STRICT, WITHOUT ROWID;

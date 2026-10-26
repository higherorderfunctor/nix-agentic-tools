-- SQLx runs this schema change and backfill in one startup transaction.
CREATE TABLE request_chart_daily (
  day_unix INTEGER NOT NULL CHECK (day_unix >= 0 AND day_unix % 86400 = 0),
  provider_id TEXT NOT NULL REFERENCES providers (id),
  client_key TEXT NOT NULL,
  model_id TEXT NOT NULL CHECK (length(model_id) > 0 AND length(model_id) <= 128),
  events INTEGER NOT NULL CHECK (events > 0),
  complete_events INTEGER NOT NULL CHECK (complete_events BETWEEN 0 AND events),
  error_events INTEGER NOT NULL CHECK (error_events BETWEEN 0 AND events),
  input_tokens INTEGER NOT NULL CHECK (input_tokens >= 0),
  input_tokens_unknown INTEGER NOT NULL CHECK (input_tokens_unknown BETWEEN 0 AND events),
  output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
  output_tokens_unknown INTEGER NOT NULL CHECK (output_tokens_unknown BETWEEN 0 AND events),
  cache_read_tokens INTEGER NOT NULL CHECK (cache_read_tokens >= 0),
  cache_read_tokens_unknown INTEGER NOT NULL CHECK (cache_read_tokens_unknown BETWEEN 0 AND events),
  cache_write_tokens INTEGER NOT NULL CHECK (cache_write_tokens >= 0),
  cache_write_tokens_unknown INTEGER NOT NULL CHECK (cache_write_tokens_unknown BETWEEN 0 AND events),
  PRIMARY KEY (day_unix, provider_id, client_key, model_id)
) STRICT, WITHOUT ROWID;

INSERT INTO request_chart_daily
SELECT
  (r.occurred_at_unix / 86400) * 86400,
  c.provider_id,
  COALESCE(r.client_id, ''),
  r.model_id,
  COUNT(*),
  SUM(r.usage_complete),
  SUM(r.status_code >= 400),
  COALESCE(SUM(r.input_tokens), 0),
  SUM(r.input_tokens IS NULL),
  COALESCE(SUM(r.output_tokens), 0),
  SUM(r.output_tokens IS NULL),
  COALESCE(SUM(r.cache_read_tokens), 0),
  SUM(r.cache_read_tokens IS NULL),
  COALESCE(SUM(r.cache_write_tokens), 0),
  SUM(r.cache_write_tokens IS NULL)
FROM request_events r
JOIN credentials c ON c.id = r.credential_id
GROUP BY 1, 2, 3, 4;

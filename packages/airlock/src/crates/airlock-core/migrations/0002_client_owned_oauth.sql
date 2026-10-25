-- M06 narrows every fake OAuth mapping to the authenticated client that
-- created it. M05 state is pre-release and has no defensible owner, so it is
-- retired instead of guessing.
DROP TABLE oauth_mappings;
DROP TABLE oauth_tokens;

CREATE TABLE clients (
  id TEXT PRIMARY KEY,
  inserted_at_unix INTEGER NOT NULL CHECK (inserted_at_unix > 0)
) STRICT, WITHOUT ROWID;

CREATE TABLE oauth_tokens (
  credential_id TEXT PRIMARY KEY REFERENCES credentials (id),
  access_token TEXT NOT NULL,
  refresh_token TEXT NOT NULL,
  refresh_token_expires_at_unix INTEGER
    CHECK (refresh_token_expires_at_unix IS NULL OR refresh_token_expires_at_unix > 0),
  access_expires_at_unix INTEGER NOT NULL CHECK (access_expires_at_unix > 0),
  updated_at_unix INTEGER NOT NULL CHECK (updated_at_unix > 0)
) STRICT, WITHOUT ROWID;

CREATE TABLE oauth_mappings (
  client_id TEXT NOT NULL REFERENCES clients (id),
  credential_id TEXT NOT NULL REFERENCES credentials (id),
  generation INTEGER NOT NULL CHECK (generation > 0),
  fake_access_token TEXT NOT NULL UNIQUE,
  fake_refresh_token TEXT NOT NULL UNIQUE,
  fake_access_expires_at_unix INTEGER NOT NULL CHECK (fake_access_expires_at_unix > 0),
  updated_at_unix INTEGER NOT NULL CHECK (updated_at_unix > 0),
  PRIMARY KEY (client_id, credential_id)
) STRICT, WITHOUT ROWID;

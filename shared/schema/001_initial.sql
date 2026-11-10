-- Burnline schema v1
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- This file is the authoritative schema. It is plain SQLite DDL with no
-- library-specific syntax, so any SQLite binding on any platform can apply it.
-- Do not transcribe it into application code -- read it, ship it, and test
-- migrations against it.
--
-- Connection pragmas (journal_mode, foreign_keys, busy_timeout) are set by the
-- application when it opens the database, not here: they are per-connection
-- settings rather than schema, and WAL mode in particular persists in the file
-- header once set.
--
-- Conventions
--   * timestamps  INTEGER, epoch seconds, UTC. Never a local time, never a string.
--   * money       INTEGER nanodollars (USD x 10^9). Never REAL.
--   * booleans    INTEGER 0/1.
--   * NULL means "unknown", never "zero". This matters most for cost_nanos.

-- ---------------------------------------------------------------------------
-- Providers and models
-- ---------------------------------------------------------------------------

CREATE TABLE providers (
  id           INTEGER PRIMARY KEY,
  key          TEXT    NOT NULL UNIQUE,          -- codex | claude_code | cursor
  display_name TEXT    NOT NULL,
  enabled      INTEGER NOT NULL DEFAULT 1,
  created_at   INTEGER NOT NULL
);

CREATE TABLE models (
  id             INTEGER PRIMARY KEY,
  provider_id    INTEGER NOT NULL REFERENCES providers(id),
  canonical_name TEXT    NOT NULL,
  display_name   TEXT    NOT NULL,
  family         TEXT,
  -- 'non_model' carries values that occupy the model field without being a
  -- model: <synthetic>, codex-auto-review. Kept visible in breakdowns, never
  -- priced, excluded from model-share arithmetic.
  kind           TEXT    NOT NULL DEFAULT 'model'
                 CHECK (kind IN ('model', 'non_model')),
  created_at     INTEGER NOT NULL,
  UNIQUE (provider_id, canonical_name)
);

-- Time-bounded, because providers rename models and historical events must keep
-- resolving to the mapping that was correct when they happened.
CREATE TABLE model_aliases (
  id             INTEGER PRIMARY KEY,
  provider_id    INTEGER NOT NULL REFERENCES providers(id),
  raw_model_name TEXT    NOT NULL,
  model_id       INTEGER NOT NULL REFERENCES models(id),
  valid_from     INTEGER,
  valid_until    INTEGER,
  source         TEXT    NOT NULL DEFAULT 'bundled'
                 CHECK (source IN ('bundled', 'user')),
  UNIQUE (provider_id, raw_model_name, valid_from)
);

-- ---------------------------------------------------------------------------
-- Projects and sessions
-- ---------------------------------------------------------------------------

-- identity_kind records HOW the project was identified, because the fallbacks
-- have different stability guarantees: a git remote survives the directory
-- moving, a path hash does not.
CREATE TABLE projects (
  id              INTEGER PRIMARY KEY,
  identity_kind   TEXT    NOT NULL
                  CHECK (identity_kind IN ('git_remote', 'git_root', 'path')),
  identity_key    TEXT    NOT NULL,   -- normalised remote URL, or SHA-256 of a path
  display_name    TEXT    NOT NULL,
  user_alias      TEXT,
  last_known_path TEXT,
  -- Set when the user merges two projects that turned out to be one. Rows are
  -- never rewritten; reads follow the redirect.
  merged_into_id  INTEGER REFERENCES projects(id),
  first_seen_at   INTEGER NOT NULL,
  last_seen_at    INTEGER NOT NULL,
  UNIQUE (identity_kind, identity_key)
);

CREATE TABLE sessions (
  id                INTEGER PRIMARY KEY,
  provider_id       INTEGER NOT NULL REFERENCES providers(id),
  source_session_id TEXT    NOT NULL,
  project_id        INTEGER REFERENCES projects(id),
  started_at        INTEGER NOT NULL,
  ended_at          INTEGER,
  UNIQUE (provider_id, source_session_id)
);

-- ---------------------------------------------------------------------------
-- Pricing
-- ---------------------------------------------------------------------------

-- Append-only. A price change creates a new row; it never updates an old one.
-- Rates are nanodollars per million tokens.
CREATE TABLE pricing_versions (
  id                          INTEGER PRIMARY KEY,
  model_id                    INTEGER NOT NULL REFERENCES models(id),
  valid_from                  INTEGER NOT NULL,   -- inclusive
  valid_until                 INTEGER,            -- exclusive, NULL = current
  input_nanos_per_mtok        INTEGER,
  cached_input_nanos_per_mtok INTEGER,
  cache_write_nanos_per_mtok  INTEGER,
  output_nanos_per_mtok       INTEGER,
  reasoning_nanos_per_mtok    INTEGER,
  currency                    TEXT    NOT NULL DEFAULT 'USD',
  source                      TEXT    NOT NULL,
  confidence                  TEXT    NOT NULL
                              CHECK (confidence IN ('exact','reconstructed','estimated','unknown')),
  created_at                  INTEGER NOT NULL
);

CREATE INDEX idx_pricing_model_from ON pricing_versions (model_id, valid_from);

-- ---------------------------------------------------------------------------
-- Usage
-- ---------------------------------------------------------------------------

CREATE TABLE usage_events (
  id                    INTEGER PRIMARY KEY,
  provider_id           INTEGER NOT NULL REFERENCES providers(id),
  model_id              INTEGER REFERENCES models(id),
  session_id            INTEGER REFERENCES sessions(id),
  project_id            INTEGER REFERENCES projects(id),

  timestamp             INTEGER NOT NULL,

  input_tokens          INTEGER NOT NULL DEFAULT 0 CHECK (input_tokens        >= 0),
  cached_input_tokens   INTEGER NOT NULL DEFAULT 0 CHECK (cached_input_tokens >= 0),
  cache_write_tokens    INTEGER NOT NULL DEFAULT 0 CHECK (cache_write_tokens  >= 0),
  output_tokens         INTEGER NOT NULL DEFAULT 0 CHECK (output_tokens       >= 0),
  reasoning_tokens      INTEGER NOT NULL DEFAULT 0 CHECK (reasoning_tokens    >= 0),

  -- Both the version and the computed cost are stored: the version makes a
  -- recomputation auditable, the cached figure keeps chart queries off a join.
  pricing_version_id    INTEGER REFERENCES pricing_versions(id),
  -- NULL means unpriced. Never write 0 for unknown -- that understates totals
  -- and makes the pricing-coverage indicator lie.
  cost_nanos            INTEGER,
  pricing_confidence    TEXT CHECK (pricing_confidence IN
                          ('exact','reconstructed','estimated','unknown')),

  source_type           TEXT    NOT NULL,
  source_file           TEXT,
  source_event_id       TEXT    NOT NULL,
  source_schema_version TEXT,
  source_offset         INTEGER,

  created_at            INTEGER NOT NULL,

  -- The deduplication guarantee. Re-reading a rotated file is therefore safe.
  UNIQUE (provider_id, source_event_id)
);

CREATE INDEX idx_usage_ts         ON usage_events (timestamp);
CREATE INDEX idx_usage_prov_ts    ON usage_events (provider_id, timestamp);
CREATE INDEX idx_usage_model_ts   ON usage_events (model_id, timestamp);
CREATE INDEX idx_usage_project_ts ON usage_events (project_id, timestamp);
CREATE INDEX idx_usage_session    ON usage_events (session_id);

-- ---------------------------------------------------------------------------
-- Quota
-- ---------------------------------------------------------------------------

CREATE TABLE quota_snapshots (
  id                INTEGER PRIMARY KEY,
  provider_id       INTEGER NOT NULL REFERENCES providers(id),
  quota_key         TEXT    NOT NULL,
  quota_name        TEXT    NOT NULL,
  scope             TEXT    NOT NULL,
  timestamp         INTEGER NOT NULL,
  used              REAL,
  remaining         REAL,
  limit_value       REAL,
  unit              TEXT,
  percentage_used   REAL,
  window_started_at INTEGER,
  reset_at          INTEGER,
  status            TEXT    NOT NULL
                    CHECK (status IN ('healthy','warning','critical','exhausted',
                                      'reset_pending','unavailable','stale','unknown')),
  source            TEXT    NOT NULL,
  created_at        INTEGER NOT NULL
);

CREATE INDEX idx_quota_key_ts ON quota_snapshots (provider_id, quota_key, timestamp);

-- A banked reset is a consumable that zeroes a usage window early. It is NOT
-- extra allowance, so it is never folded into a used percentage. Its expiry is
-- a different event from a window reset: a reset replenishes, an expiry removes
-- capacity that was never used.
CREATE TABLE banked_resets (
  id                   INTEGER PRIMARY KEY,
  provider_id          INTEGER NOT NULL REFERENCES providers(id),
  source_reset_id      TEXT    NOT NULL,
  applies_to_quota_key TEXT,
  granted_at           INTEGER,
  expires_at           INTEGER,
  consumed_at          INTEGER,
  -- 'unknown' is required: Burnline observes rather than controls this, so a
  -- reset that vanishes without an observable transition must not be guessed at.
  status               TEXT    NOT NULL
                       CHECK (status IN ('held','consumed','expired','unknown')),
  source               TEXT    NOT NULL,
  observed_at          INTEGER NOT NULL,
  UNIQUE (provider_id, source_reset_id)
);

-- ---------------------------------------------------------------------------
-- Ingestion and notification state
-- ---------------------------------------------------------------------------

CREATE TABLE source_states (
  id                    INTEGER PRIMARY KEY,
  provider_id           INTEGER NOT NULL REFERENCES providers(id),
  source_identifier     TEXT    NOT NULL,
  inode                 INTEGER,
  file_size             INTEGER,
  last_modified_at      INTEGER,
  last_offset           INTEGER NOT NULL DEFAULT 0,
  last_event_identifier TEXT,
  last_scan_at          INTEGER,
  UNIQUE (provider_id, source_identifier)
);

-- cycle_token, not reset_at. A banked reset moves the reset timestamp, so
-- keying deduplication on it would silently suppress the re-armed alert.
-- cycle_token identifies the window itself (window start + quota identity).
CREATE TABLE notification_events (
  id                INTEGER PRIMARY KEY,
  provider_id       INTEGER NOT NULL REFERENCES providers(id),
  quota_key         TEXT,
  notification_type TEXT    NOT NULL,
  threshold         REAL,
  fired_at          INTEGER NOT NULL,
  cycle_token       TEXT
);

CREATE INDEX idx_notif_dedup
  ON notification_events (provider_id, quota_key, notification_type, cycle_token);

-- ---------------------------------------------------------------------------
-- Derived surfaces
-- ---------------------------------------------------------------------------

-- awarded_at is stored so that recomputation after a backfill does not reshuffle
-- the user's history.
CREATE TABLE achievements (
  id          INTEGER PRIMARY KEY,
  key         TEXT    NOT NULL,
  tier        TEXT,
  provider_id INTEGER REFERENCES providers(id),
  value       INTEGER,
  awarded_at  INTEGER NOT NULL,
  created_at  INTEGER NOT NULL,
  UNIQUE (key, tier)
);

-- Reason strings only. Never store the offending line: it may contain prompt
-- text or source code, which Burnline must not retain.
CREATE TABLE parser_errors (
  id          INTEGER PRIMARY KEY,
  provider_id INTEGER NOT NULL REFERENCES providers(id),
  source_file TEXT,
  line_number INTEGER,
  reason      TEXT    NOT NULL,
  occurred_at INTEGER NOT NULL
);

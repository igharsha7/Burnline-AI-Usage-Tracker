-- Burnline schema v7: source files stored once, and only the indexes queries use
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- Every event carried its full source file path and source type, about 135
-- bytes and half the row, repeated for every event of a file. They move to
-- source_files, one row per file, which events reference by id.
--
-- The table is rebuilt rather than altered, which also drops two indexes no
-- query needs: (provider_id, timestamp) duplicated (timestamp), whose range
-- scan a provider filter barely lengthens, and (model_id, timestamp) served
-- only re-pricing, which is rare and walks events in id order anyway.
--
-- Rebuilding leaves the old pages free inside the file. The application
-- compacts the file once after this migration (see README).

CREATE TABLE source_files (
  id          INTEGER PRIMARY KEY,
  provider_id INTEGER NOT NULL REFERENCES providers(id),
  source_type TEXT    NOT NULL,   -- the record format, e.g. claude_code_jsonl
  path        TEXT,               -- NULL for a source that is not a file
  UNIQUE (provider_id, source_type, path)
);

INSERT INTO source_files (provider_id, source_type, path)
SELECT DISTINCT provider_id, source_type, source_file FROM usage_events;

CREATE TABLE usage_events_v7 (
  id                    INTEGER PRIMARY KEY,
  provider_id           INTEGER NOT NULL REFERENCES providers(id),
  model_id              INTEGER REFERENCES models(id),
  session_id            INTEGER REFERENCES sessions(id),
  project_id            INTEGER REFERENCES projects(id),

  timestamp             INTEGER NOT NULL,

  input_tokens          INTEGER NOT NULL DEFAULT 0 CHECK (input_tokens        >= 0),
  cached_input_tokens   INTEGER NOT NULL DEFAULT 0 CHECK (cached_input_tokens >= 0),
  cache_write_tokens    INTEGER NOT NULL DEFAULT 0 CHECK (cache_write_tokens  >= 0),
  cache_write_1h_tokens INTEGER NOT NULL DEFAULT 0
                        CHECK (cache_write_1h_tokens >= 0 AND cache_write_1h_tokens <= cache_write_tokens),
  output_tokens         INTEGER NOT NULL DEFAULT 0 CHECK (output_tokens       >= 0),
  reasoning_tokens      INTEGER NOT NULL DEFAULT 0 CHECK (reasoning_tokens    >= 0),
  service_tier          TEXT,

  pricing_version_id    INTEGER REFERENCES pricing_versions(id),
  cost_nanos            INTEGER,
  pricing_confidence    TEXT CHECK (pricing_confidence IN
                          ('exact','reconstructed','estimated','unknown')),

  source_file_id        INTEGER NOT NULL REFERENCES source_files(id),
  source_event_id       TEXT    NOT NULL,
  source_schema_version TEXT,
  source_offset         INTEGER,

  created_at            INTEGER NOT NULL,

  -- The event id leads, so the planner never mistakes this index for a way
  -- to find one provider's events: walking it to filter by provider reads the
  -- table in random order. Provider filters use the timestamp index instead.
  UNIQUE (source_event_id, provider_id)
);

INSERT INTO usage_events_v7 (
  id, provider_id, model_id, session_id, project_id, timestamp,
  input_tokens, cached_input_tokens, cache_write_tokens, cache_write_1h_tokens,
  output_tokens, reasoning_tokens, service_tier,
  pricing_version_id, cost_nanos, pricing_confidence,
  source_file_id, source_event_id, source_schema_version, source_offset, created_at)
SELECT
  e.id, e.provider_id, e.model_id, e.session_id, e.project_id, e.timestamp,
  e.input_tokens, e.cached_input_tokens, e.cache_write_tokens, e.cache_write_1h_tokens,
  e.output_tokens, e.reasoning_tokens, e.service_tier,
  e.pricing_version_id, e.cost_nanos, e.pricing_confidence,
  f.id, e.source_event_id, e.source_schema_version, e.source_offset, e.created_at
FROM usage_events e
JOIN source_files f
  ON f.provider_id = e.provider_id AND f.source_type = e.source_type AND f.path IS e.source_file;

DROP TABLE usage_events;
ALTER TABLE usage_events_v7 RENAME TO usage_events;

-- Every range query, all providers or one: the dashboard's charts and totals.
CREATE INDEX idx_usage_ts         ON usage_events (timestamp);
-- A project's history and its breakdowns.
CREATE INDEX idx_usage_project_ts ON usage_events (project_id, timestamp);
-- A session's events, in the session detail view.
CREATE INDEX idx_usage_session    ON usage_events (session_id);

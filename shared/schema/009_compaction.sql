-- Burnline schema v9: compacting old history into rollups
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- A heavy user writes tens of thousands of events a day, gigabytes a year.
-- Lifetime figures need only the rollups: tokens of every type, cost, and
-- unpriced counts per 15 minutes, provider, model and project. So events
-- older than the user's detail window are deleted and their rollups kept,
-- which bounds the file at roughly the window's worth of events.
--
-- compaction.compacted_before is the boundary: a multiple of 900, so no
-- bucket is ever part compacted, and it only moves forward. Rollups before it
-- have no events behind them, so the triggers leave them alone when events
-- are deleted, and an implementation must never insert an event before it
-- (a re-read provider file would otherwise count compacted history twice).
--
-- Rebuilding rollups (see 008) now covers only buckets from the boundary on:
-- compacted buckets have no events left to rebuild them from.
--
-- Cache savings need each event's pricing version, which compacted history
-- no longer has, so they are kept per event (cache_savings_nanos, NULL when
-- the event's price has no cache rates of its own) and summed into rollups
-- with the cache tokens they cover. The application fills the column for
-- events stored before this version.

ALTER TABLE usage_events ADD COLUMN cache_savings_nanos INTEGER;

ALTER TABLE usage_rollups ADD COLUMN cache_savings_nanos INTEGER NOT NULL DEFAULT 0;
-- Cache read and write tokens on events whose savings are known.
ALTER TABLE usage_rollups ADD COLUMN cache_savings_tokens INTEGER NOT NULL DEFAULT 0;

CREATE TABLE compaction (
  id               INTEGER PRIMARY KEY CHECK (id = 1),
  compacted_before INTEGER NOT NULL CHECK (compacted_before % 900 = 0)
);
INSERT INTO compaction (id, compacted_before) VALUES (1, 0);

DROP TRIGGER usage_rollups_insert;
DROP TRIGGER usage_rollups_delete;
DROP TRIGGER usage_rollups_update;

CREATE TRIGGER usage_rollups_insert AFTER INSERT ON usage_events
BEGIN
  INSERT INTO usage_rollups (
    bucket, provider_id, model_id, project_id, events, input_tokens, cached_input_tokens,
    cache_write_tokens, cache_write_1h_tokens, output_tokens, reasoning_tokens, cost_nanos,
    unpriced_events, cache_savings_nanos, cache_savings_tokens)
  VALUES (
    NEW.timestamp / 900, NEW.provider_id, coalesce(NEW.model_id, 0), coalesce(NEW.project_id, 0),
    1, NEW.input_tokens, NEW.cached_input_tokens, NEW.cache_write_tokens, NEW.cache_write_1h_tokens,
    NEW.output_tokens, NEW.reasoning_tokens, coalesce(NEW.cost_nanos, 0), NEW.cost_nanos IS NULL,
    coalesce(NEW.cache_savings_nanos, 0),
    CASE WHEN NEW.cache_savings_nanos IS NULL THEN 0 ELSE NEW.cached_input_tokens + NEW.cache_write_tokens END)
  ON CONFLICT (bucket, provider_id, model_id, project_id) DO UPDATE SET
    events                = events + 1,
    input_tokens          = input_tokens + excluded.input_tokens,
    cached_input_tokens   = cached_input_tokens + excluded.cached_input_tokens,
    cache_write_tokens    = cache_write_tokens + excluded.cache_write_tokens,
    cache_write_1h_tokens = cache_write_1h_tokens + excluded.cache_write_1h_tokens,
    output_tokens         = output_tokens + excluded.output_tokens,
    reasoning_tokens      = reasoning_tokens + excluded.reasoning_tokens,
    cost_nanos            = cost_nanos + excluded.cost_nanos,
    unpriced_events       = unpriced_events + excluded.unpriced_events,
    cache_savings_nanos   = cache_savings_nanos + excluded.cache_savings_nanos,
    cache_savings_tokens  = cache_savings_tokens + excluded.cache_savings_tokens;
END;

-- Deleting an event subtracts it, unless its bucket is compacted: then the
-- rollup is all that remains of it and must stay.
CREATE TRIGGER usage_rollups_delete AFTER DELETE ON usage_events
WHEN OLD.timestamp >= (SELECT compacted_before FROM compaction)
BEGIN
  UPDATE usage_rollups SET
    events                = events - 1,
    input_tokens          = input_tokens - OLD.input_tokens,
    cached_input_tokens   = cached_input_tokens - OLD.cached_input_tokens,
    cache_write_tokens    = cache_write_tokens - OLD.cache_write_tokens,
    cache_write_1h_tokens = cache_write_1h_tokens - OLD.cache_write_1h_tokens,
    output_tokens         = output_tokens - OLD.output_tokens,
    reasoning_tokens      = reasoning_tokens - OLD.reasoning_tokens,
    cost_nanos            = cost_nanos - coalesce(OLD.cost_nanos, 0),
    unpriced_events       = unpriced_events - (OLD.cost_nanos IS NULL),
    cache_savings_nanos   = cache_savings_nanos - coalesce(OLD.cache_savings_nanos, 0),
    cache_savings_tokens  = cache_savings_tokens
      - CASE WHEN OLD.cache_savings_nanos IS NULL THEN 0 ELSE OLD.cached_input_tokens + OLD.cache_write_tokens END
  WHERE bucket = OLD.timestamp / 900 AND provider_id = OLD.provider_id
    AND model_id = coalesce(OLD.model_id, 0) AND project_id = coalesce(OLD.project_id, 0);
  DELETE FROM usage_rollups
  WHERE bucket = OLD.timestamp / 900 AND provider_id = OLD.provider_id
    AND model_id = coalesce(OLD.model_id, 0) AND project_id = coalesce(OLD.project_id, 0)
    AND events = 0;
END;

CREATE TRIGGER usage_rollups_update AFTER UPDATE OF
  timestamp, provider_id, model_id, project_id, input_tokens, cached_input_tokens, cache_write_tokens,
  cache_write_1h_tokens, output_tokens, reasoning_tokens, cost_nanos, cache_savings_nanos
ON usage_events
BEGIN
  UPDATE usage_rollups SET
    events                = events - 1,
    input_tokens          = input_tokens - OLD.input_tokens,
    cached_input_tokens   = cached_input_tokens - OLD.cached_input_tokens,
    cache_write_tokens    = cache_write_tokens - OLD.cache_write_tokens,
    cache_write_1h_tokens = cache_write_1h_tokens - OLD.cache_write_1h_tokens,
    output_tokens         = output_tokens - OLD.output_tokens,
    reasoning_tokens      = reasoning_tokens - OLD.reasoning_tokens,
    cost_nanos            = cost_nanos - coalesce(OLD.cost_nanos, 0),
    unpriced_events       = unpriced_events - (OLD.cost_nanos IS NULL),
    cache_savings_nanos   = cache_savings_nanos - coalesce(OLD.cache_savings_nanos, 0),
    cache_savings_tokens  = cache_savings_tokens
      - CASE WHEN OLD.cache_savings_nanos IS NULL THEN 0 ELSE OLD.cached_input_tokens + OLD.cache_write_tokens END
  WHERE bucket = OLD.timestamp / 900 AND provider_id = OLD.provider_id
    AND model_id = coalesce(OLD.model_id, 0) AND project_id = coalesce(OLD.project_id, 0);
  DELETE FROM usage_rollups
  WHERE bucket = OLD.timestamp / 900 AND provider_id = OLD.provider_id
    AND model_id = coalesce(OLD.model_id, 0) AND project_id = coalesce(OLD.project_id, 0)
    AND events = 0;
  INSERT INTO usage_rollups (
    bucket, provider_id, model_id, project_id, events, input_tokens, cached_input_tokens,
    cache_write_tokens, cache_write_1h_tokens, output_tokens, reasoning_tokens, cost_nanos,
    unpriced_events, cache_savings_nanos, cache_savings_tokens)
  VALUES (
    NEW.timestamp / 900, NEW.provider_id, coalesce(NEW.model_id, 0), coalesce(NEW.project_id, 0),
    1, NEW.input_tokens, NEW.cached_input_tokens, NEW.cache_write_tokens, NEW.cache_write_1h_tokens,
    NEW.output_tokens, NEW.reasoning_tokens, coalesce(NEW.cost_nanos, 0), NEW.cost_nanos IS NULL,
    coalesce(NEW.cache_savings_nanos, 0),
    CASE WHEN NEW.cache_savings_nanos IS NULL THEN 0 ELSE NEW.cached_input_tokens + NEW.cache_write_tokens END)
  ON CONFLICT (bucket, provider_id, model_id, project_id) DO UPDATE SET
    events                = events + 1,
    input_tokens          = input_tokens + excluded.input_tokens,
    cached_input_tokens   = cached_input_tokens + excluded.cached_input_tokens,
    cache_write_tokens    = cache_write_tokens + excluded.cache_write_tokens,
    cache_write_1h_tokens = cache_write_1h_tokens + excluded.cache_write_1h_tokens,
    output_tokens         = output_tokens + excluded.output_tokens,
    reasoning_tokens      = reasoning_tokens + excluded.reasoning_tokens,
    cost_nanos            = cost_nanos + excluded.cost_nanos,
    unpriced_events       = unpriced_events + excluded.unpriced_events,
    cache_savings_nanos   = cache_savings_nanos + excluded.cache_savings_nanos,
    cache_savings_tokens  = cache_savings_tokens + excluded.cache_savings_tokens;
END;

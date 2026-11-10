-- Burnline schema v8: usage totals per 15 minutes, kept by triggers
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- Summing events directly is fast for a week and too slow for a lifetime:
-- on ten million events, lifetime totals took 6.9 seconds and a year of daily
-- buckets 0.9. These rollups hold the same sums per 15-minute UTC bucket,
-- provider, model and project.
--
-- Fifteen minutes, because every time-zone offset in use is a multiple of
-- it (India is UTC+5:30, Nepal +5:45), so local days, weeks and months are
-- exact unions of buckets. Hourly buckets would split them.
--
-- Rollups are derived, never a source of truth. Triggers keep them exact in
-- the same transaction as every insert, update and delete of an event, and
-- they can be rebuilt from usage_events at any time by deleting every row
-- and repeating the INSERT … SELECT below.
--
-- A missing model or project is stored as 0, because NULL never matches in a
-- key. A merged project keeps its own id here, as in usage_events; readers
-- follow projects.merged_into_id.

CREATE TABLE usage_rollups (
  bucket                INTEGER NOT NULL,   -- timestamp / 900
  provider_id           INTEGER NOT NULL,
  model_id              INTEGER NOT NULL,   -- 0 when the event has no model
  project_id            INTEGER NOT NULL,   -- 0 when the event has no project
  events                INTEGER NOT NULL,
  input_tokens          INTEGER NOT NULL,
  cached_input_tokens   INTEGER NOT NULL,
  cache_write_tokens    INTEGER NOT NULL,
  cache_write_1h_tokens INTEGER NOT NULL,
  output_tokens         INTEGER NOT NULL,
  reasoning_tokens      INTEGER NOT NULL,
  cost_nanos            INTEGER NOT NULL,   -- priced events only
  unpriced_events       INTEGER NOT NULL,
  PRIMARY KEY (bucket, provider_id, model_id, project_id)
) WITHOUT ROWID;

INSERT INTO usage_rollups
SELECT timestamp / 900, provider_id, coalesce(model_id, 0), coalesce(project_id, 0),
       count(*), sum(input_tokens), sum(cached_input_tokens), sum(cache_write_tokens),
       sum(cache_write_1h_tokens), sum(output_tokens), sum(reasoning_tokens),
       coalesce(sum(cost_nanos), 0), sum(cost_nanos IS NULL)
FROM usage_events
GROUP BY 1, 2, 3, 4;

CREATE TRIGGER usage_rollups_insert AFTER INSERT ON usage_events
BEGIN
  INSERT INTO usage_rollups VALUES (
    NEW.timestamp / 900, NEW.provider_id, coalesce(NEW.model_id, 0), coalesce(NEW.project_id, 0),
    1, NEW.input_tokens, NEW.cached_input_tokens, NEW.cache_write_tokens, NEW.cache_write_1h_tokens,
    NEW.output_tokens, NEW.reasoning_tokens, coalesce(NEW.cost_nanos, 0), NEW.cost_nanos IS NULL)
  ON CONFLICT (bucket, provider_id, model_id, project_id) DO UPDATE SET
    events                = events + 1,
    input_tokens          = input_tokens + excluded.input_tokens,
    cached_input_tokens   = cached_input_tokens + excluded.cached_input_tokens,
    cache_write_tokens    = cache_write_tokens + excluded.cache_write_tokens,
    cache_write_1h_tokens = cache_write_1h_tokens + excluded.cache_write_1h_tokens,
    output_tokens         = output_tokens + excluded.output_tokens,
    reasoning_tokens      = reasoning_tokens + excluded.reasoning_tokens,
    cost_nanos            = cost_nanos + excluded.cost_nanos,
    unpriced_events       = unpriced_events + excluded.unpriced_events;
END;

CREATE TRIGGER usage_rollups_delete AFTER DELETE ON usage_events
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
    unpriced_events       = unpriced_events - (OLD.cost_nanos IS NULL)
  WHERE bucket = OLD.timestamp / 900 AND provider_id = OLD.provider_id
    AND model_id = coalesce(OLD.model_id, 0) AND project_id = coalesce(OLD.project_id, 0);
  DELETE FROM usage_rollups
  WHERE bucket = OLD.timestamp / 900 AND provider_id = OLD.provider_id
    AND model_id = coalesce(OLD.model_id, 0) AND project_id = coalesce(OLD.project_id, 0)
    AND events = 0;
END;

-- An update moves the event's old figures out of their bucket and its new
-- figures in, which covers a changed timestamp, model or project as well as
-- a more complete snapshot or a new price.
CREATE TRIGGER usage_rollups_update AFTER UPDATE OF
  timestamp, provider_id, model_id, project_id, input_tokens, cached_input_tokens, cache_write_tokens,
  cache_write_1h_tokens, output_tokens, reasoning_tokens, cost_nanos
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
    unpriced_events       = unpriced_events - (OLD.cost_nanos IS NULL)
  WHERE bucket = OLD.timestamp / 900 AND provider_id = OLD.provider_id
    AND model_id = coalesce(OLD.model_id, 0) AND project_id = coalesce(OLD.project_id, 0);
  DELETE FROM usage_rollups
  WHERE bucket = OLD.timestamp / 900 AND provider_id = OLD.provider_id
    AND model_id = coalesce(OLD.model_id, 0) AND project_id = coalesce(OLD.project_id, 0)
    AND events = 0;
  INSERT INTO usage_rollups VALUES (
    NEW.timestamp / 900, NEW.provider_id, coalesce(NEW.model_id, 0), coalesce(NEW.project_id, 0),
    1, NEW.input_tokens, NEW.cached_input_tokens, NEW.cache_write_tokens, NEW.cache_write_1h_tokens,
    NEW.output_tokens, NEW.reasoning_tokens, coalesce(NEW.cost_nanos, 0), NEW.cost_nanos IS NULL)
  ON CONFLICT (bucket, provider_id, model_id, project_id) DO UPDATE SET
    events                = events + 1,
    input_tokens          = input_tokens + excluded.input_tokens,
    cached_input_tokens   = cached_input_tokens + excluded.cached_input_tokens,
    cache_write_tokens    = cache_write_tokens + excluded.cache_write_tokens,
    cache_write_1h_tokens = cache_write_1h_tokens + excluded.cache_write_1h_tokens,
    output_tokens         = output_tokens + excluded.output_tokens,
    reasoning_tokens      = reasoning_tokens + excluded.reasoning_tokens,
    cost_nanos            = cost_nanos + excluded.cost_nanos,
    unpriced_events       = unpriced_events + excluded.unpriced_events;
END;

-- Burnline schema v10: usage totals per UTC day, kept from the 15-minute rollups
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- A year or a lifetime charted by week or month still read every 15-minute
-- rollup: on ten million events over five years, all time took over half a
-- second. These hold the same sums per UTC day, provider, model and project,
-- about a tenth as many rows.
--
-- A local day is not a UTC day (India's starts at 18:30 UTC), so a reader
-- takes the whole UTC days inside a range from here and the partial days at
-- either end from usage_rollups. Ranges stay exact to the quarter hour, and
-- a range shorter than a day reads only usage_rollups.
--
-- Derived from usage_rollups, never from events, so compacted history is
-- included. Triggers keep it exact in the same transaction as every change to
-- a rollup, which in turn changes with every event; nothing else writes it.

CREATE TABLE daily_rollups (
  day                   INTEGER NOT NULL,   -- bucket / 96, the UTC day
  provider_id           INTEGER NOT NULL,
  model_id              INTEGER NOT NULL,
  project_id            INTEGER NOT NULL,
  events                INTEGER NOT NULL,
  input_tokens          INTEGER NOT NULL,
  cached_input_tokens   INTEGER NOT NULL,
  cache_write_tokens    INTEGER NOT NULL,
  cache_write_1h_tokens INTEGER NOT NULL,
  output_tokens         INTEGER NOT NULL,
  reasoning_tokens      INTEGER NOT NULL,
  cost_nanos            INTEGER NOT NULL,
  unpriced_events       INTEGER NOT NULL,
  cache_savings_nanos   INTEGER NOT NULL,
  cache_savings_tokens  INTEGER NOT NULL,
  last_bucket           INTEGER NOT NULL,   -- the day's latest rollup bucket
  PRIMARY KEY (day, provider_id, model_id, project_id)
) WITHOUT ROWID;

INSERT INTO daily_rollups (
  day, provider_id, model_id, project_id, events, input_tokens, cached_input_tokens,
  cache_write_tokens, cache_write_1h_tokens, output_tokens, reasoning_tokens, cost_nanos,
  unpriced_events, cache_savings_nanos, cache_savings_tokens, last_bucket)
SELECT bucket / 96, provider_id, model_id, project_id, sum(events), sum(input_tokens),
       sum(cached_input_tokens), sum(cache_write_tokens), sum(cache_write_1h_tokens), sum(output_tokens),
       sum(reasoning_tokens), sum(cost_nanos), sum(unpriced_events), sum(cache_savings_nanos),
       sum(cache_savings_tokens), max(bucket)
FROM usage_rollups GROUP BY 1, 2, 3, 4;

CREATE TRIGGER daily_rollups_insert AFTER INSERT ON usage_rollups
BEGIN
  INSERT INTO daily_rollups (
    day, provider_id, model_id, project_id, events, input_tokens, cached_input_tokens,
  cache_write_tokens, cache_write_1h_tokens, output_tokens, reasoning_tokens, cost_nanos,
  unpriced_events, cache_savings_nanos, cache_savings_tokens, last_bucket)
  VALUES (
    NEW.bucket / 96, NEW.provider_id, NEW.model_id, NEW.project_id, NEW.events, NEW.input_tokens,
    NEW.cached_input_tokens, NEW.cache_write_tokens, NEW.cache_write_1h_tokens, NEW.output_tokens,
    NEW.reasoning_tokens, NEW.cost_nanos, NEW.unpriced_events, NEW.cache_savings_nanos,
    NEW.cache_savings_tokens, NEW.bucket)
  ON CONFLICT (day, provider_id, model_id, project_id) DO UPDATE SET
    events                = events + excluded.events,
    input_tokens          = input_tokens + excluded.input_tokens,
    cached_input_tokens   = cached_input_tokens + excluded.cached_input_tokens,
    cache_write_tokens    = cache_write_tokens + excluded.cache_write_tokens,
    cache_write_1h_tokens = cache_write_1h_tokens + excluded.cache_write_1h_tokens,
    output_tokens         = output_tokens + excluded.output_tokens,
    reasoning_tokens      = reasoning_tokens + excluded.reasoning_tokens,
    cost_nanos            = cost_nanos + excluded.cost_nanos,
    unpriced_events       = unpriced_events + excluded.unpriced_events,
    cache_savings_nanos   = cache_savings_nanos + excluded.cache_savings_nanos,
    cache_savings_tokens  = cache_savings_tokens + excluded.cache_savings_tokens,
    last_bucket           = max(last_bucket, excluded.last_bucket);
END;

-- A rollup's key never changes, only its sums.
CREATE TRIGGER daily_rollups_update AFTER UPDATE ON usage_rollups
BEGIN
  UPDATE daily_rollups SET
    events                = events - OLD.events + NEW.events,
    input_tokens          = input_tokens - OLD.input_tokens + NEW.input_tokens,
    cached_input_tokens   = cached_input_tokens - OLD.cached_input_tokens + NEW.cached_input_tokens,
    cache_write_tokens    = cache_write_tokens - OLD.cache_write_tokens + NEW.cache_write_tokens,
    cache_write_1h_tokens = cache_write_1h_tokens - OLD.cache_write_1h_tokens + NEW.cache_write_1h_tokens,
    output_tokens         = output_tokens - OLD.output_tokens + NEW.output_tokens,
    reasoning_tokens      = reasoning_tokens - OLD.reasoning_tokens + NEW.reasoning_tokens,
    cost_nanos            = cost_nanos - OLD.cost_nanos + NEW.cost_nanos,
    unpriced_events       = unpriced_events - OLD.unpriced_events + NEW.unpriced_events,
    cache_savings_nanos   = cache_savings_nanos - OLD.cache_savings_nanos + NEW.cache_savings_nanos,
    cache_savings_tokens  = cache_savings_tokens - OLD.cache_savings_tokens + NEW.cache_savings_tokens
  WHERE day = NEW.bucket / 96 AND provider_id = NEW.provider_id
    AND model_id = NEW.model_id AND project_id = NEW.project_id;
END;

CREATE TRIGGER daily_rollups_delete AFTER DELETE ON usage_rollups
BEGIN
  UPDATE daily_rollups SET
    events                = events - OLD.events,
    input_tokens          = input_tokens - OLD.input_tokens,
    cached_input_tokens   = cached_input_tokens - OLD.cached_input_tokens,
    cache_write_tokens    = cache_write_tokens - OLD.cache_write_tokens,
    cache_write_1h_tokens = cache_write_1h_tokens - OLD.cache_write_1h_tokens,
    output_tokens         = output_tokens - OLD.output_tokens,
    reasoning_tokens      = reasoning_tokens - OLD.reasoning_tokens,
    cost_nanos            = cost_nanos - OLD.cost_nanos,
    unpriced_events       = unpriced_events - OLD.unpriced_events,
    cache_savings_nanos   = cache_savings_nanos - OLD.cache_savings_nanos,
    cache_savings_tokens  = cache_savings_tokens - OLD.cache_savings_tokens,
    -- The latest bucket left that day; the row goes below if there is none.
    last_bucket           = coalesce((
      SELECT max(bucket) FROM usage_rollups
      WHERE bucket >= OLD.bucket / 96 * 96 AND bucket < OLD.bucket / 96 * 96 + 96
        AND provider_id = OLD.provider_id AND model_id = OLD.model_id AND project_id = OLD.project_id),
      last_bucket)
  WHERE day = OLD.bucket / 96 AND provider_id = OLD.provider_id
    AND model_id = OLD.model_id AND project_id = OLD.project_id;
  DELETE FROM daily_rollups
  WHERE day = OLD.bucket / 96 AND provider_id = OLD.provider_id
    AND model_id = OLD.model_id AND project_id = OLD.project_id AND events = 0;
END;

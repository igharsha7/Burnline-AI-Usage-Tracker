-- Burnline schema v2: cache-write duration
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- Providers price cache writes by how long the cache lives: Anthropic charges
-- about 1.25x the input rate for a 5-minute write and 2x for a 1-hour write.
-- A single cache_write_tokens column cannot price both, and the split cannot be
-- recovered once the provider's own transcripts are cleaned up, so the 1-hour
-- part is recorded as a fact alongside the total.
--
-- cache_write_1h_tokens is a SUBSET of cache_write_tokens, never added to it.
-- The 5-minute part is cache_write_tokens - cache_write_1h_tokens.

ALTER TABLE usage_events
  ADD COLUMN cache_write_1h_tokens INTEGER NOT NULL DEFAULT 0
  CHECK (cache_write_1h_tokens >= 0 AND cache_write_1h_tokens <= cache_write_tokens);

ALTER TABLE pricing_versions
  ADD COLUMN cache_write_1h_nanos_per_mtok INTEGER;

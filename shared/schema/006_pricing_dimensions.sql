-- Burnline schema v6: pricing by service tier and prompt length
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- One model's price is several rates. Providers charge priority processing
-- (OpenAI) and fast mode (Anthropic) a multiple of the standard rate, and
-- many current models charge more for every token of a request whose prompt
-- is long (OpenAI above 272,000 tokens, for example). So a pricing version is
-- one rate set for one tier and one prompt-length band, and a model's price
-- at an instant is the set of versions valid then.
--
-- service_tier: 'standard', 'priority', 'flex', 'ultrafast', or 'fast'.
-- above_prompt_tokens: the band applies to requests whose prompt (input plus
-- cache reads plus cache writes) exceeds this; 0 is the base band.
--
-- The unique index makes loading a pricing manifest idempotent: the same
-- version from the same source is one row however often it is loaded.

ALTER TABLE pricing_versions
  ADD COLUMN service_tier TEXT NOT NULL DEFAULT 'standard'
  CHECK (service_tier IN ('standard', 'priority', 'flex', 'ultrafast', 'fast'));

ALTER TABLE pricing_versions
  ADD COLUMN above_prompt_tokens INTEGER NOT NULL DEFAULT 0
  CHECK (above_prompt_tokens >= 0);

CREATE UNIQUE INDEX idx_pricing_identity
  ON pricing_versions (model_id, service_tier, above_prompt_tokens, valid_from, source);

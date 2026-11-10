-- Burnline schema v4: service tier
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- Providers bill a request by its service tier as well as its tokens: OpenAI's
-- priority ("fast") tier and Anthropic's priority tier cost more than the
-- standard one. The tier is a fact about the request, written in the provider's
-- transcript, and lost with it when the provider cleans up old files, so it is
-- recorded beside the token counts.
--
-- The provider's own value, as written ("default", "priority", "standard").
-- NULL when the transcript did not say, which pricing treats as standard.

ALTER TABLE usage_events
  ADD COLUMN service_tier TEXT;

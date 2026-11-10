-- Burnline schema v3: parser resume state
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- Resuming a file from last_offset is not always enough. A Codex rollout names
-- its model and working directory once per turn, and token records follow
-- later, so a pass that starts mid-file must be told what was already in
-- force. resume_state carries that, as text the provider's parser wrote and
-- alone reads.
--
-- The value is opaque to everything but that parser, and always optional: an
-- implementation that does not understand it, or finds it missing, re-reads
-- the file from the start. The uniqueness constraint on usage_events makes
-- that re-read harmless, only slower.

ALTER TABLE source_states
  ADD COLUMN resume_state TEXT;

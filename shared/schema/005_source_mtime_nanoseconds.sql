-- Burnline schema v5: subsecond source modification times
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- Whole seconds cannot distinguish same-size rewrites within one second.
-- NULL marks a legacy state, which is re-scanned to establish a precise stat.

ALTER TABLE source_states
  ADD COLUMN last_modified_nanoseconds INTEGER
  CHECK (last_modified_nanoseconds >= 0 AND last_modified_nanoseconds < 1000000000);

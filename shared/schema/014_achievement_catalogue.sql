-- Burnline schema v14: achievements the reworked catalogue no longer holds
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- Monthly challenges now follow a fixed schedule starting in September
-- 2026, so a month earned under the old adaptive challenge meant something
-- else: those rows go, and the months on the schedule are judged again from
-- the history. The 10M rung left the lifetime-tokens ladder, which now
-- starts at 1M.
--
-- Achievements are derived from usage, so removing them loses nothing the
-- history cannot award again.

DELETE FROM achievements WHERE key = 'monthly';
DELETE FROM achievements WHERE key = 'lifetime-tokens' AND tier = '10000000';

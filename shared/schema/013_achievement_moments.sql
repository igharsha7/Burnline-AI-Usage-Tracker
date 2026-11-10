-- Burnline schema v13: when each achievement was announced and celebrated
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- announced_at is when a notification about the achievement was decided,
-- shown or not; celebrated_at is when the app last played its arrival. NULL
-- means not yet. Both are moments in the app, not facts about usage, so a
-- rebuild of achievements may leave them NULL and simply celebrate again.
--
-- Achievements earned before this version were seen on their own shelves
-- already, so they count as both.

ALTER TABLE achievements ADD COLUMN announced_at INTEGER;
ALTER TABLE achievements ADD COLUMN celebrated_at INTEGER;

UPDATE achievements SET announced_at = created_at, celebrated_at = created_at;

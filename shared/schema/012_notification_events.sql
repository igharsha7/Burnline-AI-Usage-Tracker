-- Burnline schema v12: provider-independent notifications and pending reset explanations
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- notification_events records every alert sent, so none repeats at the next
-- refresh. A spend alert covers every provider at once, so provider_id may now
-- be NULL. SQLite cannot drop a NOT NULL constraint, so the table is rebuilt;
-- no earlier build wrote to it.
--
-- cycle_token names what an alert belongs to: a quota window's cycle token
-- (provider, quota, window start), "day:YYYY-MM-DD" or "week:YYYY-MM-DD" for
-- spend, or "expires:<epoch>" for a banked reset's expiry reminder. It is
-- never a reset time, which a banked reset moves. threshold is a percentage,
-- or for spend the limit in nanodollars.

CREATE TABLE notification_events_v12 (
  id                INTEGER PRIMARY KEY,
  provider_id       INTEGER REFERENCES providers(id),
  quota_key         TEXT,
  notification_type TEXT    NOT NULL,
  threshold         REAL,
  fired_at          INTEGER NOT NULL,
  cycle_token       TEXT
);

INSERT INTO notification_events_v12
  SELECT id, provider_id, quota_key, notification_type, threshold, fired_at, cycle_token
  FROM notification_events;

DROP TABLE notification_events;
ALTER TABLE notification_events_v12 RENAME TO notification_events;

CREATE INDEX idx_notif_dedup
  ON notification_events (provider_id, quota_key, notification_type, cycle_token);
CREATE INDEX idx_notif_fired ON notification_events (fired_at);

-- Early resets wait for the banked-reset ledger to catch up before an alert
-- names their cause. Keep the pending cycle and its last recorded before
-- figure through a restart; remove the row when explained or superseded.
CREATE TABLE pending_quota_resets (
  provider_id        INTEGER NOT NULL REFERENCES providers(id),
  quota_key          TEXT    NOT NULL,
  cycle_token        TEXT,
  seen_at            INTEGER NOT NULL,
  before_snapshot_id INTEGER REFERENCES quota_snapshots(id) ON DELETE SET NULL,
  PRIMARY KEY (provider_id, quota_key)
);

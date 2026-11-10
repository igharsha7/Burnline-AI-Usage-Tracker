-- Burnline schema v11: re-pricing that survives a crash
--
-- Copyright (C) 2026 Challapalli Harshavardhan Reddy
-- Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
--
-- Applying a manifest commits its new pricing versions in one transaction,
-- and re-pricing the events they cover runs afterwards in batches. A crash in
-- between used to leave those events at their old cost for good. Now each new
-- version queues its own recalculation in the same transaction, through the
-- trigger below; an implementation re-prices the events it covers and removes
-- the row only once every batch has committed, and finishes any row left over
-- at the next launch. Re-pricing is idempotent, so a replay is safe.
-- Events before compaction.compacted_before are never re-priced: compacted
-- time keeps the cost it had.

CREATE TABLE pending_repricing (
  pricing_version_id INTEGER PRIMARY KEY REFERENCES pricing_versions(id)
);

-- An older build may have stopped between applying a manifest and
-- re-pricing it, so every known version is checked once.
INSERT INTO pending_repricing SELECT id FROM pricing_versions;

CREATE TRIGGER pricing_versions_reprice AFTER INSERT ON pricing_versions
BEGIN
  INSERT INTO pending_repricing VALUES (NEW.id);
END;

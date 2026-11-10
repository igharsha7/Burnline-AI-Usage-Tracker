# Schema

Authoritative SQLite DDL for Burnline, shared by every platform implementation.

- Files apply in filename order: `001_initial.sql`, `002_*.sql`, and so on.
- **Never edit a released migration.** Schema changes are new files. An edited
  migration means two users on the same version have different databases.
- The file number is the schema version. Applications record it in
  `PRAGMA user_version` and refuse to open a database from the future.
- Plain SQLite only. No library-specific syntax, so any binding on any platform
  can apply these directly.
- Migration tests run against fixture databases captured at every prior version.
  A migration without a test is not finished.

Connection pragmas belong to the application, not to migrations: `journal_mode`,
`foreign_keys`, and `busy_timeout` are per-connection settings, and so are the
macOS writer's `synchronous = NORMAL`, `wal_autocheckpoint`,
`journal_size_limit`, `temp_store` and `cache_size`.

`auto_vacuum` is a property of the file, settable only before the first table
or by a full `VACUUM`, so it cannot be a migration either. Create databases
with `auto_vacuum = INCREMENTAL` before applying `001`, and switch an older one
with a single `VACUUM` before first use. That `VACUUM` also returns the space
migration `007` frees by rebuilding `usage_events`.

`usage_rollups` (migration `008`) is maintained by triggers defined in the
schema, so any implementation that writes `usage_events` keeps it exact without
code of its own. It is derived from events for every bucket from
`compaction.compacted_before` on (migration `009`); before that, the rollups
are all that remains of compacted history, so a rebuild leaves them alone.
An event older than the boundary may be inserted only into a bucket where the
provider's rollups count no more events than are stored, that is, one holding
none of its compacted history; anywhere else it could be one already counted. An implementation fills
`usage_events.cache_savings_nanos` itself, as it does `cost_nanos`.

`daily_rollups` (migration `010`) sums `usage_rollups` per UTC day, kept by
triggers on `usage_rollups`, so it too needs no code of its own. Readers take a
range's whole UTC days from it and the partial days at either end from
`usage_rollups`; the two give identical sums.

`pending_repricing` (migration `011`) queues each new pricing version through
an insert trigger. Recalculate its affected events in batches and remove the
marker only after every batch commits; retry remaining markers at launch.
Events before the compaction boundary stay frozen even if an interrupted
compaction has not deleted them yet.

`notification_events` (rebuilt by migration `012`) records each alert sent.
Deduplicate on provider, quota, type, threshold and cycle token; a spend alert
has no provider. Re-arming within a window is an implementation's own state.

`pending_quota_resets` (migration `012`) keeps early resets whose cause is
still awaiting a fresh banked-reset ledger. Each row references the last
recorded quota snapshot before the drop. Resume its grace period after a
restart, and remove it when explained or superseded by a later cycle.

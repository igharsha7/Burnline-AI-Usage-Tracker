# Performance

Burnline runs all day in the menu bar, beside the tools it measures. It must
cost close to nothing while idle, and stay interactive over years of history.
This page holds the budgets, the measured figures, and what was changed to
reach them.

Every figure here was measured on a MacBook Pro M4 with 16 GB of memory, in a
release build, unless it says otherwise. Re-measure with the
[opt-in tests](testing.md#opt-in-tests) before and after any change that
touches the paths below, and put both numbers in the pull request.

## Budgets

| Measure | Budget |
|---|---|
| Any dashboard range, warm | 100 ms |
| Idle sync with nothing changed | 100 ms |
| Idle CPU | Negligible over an hour with no activity |
| Store size | At most 300 bytes per event, indexes included |
| Store insert rate at ten million rows | 20,000 events a second (see [why revised](#two-revised-targets)) |
| Space returned after deleting a year | 80% (see [why revised](#two-revised-targets)) |
| Side files | WAL 64 MB, 3 backups, parser errors 90 days |

## The performance gate

CI checks every pull request against these budgets, and against the branch it
targets. Two suites, skipped unless `BURNLINE_PERF` names a directory for
their figures, measure what a user would feel:

- `StorePerformanceTests`: half a million synthetic events written (insert
  rate, bytes per event), then every dashboard range read warm, each the
  fastest of five runs.
- `SyncPerformanceTests`: a first import of 2,000 invented Claude Code
  transcripts, then the idle sync that finds nothing changed, the fastest of
  seven.

Run them yourself, in release:

```sh
BURNLINE_PERF=/tmp/perf swift test --package-path macos/Packages -c release --no-parallel --filter PerformanceTests
python3 .github/scripts/perf_compare.py --head /tmp/perf
```

In CI, the Performance job builds the pull request and its base branch and
measures them in turns on the same runner, twice each, keeping each figure's
best run. `.github/scripts/perf_compare.py` then fails the check when:

- **a figure is over its budget.** The budgets are the table above, except
  the insert rate, held at 20,000 a second because shared runners are slower
  than the reference Mac; the comparison catches smaller drops.
- **a figure is worse than the base by more than noise.** A time may be 25%
  and 3 ms slower, an insert rate 25% lower, the size per event 3% larger.

The report on the pull request lists every figure beside the base's and the
budget. A pull request that fails the gate is not merged until it is fixed, or
until the maintainer agrees a budget should change, in which case the change
and its reason go in this page.

## Storage

`ScaleTests`, ten million synthetic events over five years:

| Measure | Measured |
|---|---|
| Bytes per event, indexes included | **248** (from 412 before the storage work) |
| Insert rate at ten million rows | **24,600–26,500/s** across runs; 52,300/s at one million |
| Idle sync, real history | **8 ms** Claude Code, **5 ms** Codex |
| Space returned after deleting a year | **88%** (84% at one million); slowest concurrent batch 0.6 s |
| Compacting to 180 days | Ten million events: 2.49 GB to **247 MB**, first pass about 4 minutes. One million: 249 MB to 30 MB in 5.6 s. Every lifetime figure unchanged. |
| A real sync batch at ten million rows | About 40 ms |

What it took:

- Source file paths moved to their own table, so each event stores an id
  rather than a path.
- The `(provider, timestamp)` and `(model, timestamp)` indexes were dropped,
  and the unique key leads with the event id.
- The writer runs `synchronous = NORMAL`, with a 32 MB checkpoint interval, a
  32 MB cache and in-memory temporary files.
- Ingestion caches identities per batch and reuses prepared statements.
- Repricing walks the timestamp index.
- **Compaction.** Without it a heavy user (about 52,500 events a day) would
  pass 20 GB in five years. Past the detail window only 15-minute rollups
  remain, so the store settles near the window's size. See
  [data lifecycle](data-lifecycle.md).

### Two revised targets

The insert-rate target was 50,000 a second and the space-returned target 90%.
Both missed for one cause: the deduplication index is keyed by the event id,
and Claude Code's message ids are random. Every insert into a ten-million-row
index dirties a random page (about 4 KB of WAL per event), and deleting the
oldest year thins that index's pages rather than freeing them. The part-empty
pages are reused by later inserts, so the space is not leaked, only not
returned.

A hashed key would narrow both gaps, but it would move the uniqueness check
out of SQLite into application code that every implementation must copy
exactly, and would risk merging two events whose hashes collide. Uniqueness
stays in SQLite (see [decisions](decisions.md)), and the targets were revised to
what was measured.

## Aggregation

`ScaleTests`, ten million events over five years, each preset's chart by
provider and its breakdown by model together, on India's calendar:

| Preset | Buckets | Warm | Before the daily tier |
|---|---|---|---|
| Today | 24 hours | **0.4 ms** | 0.2 ms |
| Last 7 days | 7 days | **0.3 ms** | 0.2 ms |
| Last 30 days | 30 days | **2 ms** | 4 ms |
| Last 90 days | 90 days | **9 ms** | 20 ms |
| Year to date | 44 weeks | **10 ms** | 85 ms |
| Last year | 53 weeks | **12 ms** | 112 ms |
| All time | 61 months | **42 ms** | 559 ms |

- **Rollups.** Lifetime totals took 6.9 s over events and 82 ms over 15-minute
  rollups; a year of daily buckets took 0.6 s and 12 ms.
- **The daily tier.** Long ranges still scanned and sorted every 15-minute
  rollup twice. `daily_rollups` holds sums per UTC day, kept by triggers. A
  bucket reads its whole UTC days from it and its partial days from the
  15-minute rollups, so results are identical. It costs under a byte per
  event, and the insert rate held at 25,500 a second. See
  [aggregation](aggregation.md).
- Buckets are worked out on the calendar in Swift and passed to SQL as one
  materialised JSON edge list, so SQL never does calendar arithmetic.

## Dashboard

`DashboardLoadTimingTests` against this machine's real store, before and
after loading moved off the main actor and ran concurrently:

| Range | Before | After |
|---|---|---|
| Today | 3.0 ms | **0.9 ms** |
| 7 days | 3.5 ms | **1.2 ms** |
| 30 days | 5.6 ms | **2.2 ms** |
| 90 days | 9.0 ms | **4.4 ms** |
| Year to date | 11.1 ms | **3.7 ms** |
| 12 months | 16.6 ms | **13.9 ms** |
| All time | 9.7 ms | **2.9 ms** |

- Buckets and table rows are derived once per load, not in view bodies.
- Reloads triggered by new usage are coalesced.
- The store opens off the main thread at launch.
- Formatters are built once and reused.

## First import

`ImportTimingTests` on this Mac (2.8 GB of transcripts, under a tenth of it
usage records):

| | Before | After |
|---|---|---|
| Claude Code | 5.2 s | **1.3 s** |
| Codex | 7.6 s | **1.6 s** |
| Setup, debug build | 45 s | **about 12 s** |

Reading was nine tenths of the time, with every line copied before anything
looked at it. Now:

- The line reader splits and searches raw bytes, and copies only the lines an
  adapter selects.
- Files are parsed across the cores a group at a time, then written one at a
  time in their listed order.
- Codex looks for a record type near the start of each line, where Codex
  writes it. A line whose start does not show its type is searched whole, so a
  later format cannot be skipped silently; a comparison over the whole Codex
  history reads exactly the same records either way.
- While an import runs, setup polls only its progress.

Writing was already 0.3–0.4 s, so bigger transactions, deferred rollup
triggers and a different JSON parser were measured and left out.

## Idle

With the dashboard open and nothing happening: **0.0% CPU**, a 0.0 power
score, about **0.2 wakeups a second**, and a **115 MB** footprint, most of it
the window's layers, with no leaks of its own.

How it stays there:

- File-system events drive ingestion. The 5-minute sweep is a safety net, and
  an idle sync costs single-digit milliseconds.
- Quota refreshes follow the schedule in [quota](quota.md): faster only near a
  limit or a reset, slower when nothing is changing.
- Animations (the popover's glow, the comparison ticker, the Streaks fire) run
  only while they are on screen, and hold still under Reduce Motion.
- `PRAGMA optimize` runs on a slow timer and at quit.
- The update check is one timer a day, Sparkle's own.

## Measuring a change

1. Run the relevant opt-in test before the change, in release, and note the
   figures.
2. Make the change and run it again.
3. For UI work, check memory before and after in Activity Monitor or
   Instruments, and report it. Keeping Burnline light is a requirement, not
   polish.
4. Put both sets of figures in the pull request.

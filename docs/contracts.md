# Contracts

What every Burnline implementation must agree on, whatever its platform or
language. The macOS app is one implementation. The Windows app, in progress, is
another, and the two must be able to open each other's database.

This document is **normative**. "Must" and "never" mean exactly that. If a
platform document or the code disagrees with it, the contract wins and the
other is a bug. Changing a contract is a design decision: open an issue first,
and change this document in the same pull request as the code.

| Topic | Detailed in |
|---|---|
| The database's tables and triggers | [Data model](data-model.md) |
| Reading provider files | [Ingestion](ingestion.md), [providers](providers.md) |
| Prices | [Pricing](pricing.md) |
| Quota | [Quota and limits](quota.md) |
| Every numbered edge case | [Edge cases](edge-cases.md) |

## 1. The database is the interface between platforms

Burnline keeps everything in one plain SQLite file, not an ORM's store.

- **The schema is `shared/schema/*.sql`, and nowhere else.** An implementation
  applies those files; it never restates the schema in application code. Each
  file `NNN_name.sql` is one migration and produces schema version `NNN`.
- **The schema version is `PRAGMA user_version`.** An implementation must not
  track migrations in a table of its own as the source of truth. A database
  migrated by another implementation would look unmigrated to it.
- **Refuse a newer database.** An implementation must not open a database
  whose `user_version` is higher than it understands. A newer sibling may have
  added columns it would silently ignore and then overwrite.
- **Back up before a migration** that drops or rewrites a column, as a file
  copy. Never destroy data as a way to recover.
- **Migrations are never edited once released.** A change is a new file.
- **Derived tables are kept by the schema's own triggers.** `usage_rollups`,
  `daily_rollups` and `pending_repricing` are maintained by triggers defined
  in the migrations, so an implementation gets them by applying the schema.
  Application code never writes `daily_rollups`.
- Connection settings (journal mode, foreign keys, busy timeout, cache size,
  synchronous mode) are each implementation's own. `auto_vacuum` is set to
  `INCREMENTAL` when a file is created, before migration 001; a file created
  earlier is switched with one `VACUUM` before first use.

## 2. Representation

**Money is integer nanodollars.** US dollars times 10⁹ in a signed 64-bit
integer, covering about ±9.2 billion dollars. Never a float, in any language,
anywhere on the cost path.

**Cost uses a wide intermediate and rounds half to even.** Rates are
nanodollars per million tokens, so the product overflows 64 bits easily:
10⁹ tokens at $15 per million is 1.5×10¹⁹ before dividing.

```
cost_nanos = round_half_even(tokens × nanos_per_million_tokens / 1_000_000)
```

computed in 128 bits or an equivalent wide type. A result that still does not
fit is an error, never a wrapped value.

**USD only.** Providers publish in USD. A converted currency was rejected: a
figure that moves daily while its source does not is a support burden, and
storing per-event exchange rates would make history irreproducible.

**Timestamps are whole epoch seconds, UTC.** Never local time, never a string.
A provider timestamp with milliseconds is floored.

**Calendar buckets come from the calendar.** A local day, week or month is
computed from the user's calendar and time zone, never by dividing epoch
seconds. A local day is 23 or 25 hours across a daylight-saving change, and a
date can be skipped entirely.

**NULL means unknown, never zero.** An unpriced event has `cost_nanos` NULL.
Writing 0 would understate every total that sums it and make coverage report
complete data where it is not.

## 3. The canonical usage event

Every adapter normalises its provider's records into one shape. Nothing
provider-specific reaches storage, aggregates or charts.

| Field | Meaning |
|---|---|
| provider, model, session, project | resolved identities; any may be unknown |
| timestamp | epoch seconds, UTC |
| input, cached input, cache write, 1-hour cache write, output, reasoning | non-negative token counts |
| service tier | the provider's billing tier as written, or unknown, which prices as standard |
| pricing version, cost, confidence, cache savings | derived and recomputable |
| source file, source event id, source schema version, offset | provenance |

**Token counts are facts. Everything else is derived**, and the stored
provenance must be enough to recompute it without the provider's files, which
providers delete.

**Processed tokens = input + cached input + output.** Cache reads count.
Reasoning is stored but never added: providers already count it inside output,
and double-counting would be invisible.

**Input is the uncached remainder.** Anthropic reports uncached input beside
cache reads and writes. OpenAI reports the whole prompt as `input_tokens`, with
cache reads and writes as parts of it, so a Codex event's input is
`input_tokens − cached_input_tokens − cache_write_input_tokens`. A cached part
larger than the whole is a parser error, and input is then zero.

**The 1-hour cache write is a subset** of the cache-write count, never added to
it. The 5-minute part is the difference. Without it, cost could not be
recomputed once the provider's transcripts are gone.

**Deduplication is by `(provider, source event id)`.** It is a unique index in
the schema, leading with the event id. This is what makes re-reading a rotated,
rewritten or re-scanned file safe. When two copies of one event disagree, **the
more complete copy wins**: the one with more output tokens, then, on a tie, more prompt tokens (input plus cache reads and writes).
Providers write streaming snapshots of one response, and the later one carries
the final count. The rule does not depend on which copy is read first.

## 4. Reading provider files

- A source file's progress is its byte offset just past the last complete
  line, with its inode, size and modification time (seconds and
  nanoseconds), in `source_states`.
- **Resume at the offset only when the file is evidently the same file, grown
  by appending**: same inode, larger, and the byte before the offset still a
  newline. Anything else is read again from the start.
- **A final line with no newline is not read.** It may still be being written.
- **Insert events and advance the offset in one transaction.** A crash can then
  lose neither without the other.
- `resume_state` is opaque text owned by the parser that wrote it. An
  implementation that does not understand it, or finds it missing, must read
  the file from the start rather than resume without it. Deduplication makes
  that safe.
- **Parser errors record a reason, never the line.** The line may hold prompt
  text or code.

## 5. Pricing

- **Append-only.** A price change writes a new version; no version is ever
  updated or deleted.
- **Validity windows are `valid_from` inclusive, `valid_until` exclusive**, so
  an event exactly on a change belongs to exactly one version.
- **A gap is unpriced.** Never interpolate, and never fall back to today's
  price. A silently wrong historical cost is worse than a visible gap.
- **Recalculation uses historical versions**, never current rates.
- **Non-models are never priced.**
- An event's price is chosen from the rows valid at its time, narrowed in this
  order:
  1. rows of its service tier. A tier the model has no rows for is priced at
     standard and marked estimated;
  2. the highest prompt-length band whose threshold the prompt exceeds, where
     the prompt is input plus cache reads plus cache writes. The band prices
     **every** token of the event, not only those above the threshold;
  3. a user-sourced row over any other;
  4. the most recently started.
- Recorded tiers map to what they bill as: absent, `default`, `standard` and
  `auto` are standard; Codex's `fast` is OpenAI priority; Claude Code's `fast`
  is Anthropic fast mode. An unrecognised tier prices at standard, estimated.
- Each component is costed at its own rate. A cache read or write with no rate
  of its own falls back to the input rate (a 1-hour write first to the
  5-minute write rate), and the result is estimated. A missing input or output
  rate leaves the event unpriced rather than understated.
- **Confidence** is `exact` (the published price for that time),
  `reconstructed` (a price assumed for earlier time), `estimated` (a fallback
  was used) or `unknown`. It travels with every figure.
- **Cache savings** are per event, at the version that priced it, stored with
  the event and summed into the rollups. An event whose price has no cache
  rates of its own is left out, and the coverage of cache tokens is stated.
  There is never one discount across providers.
- **Fetched manifests must preserve history.** A newer price list is used only
  if every version already known is in it, unchanged. One that edits or drops
  a recorded price is refused whole. What it adds re-prices the events it
  covers and nothing else.
- **Repricing survives a crash.** Each new version queues itself in
  `pending_repricing` in the same transaction it is inserted. The marker is
  removed only after every batch has committed. Leftover markers are finished
  at the next launch.
- **Compacted time keeps its cost.** Events before the compaction boundary
  are never re-priced.

## 6. Model identity

- Raw model names are first put in a plain form: trimmed, lowercased, a
  bracketed variant such as `[1m]` removed (except on angle-bracket values),
  and a routing prefix such as `anthropic/` removed.
- **Aliases are time-bounded**, so history keeps resolving to the mapping that
  was right when it happened.
- Dated and undated names for one model alias to one canonical model.
- **Non-models** (a value in angle brackets, or one the alias manifest lists)
  are visible in breakdowns, never priced, and left out of share arithmetic.
- **An unrecognised model is kept**, unpriced, with unknown confidence. It is
  never discarded. A discarded event is gone for good; an unpriced one gains
  its cost when the manifest catches up.

## 7. Project identity

A usage record carries a working directory. It resolves to a project in this
order:

1. **Git remote**, normalised to `host/owner/repo`: protocol, credentials,
   port and a `.git` suffix removed, so the ssh and https forms agree. The
   remote is `origin`, or the first remote when there is no `origin`. A local
   path or `file://` remote does not count.
2. **Git root**, as a SHA-256 of its path, for a repository with no remote.
3. **The directory**, as a SHA-256 of its normalised path, outside any
   repository.

The remote comes first because it alone survives the folder moving. A path
hash splits a project's history the first time a folder is renamed, and the
split is invisible.

- One project per git root. A monorepo's sub-packages are not split.
- A linked worktree resolves to its main repository. A submodule is its own
  project.
- **A working directory that no longer exists** cannot be read for its remote.
  If its session already has a project, the record joins that project; it does
  not create one from the stale path.
- **Merging sets a redirect** (`merged_into_id`). No usage row is rewritten, so
  a merge is reversible. A merge that would create a loop is refused.

## 8. Quota

- **Quota and usage history are separate systems.** Token counts must never
  be presented as reproducing a subscription allowance.
- **Quota comes from the provider**, through the provider's own tool where
  one exists. Figures that cover the whole account, not just this Mac, are
  labelled as account-wide.
- **A reset is confirmed only by the provider**: a new window start, a reset
  time that advances, or a large fall in usage. Local time passing an old reset
  time confirms nothing. Refresh, then confirm, then notify.
- **A window can end early.** A banked reset ends it at the user's choice, and
  providers sometimes reset everyone. A fall of 20 points or more within a
  window, with the reset time unchanged, is a reset.
- **A failed read keeps the last figures**, marked stale with their age. Stale
  figures, and a window past its reset time with no confirming read, alert
  nothing.
- **Burn rate uses only the current window**, and discards the discontinuity at
  a reset rather than averaging across it.

### Banked resets

- A banked reset is a **discrete count** with a target window and an expiry:
  never a percentage, never folded into a used figure, never "extra
  allowance".
- **A window resets; a banked reset expires.** Using one word for both is the
  confusion this rule prevents.
- Burnline **observes banked resets and never spends one.**
- A source that cannot see banked resets says so, and what is known about
  them stays unchanged. A banked reset that disappears is `expired` if its
  expiry has passed, otherwise `unknown`; it is never assumed `consumed`.
- Countdowns come from refreshed provider data, never from extrapolating an
  old reset time.

### Notifications

- Every alert decided is recorded in `notification_events`, keyed on provider,
  quota key, type, threshold and **cycle token**, and is never sent twice for
  the same key.
- The cycle token names the window (or the day, week or expiry) an alert
  belongs to. **It is never the reset time**, which a banked reset moves.
  Keying on the cycle token is what re-arms every threshold after any reset.

## 9. Manifests

Data that can be corrected without an app release is shipped as versioned JSON
under `shared/`:

| File | Holds |
|---|---|
| `pricing/pricing.json` | model prices with validity windows, tiers and bands |
| `pricing/model_aliases.json` | raw model names to canonical models, time-bounded, and non-models |
| `corpus/comparisons.json` | the comparison corpus |

An implementation must check `schemaVersion` on load and report a mismatch
separately from a missing or malformed file. **A manifest from the future is
refused**, not read with its unknown fields ignored.

## 10. Storage and history

- **Lifetime history is kept by default.** Providers delete their own
  transcripts (Claude Code after 30 days by default), so Burnline's database
  becomes the only record. Deleting history happens only by the user's choice.
- **Rollups are exact and derived.** `usage_rollups` sums every token type,
  cost, unpriced count and cache savings per 15-minute UTC bucket, provider,
  model and project (0 for a missing model or project). Fifteen minutes because
  every time-zone offset in use is a multiple of it, so every local day, week
  and month is a whole number of buckets.
- `daily_rollups` holds the same sums per UTC day. A range reads its whole UTC
  days there and its partial days at either end from `usage_rollups`; the
  result is identical to summing `usage_rollups` alone.
- **Compaction keeps every figure.** Events older than the detail window are
  deleted and their rollups kept. `compaction.compacted_before` is the
  boundary: a multiple of 900, moved forward before any event is deleted,
  never back, and never past the bucket of the newest event it compacts.
- **A late event before the boundary** may be inserted only into a 15-minute
  bucket holding none of its provider's compacted history. In any other bucket
  it could be an event the rollups already count.
- Space is reclaimed with `incremental_vacuum` in small steps. A full `VACUUM`
  runs only after a compaction that removes a quarter or more of the stored
  events.

## 11. Privacy and security

Binding on every implementation. [Privacy and security](privacy-and-security.md)
explains each.

- **Usage metadata only.** Never store prompts, responses, source code,
  terminal contents or transcript text. Decode only the fields needed.
- **Credentials are read at the point of use and never retained**: not in the
  database, not in logs, not in crash reports, not in preferences. Never
  renewed, since renewing writes to the provider's own login.
- **No telemetry.** Any future telemetry is explicit opt-in and never includes
  usage figures, project paths, prompts or token counts.
- **Network use is limited** to the public price list (no identifier, with an
  opt-out) and quota reads. A request carrying a provider's token names itself
  as Burnline, never posing as the provider's tool.
- **Read-only toward providers.** Never modify their configuration or files.

## 12. Licensing

- **AGPL-3.0, with the Section 7(b) attribution term in `NOTICE`.**
- Every implementation must have an About surface reachable from its
  interface showing the copyright, the license, the attribution required by
  `NOTICE` and the source link. This is a license obligation.
- Every source file carries the AGPL header with the copyright line.
- Dependencies must be AGPL-compatible. MIT, BSD and Apache-2.0 are;
  proprietary and GPLv2-only are not.

See [licensing](licensing.md).

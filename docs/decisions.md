# Decisions

The choices that shape Burnline, each with the reason it was taken. The
reason is what matters: it tells a future reader whether new information
should reopen a decision. Propose a change to any of these in an issue before
writing code against it.

## Locked

### Product

| Decision | Reason |
|---|---|
| **Local-first: no account, no backend, no sync** | Usage history is private, and everything Burnline needs is already on the Mac. A backend would add a party to trust and a service to keep running. |
| **No telemetry** | Nothing Burnline would learn is worth the trust it costs. Any future telemetry must be explicit opt-in and never include usage figures, paths, prompts or token counts. |
| **Usage metadata only** | Transcripts hold prompts and code. Burnline never stores them, and never decodes them into a value. See [privacy and security](privacy-and-security.md). |
| **Read-only toward providers** | Burnline observes. It never writes a provider's files or configuration, renews a login, or spends a banked reset. |
| **USD only** | Providers publish USD. A converted display currency was considered and rejected: a figure that moves daily while the source does not is a support burden, and storing per-event exchange rates would make historical totals irreproducible. |

### Platform

| Decision | Reason |
|---|---|
| **A native menu-bar utility with a full dashboard** | Burnline sits beside the tools it measures all day, so it uses native controls, notifications and the Settings scene, and costs close to nothing while idle. |
| **Swift 6 strict concurrency from the start** | Retrofitting data-race safety is harder than starting with it. Ingestion, quota and notifications are actors. |
| **Minimum macOS 14** | `MenuBarExtra`, Swift Charts, `SMAppService` and Observation all need it. |
| **Not sandboxed** | Burnline reads `~/.claude`, `~/.codex` and Xcode's coding-assistant homes. A sandbox would force a folder picker and a security-scoped bookmark per provider, and first-run detection would stop working. |
| **Un-notarized `.dmg` plus a Homebrew tap** | Notarization needs the paid Apple Developer Program. The AGPL rules out the Mac App Store for redistributors anyway. Without notarization every download needs one "Open Anyway" in System Settings on first launch; Homebrew 5.0 no longer bypasses it. See [releasing](releasing.md). |
| **Dark only** | The app sets the dark appearance at launch, so every surface is designed and checked once. Each colour token has one value and an Increase Contrast variant. |
| **Pure neutral greys** | Warm-tinted surfaces read as yellow beside the ember accent. |

### Data

| Decision | Reason |
|---|---|
| **SQLite through GRDB, never SwiftData** | The schema needs explicit indexes, aggregation queries, versioned migrations and a file another platform can open. GRDB is a wrapper over SQLite, not an alternative, so the file stays portable. |
| **The schema lives in `shared/schema/*.sql`, never in code** | The database is the interface between platforms. A Windows implementation applies the same files. |
| **`PRAGMA user_version`, not GRDB's `DatabaseMigrator`** | The migrator records applied migrations in its own table. A database migrated by another implementation would have none, and migration 1 would run again. |
| **Integer nanodollars, never floating point** | Money must add up exactly across millions of events. Multiplication runs in 128 bits and rounds half to even. |
| **Epoch-second UTC timestamps; calendar work at read time** | Stored facts never depend on the machine's zone. Time-zone changes, daylight saving and the week start apply when a range is built. |
| **Token counts are facts; cost is derived** | Prices change and get corrected. Keeping the counts and the price version lets cost be recomputed. |
| **Append-only, versioned pricing** | Historical cost must never be rewritten silently. A correction is a new version; affected events are repriced explicitly. |
| **Uniqueness stays in SQLite** (1 November 2026) | A hashed event key would raise the insert rate, but would move the check into code every implementation must copy exactly, and risk merging two events whose hashes collide. See [performance](performance.md#two-revised-targets). |
| **15-minute UTC rollups** | Every time-zone offset in use is a multiple of 15 minutes (India is UTC+5:30, Nepal +5:45), so local days re-bucket exactly; hourly buckets would split them. Rollups are kept by triggers, so any implementation that writes events keeps them exact. |
| **A daily tier** (1 November 2026) | Long ranges were slow over 15-minute rollups alone. Sums per UTC day cut all-time from 559 ms to 42 ms, at under a byte per event. |
| **Compaction past a detail window** (180 days by default) | Without it a heavy user would pass 20 GB in five years. Rollups keep every figure exact; only per-event detail goes. |
| **zstd, from its official repository, pinned** | Codex compresses older sessions, which are most of a long history, and macOS has no zstd decoder. It is C built from source, so the version is exact. |
| **Prices fetched daily, on by default** | Prices change between releases, and a stale price misstates every later event. The fetch is a plain GET of a public file with no identifier, and can be turned off; the bundled prices still price all history. |
| **Injectable clock and randomness** | No test may depend on the wall clock or on chance. |

### Repository

| Decision | Reason |
|---|---|
| **Platforms are directories, never branches** | `macos/` and `windows/`, which is in progress, share `shared/` and change together. Branches per platform would drift. |
| **One package, five modules** | One `swift test` builds and tests everything without Xcode, and the import rule is checked by tests. |
| **No MVP or phase split in the product** | The specification describes the whole product; build order is a dependency order, not a roadmap. |
| **AGPL-3.0 with an attribution term** | No proprietary forks, while commercial use stays allowed. See [licensing](licensing.md). |
| **Contributions under the AGPL, with no contributor agreement** (10 November 2026) | Burnline is a community project, not a commercial one, and asking contributors to sign their rights over would put people off. Each contributor keeps the copyright in what they write and licenses it under the project's terms. The cost is accepted: a different license for the whole project would need every contributor's agreement. See [licensing](licensing.md#contributions-and-copyright). |

## Planned

| What | Where it stands |
|---|---|
| **OpenCode and Antigravity** | Planned for v0.2.0. Before either: inspect what each writes locally and whether token counts exist; decide how quota is exposed; add their models to the pricing and alias manifests. Until then they are absent, not shown as zero. See [adding a provider](adding-a-provider.md). |

## Ideas

Not commitments. Each is small enough to add on its own. Rewards should lean
toward good habits (pacing, caching, steady work) rather than raw volume,
since Burnline exists to watch cost and limits.

- **Pacing achievements.** "Under the line": finish a weekly window without
  hitting its limit. "Steady hand": four weeks in a row with no run-out
  warning. Built on the burn-rate projection.
- **Efficiency badges.** A week above a 90% cache-hit rate; a new lowest cost
  per output token.
- **More personal records.** Longest session, cheapest productive day, each
  with a small "new record" moment.
- **Weekly recap.** Shown once on Monday: the streak, records broken and the
  week's story.
- **Leaderboards.** Comparing streaks or pacing with friends would need a
  server, which the local-first core does not have, so it would be opt-in and
  separate from it, and would likely need funding to run. Not before then.
- **Personal streak threshold.** Scale the daily bar to each person's typical
  day, with the fixed bar as its floor, so a light user and a heavy one are
  held to comparable effort.

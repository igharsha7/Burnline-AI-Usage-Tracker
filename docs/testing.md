# Testing

How Burnline is tested, what the tests are for, and the rules every new test
follows.

```sh
swift test --package-path macos/Packages
```

This builds and tests every module without Xcode or a running app. It is the
check to run before every commit, along with the license-header script (see
[development](development.md#license-headers)).

## Principles

- **Test behaviour, not wiring.** A test states a rule a user would notice if
  it broke, such as "a banked reset re-arms the thresholds". Smoke tests that
  only check something can be built are not wanted.
- **Name the rule.** Test names are sentences, written as raw identifiers,
  and **cite the edge-case identifier** when they protect one:

  ```swift
  @Test func `EC-R1 an event exactly on a price boundary takes the new price`() throws { … }
  ```

  A failing test then names the rule it guards, and a search for `EC-R1` finds
  the rule in [the register](edge-cases.md) and every test that holds it.
- **No wall clock and no chance.** Code takes a `WallClock` and, where it
  draws at random, a `RandomNumberGenerator`. Tests pass a `ManualClock` and a
  seeded generator. No test may depend on today's date, the machine's time
  zone or luck.
- **No real provider data in normal runs.** Tests that read this machine's
  history or quota are opt-in (see [opt-in tests](#opt-in-tests)).
- **Scratch files go through `TestDirectory`.** Never create directories with
  `FileManager.default.temporaryDirectory` directly.
- **No real system services in normal runs.** The Keychain, the network and
  the battery are injected: a test passes a stub, never the real thing, so the
  suite behaves the same on any Mac and in CI.
- **Fail, never hang.** Every wait for something asynchronous is bounded (see
  [waiting](#time-and-waiting)), so a change that never comes fails its test in
  seconds instead of stalling the run.
- **Assert the value, not that there is one.** Check the exact cost, the exact
  row or the exact sequence. `!= nil`, a count alone or "any array" passes
  while the result is wrong.

## Framework

Swift Testing throughout:

| Use | For |
|---|---|
| `@Test` with `#expect` | Most checks. A failing `#expect` reports and carries on. |
| `try #require` | Stopping at the first genuine failure, such as a value the rest of the test depends on |
| `@Test(arguments:)` | Sweeps: magnitudes, time zones, malformed inputs |
| `@Suite(.serialized)` | Suites that share a resource, such as a real store |
| `@Suite(.enabled(if:))` | Opt-in suites gated on an environment variable |
| `.timeLimit(.minutes(1))` | Tests and suites that start child processes, watch files or wait on tasks, so a hang fails instead of stalling the run |

## Layout

Tests live in `macos/Packages/Tests/`, one target per module plus the
architecture checks.

| Target | Holds |
|---|---|
| `ArchitectureTests` | The [fitness tests](#fitness-tests): the import rule and the source rules |
| `BurnlineCoreTests` | Pure domain logic: money, time and buckets, pricing, model and project names, reset detection, burn rate, alert planning, heat, streaks and tiers, achievements, limit history |
| `BurnlineStoreTests` | The database: lifecycle and migrations, ingestion writes, repositories, aggregation SQL, compaction, storage and space, pricing storage, data control, scale |
| `BurnlineProvidersTests` | Parsers for Claude Code and Codex, project identity, quota readers, child processes |
| `BurnlineServicesTests` | Actors and services: ingestion (full and incremental), quota, notifications, aggregation, activity, comparisons, pricing updates, data and maintenance |
| `BurnlineUITests` | View models and views: dashboard, menu bar, Limits outlook, Activity page, Streaks card, Settings, tour, token mix, provider logos, accessibility, review renders |

`BurnlineTestSupport` is a library target used only by tests. No product
exposes it, so it never reaches the app.

## Scratch files: `TestDirectory`

```swift
let directory = TestDirectory.make("Store")      // a new, empty directory
let file = TestDirectory.file("rollout.jsonl")   // a path in a new directory
```

Every directory is created inside one folder per test run,
`BurnlineTests-<pid>` in the system temporary directory, removed when the run
exits. A run that crashed leaves its folder behind and the next run removes
it, once it can see that process has gone. Only folders with that prefix
directly in the temporary directory are ever removed, so a mistake here cannot
reach a provider's real history.

## Time and waiting

Nothing in a test waits for real time to pass. `BurnlineTestSupport` has
these tools, each for one shape of code:

| Tool | For |
|---|---|
| `ManualClock` | The `WallClock` code reads the time from. `advance(seconds:)` moves it. |
| `SteppingClock` | A `run` loop that sleeps on a `Clock`, such as the quota or pricing loop. Every sleep returns at once and is recorded in `waits`; `onSleep` usually advances a `ManualClock` by the same amount; after `sleeps` of them the loop is ended. |
| `ControlledSleep` | Code that takes its sleep as a closure, such as the menu bar's midnight and live-expiry timers. A sleep stays pending until the test calls `release` for its duration. |
| `within(seconds:)` | Awaiting something that should arrive, such as the next change on a feed. Gives up with nil. |
| `eventually(within:)` | A condition that becomes true on a task the code owns, such as a model's reload. Polls, and gives up with false. |

```swift
let stepper = SteppingClock(sleeps: 3) { clock.advance(seconds: $0.components.seconds) }
await quota.run(clock: stepper)
#expect(reader.readTimes == [0, 900, 1_800, 2_700])
```

Prefer checking *what happened when*, such as the times of reads, over the
exact waits: a loop may split a long wait into shorter sleeps.

A test that needs a real wait, such as the FSEvents watcher, says so in its
name or comment, and bounds it with a time limit.

## Fixtures

- **Store fixture** (`StoreFixture`). A database in a fresh `TestDirectory`,
  built from the schema files the app actually ships in `shared/schema`, with
  a `ManualClock` at a fixed instant. Store tests never create a schema of
  their own.
- **Provider fixtures.** Parser tests write small, anonymised transcript and
  rollout files into a `TestDirectory`, one per case: malformed lines,
  truncated final lines, missing fields, older format versions, duplicate
  records across files. Working directories in fixtures point at paths that do
  not exist (such as `/nonexistent/burnline-fixture`), so project identity
  never reads a real repository by accident.
- **Synthetic history** (`SyntheticHistory`). A deterministic generator of
  sessions and events in the shape of real use, across both providers and a
  realistic set of models, written in batches of 1,000. It drives the scale
  tests and the storage and compaction measurements.

## Fitness tests

`ArchitectureTests` reads the source tree and fails the build when the
architecture is broken, since the compiler alone does not reliably reject an
undeclared import between targets of one package.

| Rule | Check |
|---|---|
| **Import rule** | Each module imports only the Burnline modules it may: Core none (and nothing but Foundation); Store, Core; Providers, Core and Store; Services, Core, Store and Providers; UI, Core and Services (never Store); the app target, Core, Services and UI. GRDB only in Store. SwiftUI, AppKit and Charts only in UI and the app target. See [architecture](architecture.md#the-dependency-rule). |
| **The wall clock is read only inside `Time/`** | No `Date()`, `Date.init()`, `Date.now` or `.timeIntervalSinceNow` outside `BurnlineCore/Time/`. Conversions such as `Date(timeIntervalSince1970:)` and injected clocks are fine. |
| **No floating point in `Money/`** | No `Double`, `Float` (any width), `CGFloat`, `TimeInterval`, decimal literal or exponent literal in `BurnlineCore/Money/`. |

Each rule has tests of its own matcher, with sources it must catch and
sources it must not (comments, strings, integer ranges), so a rule cannot
quietly start passing everything.

## What is covered

| Area | Covered by |
|---|---|
| Money | Rounding half-to-even, 128-bit intermediates, overflow at extreme token counts, formatting |
| Time | Daylight-saving days of 23 and 25 hours, time-zone change, week start, clock skew, bucket edges |
| Pricing | Boundaries, gaps, tiers, long-prompt bands, user overrides, cache savings and coverage, manifest preservation, repricing after a crash |
| Ingestion | Every EC-I case, resumption from offsets and saved state, replaced and shrunk files, the 5-minute sweep, first import |
| Identity | Every EC-M and EC-P case, remote normalisation, worktrees, merges and their reversal |
| Database | Fresh schema from the shipped files, every migration, refusal of a newer file, a failed migration restored from backup, the writer lock, disk-full rollback |
| Storage | Compaction leaving every figure unchanged, late history refused, space reclaimed, side files bounded |
| Quota | Each reader against recorded responses, every failure reason, fallbacks, reset detection, banked-reset ledger, staleness |
| Notifications | Thresholds, hysteresis, deduplication by cycle, re-arming after both kinds of reset, stale data suppressed, permission denied |
| Activity | Streak rule and freezes, tiers, achievements earned once, monthly challenges, records |
| Comparisons | The shipped corpus loads, every unit renders, multipliers stay in range, rotation is deterministic |
| Interface | View-model figures, empty and failure states, accessibility labels, tour targets, Settings behaviour |
| Privacy | A sentinel token through a full quota refresh never reaches the database files or any printed state |

## Coverage

```sh
macos/scripts/coverage.sh                    # runs the tests, then line coverage per module
macos/scripts/coverage.sh --files            # and per file, least covered first
macos/scripts/coverage.sh --check            # fails if a gated module lost coverage
macos/scripts/coverage.sh --update-baseline  # records today's figures as the floor
```

It counts Burnline's own sources only. Coverage is a guide to what has not
been tried, not a target: a test that runs a line without checking what it did
adds coverage and protects nothing.

- **Core, Store, Providers and Services** must not lose coverage. Their floor
  is in `macos/scripts/coverage-baseline.json`, and `--check` fails a pull
  request that takes any of them more than 0.1 points below it. When tests
  raise a figure, run `--update-baseline` and commit the new floor with them,
  so it never slides back.
- **UI is not gated.** Most of its lines are SwiftUI layout. Its logic lives in
  the view models, and that is what UI tests check.
- **The money and data paths** (cost, pricing, time windows, compaction,
  migrations) are held near complete; an uncovered line there needs a reason.

## Untested changes

Some changes cannot be covered by the suite: a visual change, behaviour that
depends on a real provider or on macOS itself. That is acceptable when it is
said. A pull request lists what its tests do not cover under **Not covered by
tests** in the template, with how it was checked instead, and carries the
`tests: not covered` label. See [contributing](../CONTRIBUTING.md#untested).

## Opt-in tests

Each is skipped unless its environment variable is set. Run them from the
repository root.

| Command | What it does |
|---|---|
| `BURNLINE_PERF=/tmp/perf swift test --package-path macos/Packages -c release --no-parallel --filter PerformanceTests` | The [performance gate](performance.md#the-performance-gate)'s suites, which CI runs on every pull request. Synthetic data only; takes under a minute. |
| `BURNLINE_SCALE=1 swift test --package-path macos/Packages -c release --filter ScaleTests` | Measures the store on a synthetic history. `BURNLINE_SCALE_EVENTS` sets its size (default one million). Ten million takes about 13 minutes and 2.5 GB. `BURNLINE_SCALE_KEEP` keeps the database afterwards. |
| `BURNLINE_REAL_HISTORY=1 swift test --package-path macos/Packages --filter RealHistoryTests` | Imports this machine's real Claude Code and Codex history into a throwaway database and prints counts only |
| `BURNLINE_IMPORT_TIMING=1 swift test --package-path macos/Packages -c release --filter ImportTimingTests` | Times a first import of this machine's history, split into reading and writing |
| `BURNLINE_REAL_QUOTA=1 swift test --package-path macos/Packages --filter RealQuotaTests` | Reads real quota through every source and prints response shapes only. May ask for Keychain access to Claude Code's login. |
| `BURNLINE_DASHBOARD_DB=/store/dir swift test --package-path macos/Packages -c release --filter DashboardLoadTimingTests` | Times every dashboard range against a real store, opened read-only |
| `BURNLINE_LAUNCH_DB=/copy/of/store swift test --package-path macos/Packages -c release --filter DashboardLoadTimingTests` | Times the launch steps, opening that copy as the writer. **Use a copy**: it migrates. |

These read real data but never print a prompt, a path or a figure beyond
counts and timings, and never write to a provider's files.

## Render tests

Some UI tests render a view to a PNG for a person to look at. They write
nothing unless their variable names a destination.

| Variable | Renders |
|---|---|
| `BURNLINE_RENDER=/path/popover.png` (`MenuBarTests`) | The popover from fixtures, with two providers and with three |
| `BURNLINE_REVIEW_DIR=/dir` (`ReviewRenderTests`) | States that cannot be brought about on demand: degraded quota in the dashboard and the popover, a full disk, a database that did not open, a provider no longer read beside the history it kept |
| `BURNLINE_STREAKS_RENDER=/dir` (`StreakCardTests`) | The Streaks card at several streak lengths and states, across the tiers |

Use them when changing those surfaces, and attach the images to the pull
request.

## Writing a new test

1. Find the target that owns the code under test. A rule in Core is tested in
   Core, even if it is also visible in the interface.
2. If it protects an edge case, put the identifier first in the name. If the
   case is new, add it to [the register](edge-cases.md).
3. Inject the clock and any randomness. Build files and databases through
   `TestDirectory` and `StoreFixture`.
4. Prefer one behaviour per test, with arguments for sweeps over a value.
5. Bound every wait with the tools in [time and waiting](#time-and-waiting).
6. Check that the test can fail: break the rule it guards for a moment, see it
   fail, and put the rule back.
7. Run the whole suite, not only the new test: the fitness tests check every
   file.

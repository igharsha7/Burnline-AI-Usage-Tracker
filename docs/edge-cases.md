# Edge cases

The register of every edge case Burnline handles. Each has a stable
identifier. **Cite the identifier in the name of the test that protects it**,
so a failing test names the rule it guards, and a search for the identifier
finds both the rule and its tests.

The rules in the "Required" column bind every implementation, as part of
[the contracts](contracts.md). "Where" points at the macOS code, and "Tests"
lists the suites (in `macos/Packages/Tests/`) whose test names cite it.

Some cases appear in more than one layer: a rule enforced in the data layer is
often enforced again in presentation, and both places get a test.

## Ingestion (EC-I)

| ID | Case | Required | Where | Tests |
|---|---|---|---|---|
| EC-I1 | Malformed record | Record a reason (no content), skip it, continue the file | adapters, `JSONLines.describe` | ClaudeCodeParserTests, CodexParserTests |
| EC-I2 | Truncated final record | Do not advance the offset past it | `LineReader` | ClaudeCodeParserTests, IncrementalIngestionTests |
| EC-I3 | File shrank or was replaced | Read it all again; uniqueness absorbs duplicates | `IngestionActor` read plan | IncrementalIngestionTests |
| EC-I4 | Same event in two files | Deduplicate on provider + source event id | the unique index, `UsageRepository` | IngestionTests |
| EC-I5 | Unknown fields | Ignore them; keep the source schema version | adapters' decoders | ClaudeCodeParserTests |
| EC-I6 | No project path | Unknown project, grouped as "No project" | adapters, aggregation | AggregationTests, ClaudeCodeParserTests, CodexParserTests |
| EC-I7 | No session id | Synthesise one from the file; never drop the event | adapters | ClaudeCodeParserTests, CodexParserTests |
| EC-I8 | Absent or negative token count | Treat as zero and record a parser error | `ParseOutput` count helper | ClaudeCodeParserTests, CodexParserTests |
| EC-I9 | Crash between insert and offset update | Same transaction, so impossible | `IngestionBatch` | IncrementalIngestionTests |
| EC-I10 | File events missed while asleep | Reconcile at launch, on wake and on a 5-minute sweep | `Reconciler`, `AppDelegate` | IncrementalIngestionTests |
| EC-I11 | Provider not installed | A detection state, not an error | `detect()`, `ProviderHealth` | ClaudeCodeParserTests, CodexParserTests, IncrementalIngestionTests, IngestionActorTests |
| EC-I12 | Very large file on first import | Stream in chunks; never load it whole | `LineReader`, `ZstdStream` | ClaudeCodeParserTests, CodexParserTests |

## Model identity (EC-M)

| ID | Case | Required | Where | Tests |
|---|---|---|---|---|
| EC-M1 | Non-model values (`<synthetic>`) | A non-model: visible, never priced, out of shares | `ModelRepository` | IngestionTests, RepositoryTests |
| EC-M2 | Dated and undated ids coexist | Alias both to one canonical model | `model_aliases.json`, `ModelRepository` | IngestionTests |
| EC-M3 | Unrecognised model | Create it unpriced, unknown confidence; never discard | `ModelRepository` | DataControlTests, IngestionTests |
| EC-M4 | Provider renames a model | Time-bounded aliases keep history resolving | `model_aliases` | IngestionTests |
| EC-M5 | Empty model field | Unknown model, still counted | `ModelRepository`, aggregation | AggregationTests, ClaudeCodeParserTests, IngestionTests |

## Project identity (EC-P)

| ID | Case | Required | Where | Tests |
|---|---|---|---|---|
| EC-P1 | Repository moved or renamed | The remote identity is unchanged; history intact. A record whose directory is gone joins its session's project. | `ProjectIdentityResolver`, `IngestionBatch` | IngestionActorTests, ProjectIdentityTests |
| EC-P2 | Repository with no remote | Git root hash; a move splits it, and a merge recovers it | `ProjectIdentityResolver` | ProjectIdentityTests |
| EC-P3 | Two clones of one repository | One project: a project, not a checkout | remote identity | ProjectIdentityTests |
| EC-P4 | Worktrees | Resolve to the main repository through `commondir` | `ProjectIdentityResolver` | ProjectIdentityTests |
| EC-P5 | Monorepo | One project at the root | `ProjectIdentityResolver` | ProjectIdentityTests |
| EC-P6 | Outside any repository | Normalised path hash | `ProjectIdentityResolver` | ProjectIdentityTests |
| EC-P7 | Merged projects | A redirect; rows never rewritten; reversible | `ProjectRepository`, aggregation's `projectRoots` | AggregationTests, RepositoryTests |
| EC-P8 | ssh and https remote forms | Normalise before identifying | `GitRemote` | ProjectIdentityTests |

## Time (EC-T)

| ID | Case | Required | Where | Tests |
|---|---|---|---|---|
| EC-T1 | Daylight-saving change | Calendar day buckets (23 or 25 hours), never epoch division | `LocalCalendar`, `BucketWidth`, aggregation | AggregationServiceTests, AggregationTests, BucketTests, NotificationServiceTests, TimeTests |
| EC-T2 | Time-zone change | Buckets recompute; stored timestamps stay UTC | `LocalCalendar` | BucketTests, TimeTests |
| EC-T3 | Skewed machine clock | Keep the provider's timestamp; clamp a future one for placement and flag it | `CheckedTimestamp` | TimeTests |
| EC-T4 | Week start preference | Applied at query time | `LocalCalendar` | BucketTests, TimeTests |
| EC-T5 | Sleep across a reset | Refresh quota before evaluating a reset | `AppDelegate` wake handling, `QuotaActor.refreshAll` | QuotaActorTests |
| EC-T6 | Countdown reaches zero | Confirm with the provider; show "reset pending"; never assume; alert nothing until confirmed | `ProviderQuotaState.status`, `AlertPlanner` | AlertPlannerTests, QuotaActorTests, RepositoryTests, ResetDetectionTests, ReviewRenderTests |

## Pricing (EC-R)

| ID | Case | Required | Where | Tests |
|---|---|---|---|---|
| EC-R1 | Event exactly on a price boundary | `valid_from` inclusive, `valid_until` exclusive | `PricingVersion.applies` | PricerTests |
| EC-R2 | Gap between versions | Unpriced; never interpolate or use today's price | `Pricer` | PricerTests |
| EC-R3 | No cache pricing for a model | Left out of savings; coverage stated | `Pricer.cacheSavings` | DataControlTests, PricerTests |
| EC-R4 | Retroactive manifest version | Re-price only the affected events; survive a crash | `PricingRepository`, `pending_repricing` | AggregationTests, DatabaseLifecycleTests, PricingStoreTests, PricingUpdaterTests |
| EC-R5 | User price override | A user-sourced version outranks the official one | `Pricer` | PricerTests |
| EC-R6 | Very large token counts | Wide intermediate; no overflow | `Nanodollars.cost`, `TokenCounts` | AggregationTests, MoneyTests, PricerTests |
| EC-R7 | Tier with no rows of its own | Priced at standard, marked estimated | `Pricer` | PricerTests |
| EC-R8 | Prompt longer than a band threshold | The whole event at the band's rates | `Pricer` | PricerTests, PricingStoreTests |
| EC-R9 | Fetched manifest edits a recorded price | Refused whole; known prices kept | `PricingManifest.preserves` | PricingStoreTests, PricingUpdaterTests |

## Quota (EC-Q)

| ID | Case | Required | Where | Tests |
|---|---|---|---|---|
| EC-Q1 | Banked reset fires mid-window | A legitimate reset; burn rate discards the discontinuity; thresholds re-arm | `ResetDetector`, `BurnRateEstimator`, `AlertPlanner` | AlertPlannerTests, BurnRateTests, ModelTests, NotificationServiceTests, QuotaActorTests, ResetDetectionTests |
| EC-Q2 | Reset time moves | Re-derive countdowns from provider data; one cycle; nothing re-arms | `ResetDetector`, `QuotaRepository` cycles | AlertPlannerTests, ModelTests, RepositoryTests, ResetDetectionTests |
| EC-Q3 | Provider unreachable | Show the last snapshot, marked stale with its age; never alert on it | `QuotaActor`, `ProviderQuotaState` | AlertPlannerTests, BurnRateTests, ChildProcessTests, NotificationServiceTests, QuotaActorTests, QuotaReaderTests, ResetDetectionTests, ReviewRenderTests |
| EC-Q4 | Credential expired | The provider is degraded; history unaffected; never renewed | `ClaudeCredentials`, `QuotaReadError` | QuotaActorTests, QuotaReaderTests, ReviewRenderTests |
| EC-Q5 | Account-wide usage | Labelled as account-wide | `QuotaReading`, `AlertPlanner` | AlertPlannerTests, QuotaActorTests, ReviewRenderTests |
| EC-Q6 | Banked reset vanishes silently | Status unknown (or expired once past its expiry); never assumed consumed | `BankedResetLedger` | ModelTests, QuotaActorTests, ResetDetectionTests, ReviewRenderTests |
| EC-Q7 | Simultaneous resets | Independent state per quota | `QuotaActor`, `AlertPlanner` | AlertPlannerTests, QuotaActorTests, QuotaReaderTests |

## Database (EC-D)

| ID | Case | Required | Where | Tests |
|---|---|---|---|---|
| EC-D1 | Disk full mid-write | Roll back, halt ingestion, surface loudly | single transactions, `Reconciler`, `SavingBanner` | DatabaseLifecycleTests, IncrementalIngestionTests |
| EC-D2 | Corrupt database | Fail closed; offer restore; never recreate empty | version probe, `StoreFailureView` | DataControlTests, DataServiceTests, DatabaseLifecycleTests, SettingsTests |
| EC-D3 | Migration failure | One transaction; restore the pre-migration backup | `BurnlineDatabase`, `DatabaseBackups` | DatabaseLifecycleTests |
| EC-D4 | Two instances | One writer; concurrent readers are fine | `WriterLock` | DatabaseLifecycleTests |
| EC-D5 | Retention reduced | Warn that provider history older than their own retention is unrecoverable | Data pane, `UsageRepository.countBefore(_:)` | DataServiceTests, RepositoryTests, SettingsTests, StoreMaintenanceTests |
| EC-D6 | Database from a newer version | Refuse to open; never read partially | version probe | DataControlTests, DatabaseLifecycleTests |
| EC-D7 | Lifetime growth | Never drop a figure to save space; compact events past the detail window; a first import keeps everything | `Compaction`, `StoreMaintenance` | CompactionTests, StorageTests, StoreMaintenanceTests |
| EC-D8 | Space left by deletion | Reclaim incrementally; a full `VACUUM` only after compacting a quarter or more of the events | `BurnlineDatabase.reclaimSpace`, `Compaction` | ScaleTests, StorageTests, StoreMaintenanceTests |
| EC-D9 | Side files accumulate | WAL cut to 64 MB; three backups; parser errors 90 days; states only for files that exist | connection settings, `DatabaseBackups`, maintenance | DatabaseLifecycleTests, IncrementalIngestionTests, StorageTests |
| EC-D10 | Compacting old history | Lifetime and per-day figures unchanged, cache savings included | rollup delete trigger, `Compaction` | AggregationServiceTests, AggregationTests, CompactionTests |
| EC-D11 | Compacted history read again | An event before the boundary, in a bucket holding compacted history, is refused; never counted twice | `LateHistory` | AggregationTests, CompactionTests, StoreMaintenanceTests |

## Presentation (EC-U)

| ID | Case | Required | Where | Tests |
|---|---|---|---|---|
| EC-U1 | Day with no usage in range | An explicit zero | `UsageSeries` (every bucket present) | AggregationServiceTests, AggregationTests, DashboardTests |
| EC-U2 | Day before tracking began | Distinct from a tracked zero ("Not tracked yet") | `trackingStart`, chart, heatmap, ledger | ActivityPageTests, AggregationServiceTests, DashboardTests |
| EC-U3 | Partial pricing coverage | A headline cost carries its coverage | `UsageTotals.costCoverage`, `CostInfo`, `TodayHeader` | AggregationTests, MenuBarTests |
| EC-U4 | Provider not measurable or disabled mid-range | History kept; series flagged; never drawn at zero | `ProviderPage`, chart | DashboardTests |
| EC-U5 | Brand-new user | Intensity scales derive from the visible range | heatmap | ActivityTests |
| EC-U6 | First launch | Onboarding, not a zeroed dashboard | `DashboardWindow` | AggregationServiceTests, SettingsTests |
| EC-U7 | Very long names | Truncate, with the full value available | table rows, chips, the popover | MenuBarTests |

## Adding one

1. Choose the next number in its group. Identifiers are never reused or
   renumbered, even if a case is retired.
2. Add a row here with the case, the required handling and where it is
   handled.
3. Write the test first, with the identifier in its name, for example
   ``@Test func `EC-I13 a rotated file keeps its offset`()``.
4. If the rule binds every implementation, add it to
   [the contracts](contracts.md) in the same pull request.

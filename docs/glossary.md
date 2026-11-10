# Glossary

Terms used across the code, the documents and the interface. Where the code
has a type for a term, it is named in backticks.

### Active day
A local calendar day with at least one usage event. Used by the heatmap and
the "active days" figure. Looser than a [streak day](#streak-day).

### Adapter
A provider's reader (`UsageProviderAdapter`). It finds the provider's history
files and parses them into `IncomingUsage`. It never writes to the database.

### Banked reset
A consumable that clears a usage window early (`BankedReset`). It is **not**
extra allowance: it does not raise a limit. It sets used capacity back to zero
and is spent doing so. Unused, it expires. A window *resets*; a banked reset
*expires*. Codex reports them as rate-limit reset credits. Claude reports them
as grants, each holding a number of resets.

### Bucket
A span of time a chart or rollup sums over. Rollup buckets are 15 minutes of
UTC (`timestamp / 900`). Chart buckets (`BucketWidth`) are minute, quarter
hour, hour, day, week or month. Hours and longer follow the user's calendar.

### Burn rate
How fast a quota window is filling, in percentage points an hour, and when it
would reach 100% at that pace (`BurnRate`). A projection, never a promise.

### Cache read, cache write
Prompt caching. A *cache read* (`cachedInput`) re-reads earlier context at a
discount. A *cache write* stores context for later reads at a premium.
Anthropic prices a 1-hour write higher than a 5-minute one. Burnline records
the 1-hour part (`cacheWriteOneHour`) as a subset of all cache writes.

### Cache savings
What caching saved: the cache tokens costed as plain input, less what they
actually cost at the event's own cache rates. Writes cost more than input, so
they reduce the saving. Computed per event, never as one discount across
providers. See [pricing](pricing.md#cache-savings).

### Compaction
Deleting events older than the [detail window](#detail-window) while keeping
their 15-minute rollups. Lifetime figures are unchanged; per-event detail goes.
The boundary is `compaction.compacted_before`.

### Confidence
How far to trust a price: `exact`, `reconstructed`, `estimated` or `unknown`
(`PricingConfidence`). It travels with every cost computed from that price.

### Coverage
The share of events in a figure that have a price. A headline cost always
carries its coverage, so an unpriced model never silently lowers a total.

### Cycle token
The identity of one quota window: provider, quota key and window start
(`QuotaSnapshot.cycleToken`). Notification deduplication keys on it rather
than on the reset time, because a banked reset moves the reset time.

### Detail window
How long every event is kept in full (`DetailRetention`): 90 days, 180 days
(the default), a year, or forever. Older history is [compacted](#compaction).

### Edge case (EC-…)
A numbered rule in [the edge-case register](edge-cases.md), such as EC-I2 or
EC-Q1. Tests cite them in their names.

### Equivalent cost
What a workload would cost at the provider's published API prices, at the
prices in force when each request happened. Shown as "equivalent cost" or
"at API prices" because a subscription is not billed per token.

### Event
One model response's token usage (`UsageEvent`, the `usage_events` table). Its
identity is `(provider, source event id)`, which makes re-reading a file safe.

### Freeze
A streak day's cover. Every 7 counted days earn one, two at most. A freeze
covers a day that fell short without adding to the streak.

### Heat
How hard usage is burning right now, from 0 to 1, judged against this person's
own history (`HeatScale`). Measured in equivalent cost an hour.

### Home
A directory a provider's tool keeps its history in. Each provider can have
several: the command-line tool's, and Xcode's coding assistant's
(`ProviderHomes`).

### Live
A provider is live while its last event is under 2 minutes old
(`StatusService.liveWindow`).

### Manifest
A versioned JSON file in `shared/` that Burnline loads as data:
`pricing/pricing.json`, `pricing/model_aliases.json`,
`corpus/comparisons.json`. Each carries a `schemaVersion` that is checked on
load.

### Nanodollars
US dollars times 10⁹, stored as a 64-bit integer (`Nanodollars`). All money in
Burnline is nanodollars. There is no floating point on the cost path.

### Non-model
A value that sits in a model field without being a model, such as
`<synthetic>` or `codex-auto-review`. Shown in breakdowns, never priced,
excluded from model shares.

### Processed tokens
Input plus cache reads plus output. Cache reads are counted. Reasoning is
reported separately and not added, because providers already count it inside
output.

### Quota, window
A provider's usage allowance (`QuotaSnapshot`). A *window* is one allowance
period: a rolling 5-hour window, a weekly window, a model's own weekly window,
or a free plan's monthly window. Each window has a usage percentage and a
reset time.

### Rollup
A precomputed sum. `usage_rollups` holds sums per 15-minute bucket, provider,
model and project. `daily_rollups` holds the same per UTC day. Both are kept by
triggers and never written by application code.

### Source file
A provider's history file (a Claude Code transcript, a Codex rollout). Stored
once in `source_files`; events reference it by id. How far it has been read
is in `source_states`.

### Streak day
A local day with at least an hour of usage, counted in 15-minute stretches
that need not be consecutive. The bar rises a quarter hour every 90 days of a
streak, up to two hours. See
[activity and achievements](activity-and-achievements.md#streaks).

### Tier (service tier)
The billing tier a request ran at (`ServiceTier`): `standard`, `priority`,
`flex`, `ultrafast` or `fast`. Codex's "fast" is OpenAI priority processing.
Claude Code's "fast" is Anthropic's fast mode.

### Tracked provider
A provider the user chose to read, in onboarding or with Add Provider. Burnline
never opens an untracked provider's files or reads its quota.

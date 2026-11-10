# Burnline documentation

Everything about how Burnline works, why it is built the way it is, and how
to change it. Start with the [overview](overview.md), then follow the path for
what you want to do.

## Reading paths

**New here.** [Overview](overview.md) → [Glossary](glossary.md) →
[Architecture](architecture.md) → [Development](development.md).

**Fixing a bug or adding a feature.** [Architecture](architecture.md) →
the page for the area you are touching → [Edge cases](edge-cases.md) →
[Testing](testing.md).

**Adding a provider.** [Providers](providers.md) → [Ingestion](ingestion.md) →
[Adding a provider](adding-a-provider.md).

**Writing another platform's implementation.** [Contracts](contracts.md) →
[Data model](data-model.md) → [Edge cases](edge-cases.md) →
[Pricing](pricing.md) → [Quota](quota.md).

**Checking what Burnline does with your data.**
[Privacy and security](privacy-and-security.md).

## All pages

### Foundations

| Page | What it covers |
|---|---|
| [Overview](overview.md) | What Burnline is, the questions it answers, its principles, and what it is not |
| [Glossary](glossary.md) | Every term the code and these pages use |
| [Architecture](architecture.md) | The system, modules and their dependency rule, concurrency, launch, where state lives, dependencies |
| [Contracts](contracts.md) | **Normative.** The rules every implementation must honour: representation, the canonical event, pricing, identity, quota, storage, privacy, licensing |
| [Decisions](decisions.md) | Locked and open decisions, each with its reason |

### How it works

| Page | What it covers |
|---|---|
| [Data model](data-model.md) | Every table and column, the rollup triggers, opening the database, connection settings, migration history |
| [Providers](providers.md) | Claude Code, Codex and Cursor: their files, records, token arithmetic, quota sources; project and model identity |
| [Ingestion](ingestion.md) | From a provider's files to stored events: triggers, offsets, parsing, writing, failures, first import |
| [Pricing](pricing.md) | Money, price selection, confidence, cache savings, the manifest, the generator and the daily fetch |
| [Quota](quota.md) | Reading limits, reset detection, banked resets, staleness, burn rate |
| [Notifications](notifications.md) | Alert kinds, freshness, deduplication by cycle, milestones |
| [Aggregation](aggregation.md) | Ranges, buckets, the three storage tiers, filters, breakdowns |
| [Data lifecycle](data-lifecycle.md) | Retention, compaction, maintenance, backups and restore, deletion, export, diagnostics |
| [Activity and achievements](activity-and-achievements.md) | Streaks, tiers, the climb, medals, monthly challenges, records |
| [Comparisons](comparisons.md) | The comparison lines, tones, the accuracy rule, the corpus and the engine |
| [Interface](interface.md) | The menu bar, popover, dashboard, Limits, onboarding, Settings, About, design tokens, accessibility |
| [Privacy and security](privacy-and-security.md) | What is read, stored and sent; credentials; permissions; reporting a vulnerability |

### Working on Burnline

| Page | What it covers |
|---|---|
| [Development](development.md) | Setup, commands, running a debug build safely, migrations, settings, prices, the icon, branches, commits |
| [Testing](testing.md) | Principles, layout, fixtures, fitness tests, opt-in and render tests |
| [Edge cases](edge-cases.md) | The register of every edge case, with its handling and its tests |
| [Performance](performance.md) | Budgets, measured figures, and what it took to reach them |
| [Adding a provider](adding-a-provider.md) | A step-by-step guide |
| [Releasing](releasing.md) | Distribution, signing, the release checklist |
| [Updates](updates.md) | In-app updates, the stable and nightly channels, the nightly look, the appcast |
| [Licensing](licensing.md) | The AGPL and its attribution term, obligations in the code, dependencies, third-party material |

## Conventions in these pages

- **Contracts bind; the rest explains.** Where a page and
  [the contracts](contracts.md) disagree, the contracts win, and the page is a
  bug.
- **Edge cases have identifiers** such as EC-I1 or EC-Q3. They appear in the
  code, in test names and in [the register](edge-cases.md).
- **Diagrams are Mermaid**, so they render on GitHub and change with the text.
- **Code names are exact.** A type, file or key named here exists under that
  name. If you find one that does not, the page is out of date: fix it in the
  same pull request as the code.

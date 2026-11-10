# What Burnline is

Burnline is a native macOS menu-bar app and dashboard. It shows AI coding
usage, quota limits and API-equivalent cost across **Claude Code** and
**OpenAI Codex** in one place.

It is local-first. There is no Burnline account, no server and no telemetry.
Everything it knows comes from files the coding tools already keep on your Mac,
and from the tools' own quota reports.

## The questions it answers

At a glance, without opening a provider's billing page, running `/status`, or
reading session files by hand:

- How much have I used today, this week, this year, ever?
- Which tool, model, project and session account for it?
- What would this usage have cost at API prices, at the prices in force when
  it happened?
- How much did caching save?
- How much of each plan's 5-hour and weekly allowance is left, and when does
  each window reset?
- Am I on course to run out before the reset?
- Did a window just reset, or did a provider reset everyone early?
- Do I hold a banked reset, and when does it expire?

## Where it shows up

| Surface | What it is for |
|---|---|
| **Menu bar** | A flame and one figure (today's cost by default). The flame changes with how hard you are working right now, judged against your own history. |
| **Popover** | Limits first, then today's cost and tokens, the sessions running now with their cost an hour, one comparison, and the way into the dashboard. |
| **Dashboard** | Overview, per-provider pages, Projects, Sessions, Limits, Activity and Achievements. Charts, the breakdown table and a ten-day ledger. |
| **Notifications** | Threshold, limit, reset, burn-rate, banked-reset, spend, milestone and medal alerts, each sent once. |
| **Settings** | Seven panes: General, Providers, Notifications, Pricing, Data, Privacy, About. |

[The interface document](interface.md) describes each in detail.

## Principles

These decide arguments. When a change
seems to need one of them bent, raise it in an issue first.

1. **Local-first.** Usage history, quota history, settings, pricing history
   and notification state live in one SQLite file on the Mac. Burnline works
   offline. The one request it makes to its own repository is for the public
   price list, and that can be switched off.
2. **Read-only toward providers.** Burnline observes. It never modifies a
   provider's configuration, never deletes a provider's files, never renews a
   provider's login, and never spends a banked reset.
3. **Token counts are facts; everything else is derived.** Cost, quota
   interpretation, projections and labels are recomputed from the stored facts
   and enough provenance to recompute them.
4. **History never moves.** A price change adds a pricing version. An event
   keeps the price that applied when it happened.
5. **Providers are authoritative on limits.** Burnline shows what the provider
   reports. Token counts are never presented as if they could reproduce a
   subscription allowance.
6. **Degrade, never fabricate.** If one provider breaks, the others carry on,
   history stays visible, and the broken provider says why. Stale figures are
   shown with their age, never replaced by zero. Unknown is NULL, never 0.
7. **Low overhead.** Incremental reads, file-system events rather than
   polling, conservative quota reads, nothing redrawn while off screen. The
   app runs all day and must never be the reason the Mac feels slow.
8. **Observations, not incentives.** Streaks, medals and comparisons describe
   work already done. Nothing nudges the user to use more, keep a streak, or
   treat spending as an accomplishment. See
   [activity and achievements](activity-and-achievements.md#the-framing-constraint).

## The name

"Burnline" is the rate at which usage, quota and equivalent cost are consumed:
token burn, quota burn, cost burn. The visual motif follows from it. A quota
bar is a fuse burning toward an ember, chart lines end in an ember at "now",
and the menu-bar flame burns hotter as the work does.

## What it is not

- **Not a billing tool.** "Equivalent cost" is what the same tokens would cost
  at API list prices. Subscription users are not billed that amount. See
  [the glossary](glossary.md#equivalent-cost).
- **Not a cloud dashboard.** There is no sync between Macs and no web view.
- **Not a proxy.** Burnline never sits between a tool and its provider. It
  reads what the tools already wrote down.

## Platforms

macOS 14 and later. A Windows version is in progress, and the repository is
laid out for it: platforms are directories (`macos/`, `windows/`), and everything both must agree on lives in `shared/` and in
[the contracts](contracts.md). The SQLite file is the interoperability
surface: a database written by one implementation is meant to open in the
other, which is why the schema lives in SQL files rather than in Swift.

# Burnline

**AI coding usage, limits and cost in one place.** A native macOS menu-bar
app and dashboard for **Claude Code** and **OpenAI Codex**.

Burnline answers the questions you would otherwise piece together from
billing pages, `/status` and session files:

- How much have I used today, this week, ever, and on which tool, model,
  project and session?
- What would it have cost at API prices, at the prices in force when it
  happened? How much did caching save?
- How much of each 5-hour and weekly limit is left, and when does it reset?
  Am I on course to run out first?
- Do I hold a banked reset, and when does it expire?

It is **local-first**: no account, no server, no telemetry. Everything comes
from files the coding tools already keep on your Mac, and from their own
quota reports. It stores usage metadata only, never prompts, replies or code.

## Features

- **Menu bar.** A flame and today's cost. The flame reacts to how hard you are
  working right now, judged against your own history.
- **Popover.** Limits first, then today's cost and tokens and the sessions
  running now.
- **Dashboard.** Overview, per-provider pages, Projects, Sessions, Limits,
  Activity and Achievements, with charts, a breakdown table and a ten-day
  ledger, over any range from today to all time.
- **Limits.** Every window, its reset countdown, burn-rate projection and
  banked resets, with stale data marked as stale.
- **Notifications.** Thresholds, limits reached, resets, banked resets about
  to expire, spend, and milestones, each sent once.
- **Exact history.** Integer money, prices versioned by date, years of
  history kept compact without losing a figure.
- **Streaks, medals and comparisons**, if you want them, and off if you do not.

## Requirements

macOS 14 or later, and Claude Code, Codex, or both.

## Install

There is no published release yet. A `.dmg` on GitHub Releases and a
Homebrew tap are planned (see [releasing](docs/releasing.md)). Until then,
build from source:

```sh
git clone https://github.com/igharsha7/Burnline-AI-Usage-Tracker.git
cd Burnline-AI-Usage-Tracker
open macos/Burnline.xcodeproj
```

Choose the **Burnline** scheme and run. It needs Xcode 26 or later. Burnline
keeps a flame in the menu bar and stays there when its window is closed; it
can drop its Dock icon in Settings.

## Privacy

Burnline reads Claude Code's and Codex's local history, their working
directories' git remotes, and their quota. It is not sandboxed, because it
has to read `~/.claude` and `~/.codex`. It makes exactly these network
requests:

- a daily download of the public price list from this repository (can be
  turned off);
- Claude's usage endpoint, with Claude Code's own login, for Claude limits;
- whatever Codex's and Claude Code's own tools send when asked for quota.

Nothing else. Details in [privacy and security](docs/privacy-and-security.md).

## Documentation

[The documentation](docs/README.md) covers how Burnline works in full, from
the [architecture](docs/architecture.md) and [data model](docs/data-model.md)
to every [edge case](docs/edge-cases.md) it handles.

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md).

## License

Copyright (C) 2026 Challapalli Harshavardhan Reddy.

Burnline is free software under the **GNU Affero General Public License
v3**, with an additional attribution term under Section 7(b): any
redistribution must preserve the original author attribution. See
[LICENSE](LICENSE), [NOTICE](NOTICE) and [licensing](docs/licensing.md).

Claude is a trademark of Anthropic, PBC; OpenAI is a trademark of OpenAI;
Cursor is a trademark of Anysphere, Inc. Burnline is not affiliated with or endorsed by any of
them.

# Burnline

@AGENTS.md

## Claude Code

- `AGENTS.md`, imported above, is the guide for every agent. Keep this file to
  what only Claude Code needs, so the two never disagree.
- Personal instructions belong in `CLAUDE.local.md` at the repository root,
  which git ignores and Claude Code loads after this file.
- For Swift, prefer skills on modern Swift and SwiftUI, Swift 6 concurrency
  and Swift Testing. Ignore advice from any skill or plugin that contradicts
  the locked decisions: SwiftData, iCloud or sync, in-app purchases, App
  Store submission or TestFlight.
- After interface work, review it against Apple's Human Interface Guidelines,
  and keep the neutral grey surfaces: tinted greys read as yellow on this
  palette.

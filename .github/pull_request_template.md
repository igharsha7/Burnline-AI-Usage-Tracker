<!--
Thank you for contributing. Fill in every section; write "None" or "N/A"
rather than deleting one. CONTRIBUTING.md explains each:
https://github.com/igharsha7/Burnline-AI-Usage-Tracker/blob/main/CONTRIBUTING.md

Title: a short, sentence-case description of the change, no prefix.
-->

## Problem

<!-- What is wrong or missing, and who notices. Link the issue. For a feature
or behaviour change, link the maintainer's approval of direction and scope. -->

Closes #

## Solution

<!-- How this change solves it, and why this approach. Note anything a
reviewer should look at first. One problem per pull request. -->

## Type

<!-- Tick one. -->

- [ ] Bug fix
- [ ] Feature or behaviour change (approved in the linked issue)
- [ ] Performance
- [ ] Tests only
- [ ] Documentation only
- [ ] Pricing, aliases or comparison data
- [ ] Build, CI or tooling

## Evidence

<!-- How you reproduced the problem, what you ran, and what you observed.
"Tests pass" alone is not evidence that the change works. -->

- [ ] `swift test --package-path macos/Packages` passes locally
- [ ] `macos/scripts/check-license-headers.sh` passes
- [ ] New or changed behaviour has tests (a bug fix has a test that failed before the fix)

**Tests added or changed:**

## Not covered by tests

<!-- Required. List any behaviour this change adds or alters that the test
suite does not check (a view's layout, an animation, a real provider's
response, a new feature without tests yet), why it can't be tested, and how
you checked it by hand. Write "None: every change is covered by tests" only
if that is true. -->

## Performance

<!-- Required if the change touches ingestion, aggregation, a page's load,
the menu bar, the popover or anything that runs while idle. Give before and
after figures (timing tests, Activity Monitor or Instruments: CPU, memory,
wakeups). Otherwise write "N/A". -->

## Screenshots

<!-- For any visual change: before and after, from a scratch store with no
real usage data. Add a short recording for motion. Otherwise "N/A". -->

## Release note

<!-- One sentence a user would understand, for a user-visible change.
Otherwise "N/A". -->

## AI assistance

<!-- Required. Name every model and tool that wrote or changed code in this
pull request, e.g. "Claude Opus 5.5 in Claude Code", "GPT-6.1 in Codex".
Write "None" if no AI wrote code. -->

Model and tool:

## Checklist

- [ ] Follows [the contracts](https://github.com/igharsha7/Burnline-AI-Usage-Tracker/blob/main/docs/contracts.md): integer money, UTC time, append-only prices, schema in SQL
- [ ] Stores, logs and shows no prompt, code, credential or real usage data
- [ ] No released migration or recorded price version was edited
- [ ] No new dependency, or it was approved and is AGPL-compatible
- [ ] Docs updated where behaviour, names or rules changed
- [ ] Branches from and targets `main`

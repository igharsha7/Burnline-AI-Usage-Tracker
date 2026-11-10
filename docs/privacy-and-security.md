# Privacy and security

What Burnline reads, stores, sends and never touches. These rules are part of
[the contracts](contracts.md#11-privacy-and-security) and bind every change.

## What is read

| Source | What Burnline takes from it |
|---|---|
| Claude Code transcripts | Per reply: message id, model, time, session id, working directory, token counts, service tier, format version |
| Codex rollouts | Per response: response id, thread and session ids, model, time, working directory, token counts, service tier, Codex version; rate limits, for the quota fallback |
| `.git` in a working directory | The repository root and its `origin` remote |
| Codex's app-server | Rate limits and banked resets |
| Claude's usage endpoint, or Claude Code | Plan limits and banked resets |
| Claude Code's login (Keychain or `.credentials.json`) | The access token for one request, and the plan name |

Adapters skip lines that do not hold usage before decoding them, and decode
only the fields above. **Message content never becomes a Swift value**, let
alone a stored one.

## What is stored

In `~/Library/Application Support/Burnline/burnline.sqlite`:

- token counts, times, models, service tiers and costs;
- sessions (the provider's id and their span);
- projects (a normalised git remote such as `github.com/owner/repo`, or a
  SHA-256 of a path; a derived name; the last path seen);
- source file paths and how far each has been read;
- quota snapshots, banked resets and notifications sent;
- achievements;
- parser errors, as a reason and a line number.

## What is never stored

- **Prompts, replies, source code, terminal contents or transcript text.**
- **The offending line of a parser error.** It may hold prompt text or code;
  only a reason that names the field is kept.
- **Credentials**: not in the database, preferences, logs or crash reports.
- **Credentials in remotes.** A remote's `user:token@` is dropped before it is
  normalised.

## Network

Burnline makes exactly these requests, and no others:

| Request | Made by | Carries | Can be turned off |
|---|---|---|---|
| `GET raw.githubusercontent.com/igharsha7/Burnline-AI-Usage-Tracker/pricing-data/shared/pricing/pricing.json`, at most daily | Burnline | Nothing beyond the URL: an ephemeral session with no cookies, cache or credentials | Settings → Pricing |
| `GET api.anthropic.com/api/oauth/usage?cedar_ember=1` | Burnline | Claude Code's access token, and a `User-Agent` naming Burnline | Only Claude quota needs it; untracking Claude Code stops it |
| Codex's rate-limit request | `codex app-server`, with its own login | Whatever Codex sends | Untracking Codex stops it |
| Claude's usage request | `claude -p`, with its own login | Whatever Claude Code sends | Used only as the fallback |

- **No telemetry.** No analytics, crash reporting or update check. Any future
  telemetry must be explicit opt-in and never include usage figures, project
  paths, prompts or token counts.
- **Never posing.** The one request carrying a provider's token names itself
  as Burnline, with the source link, never as the provider's tool.
- **Offline is normal.** Without a network, history, charts and costs all work
  from local files and the bundled prices. Quota shows its last figures, marked
  stale with their age.

## Credentials

Only one credential ever passes through Burnline's memory: Claude Code's
access token, for the usage endpoint.

- Read at the point of use, for one request, then dropped.
- Held as a `SecretString`, which prints as `<redacted>` through
  `description`, `debugDescription`, string interpolation and `dump`, is not
  `Codable` so it cannot be written to the database or a log by mistake, and
  zeroes its bytes when released. Zeroing is best effort: the source it was
  read from, and any `String` built inside `withValue`, are outside its control.
- The refresh token is never decoded.
- **Never renewed.** Renewing would write to Claude Code's login. An expired
  token is reported, and Claude Code renews it the next time it runs.
- The first read shows macOS's Keychain prompt. Declining stops Burnline asking
  for the rest of the session; quota then comes through Claude Code itself.
- Codex's login is never seen: Codex's app-server makes its own request.
- A test sends a sentinel token through a full refresh and checks that neither
  the database files nor any printed state contain it.

## Logs and errors

- Unified logging (`Logger`, subsystem `io.github.igharsha7.Burnline`), with
  privacy-aware fields.
- Never logged: credentials, cookies, prompt content, source code.
- Quota errors are matched against fixed reasons and the provider's text is
  dropped, since it may echo a request or a response.
- A child process's standard error is discarded.
- **Copy Diagnostics** holds counts, versions and health, but no token or
  cost figure, no project, session or model name, and no credential. Any path
  in it has the home folder written as `~`. See
  [data lifecycle](data-lifecycle.md#diagnostics).

## Toward providers: read-only

- Burnline never modifies a provider's configuration or files, and never
  deletes them. Deleting history in Burnline deletes only Burnline's copy.
- It never renews a provider's login and never spends a banked reset.
- Claude Code, when started for quota, runs inertly: no session saved, hooks
  off, no tools, no MCP servers, no model turn.
- Untracked providers are never read: neither their files nor their quota.

## Sandbox and permissions

**Burnline is not sandboxed.** It reads `~/.claude`, `~/.codex` and Xcode's coding
assistant homes. A sandbox
would force a folder picker and security-scoped bookmark per provider, and
first-run detection would no longer work. Onboarding instead shows per-provider
detection and says plainly that Burnline reads usage metadata only.

Permissions it may ask for:

| Permission | When | Why |
|---|---|---|
| Keychain access to "Claude Code-credentials" | The first Claude quota read | The usage endpoint needs Claude Code's token |
| Notifications | In onboarding, on Send Test, or before the first alert there is to show | Alerts |
| Login item | When the user turns on Open at login | Launch at login |

## Reporting a vulnerability

Report security issues privately, never in a public issue: through GitHub's
private vulnerability reporting, or to the contact address in `NOTICE`.
[SECURITY.md](../SECURITY.md) says what to include and what is in scope.

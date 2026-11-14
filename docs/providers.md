# Providers

What each supported tool keeps on the Mac, how Burnline reads its usage and
its quota, and the quirks found in real files. Every fact here was measured on
real data; when a provider changes its format, this page and the adapter's
tests change together.

| Provider | Usage history | Quota | Banked resets |
|---|---|---|---|
| Claude Code | Read from transcripts | Claude's usage endpoint, or Claude Code itself | From the usage endpoint only |
| Codex | Read from rollouts, compressed or not | Codex's app-server, or rollout files | From the app-server only |

The interface every adapter implements, and how to add a provider, are in
[adding a provider](adding-a-provider.md).

## Homes

A provider's tool can keep history in more than one place
(`ProviderHomes`). The command-line tools and their VS Code, Cursor and
desktop front ends share one home per provider, but **Xcode's coding
assistant runs its own copies** of Claude Code and Codex with separate homes.
A lifetime total has to read them all.

| Provider | Homes, in order |
|---|---|
| Claude Code | `$CLAUDE_CONFIG_DIR` or `~/.claude`, then `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig` |
| Codex | `$CODEX_HOME` or `~/.codex`, then `~/Library/Developer/Xcode/CodingAssistant/codex` |

Only homes that exist are read and watched. Events carry the provider's own
ids, so an event seen from two homes is stored once.

## Claude Code

### Files
- `<home>/projects/<project>/<session>.jsonl`, one transcript per session.
- `<home>/projects/<project>/<session>/subagents/*.jsonl`, subagent
  transcripts. They carry their parent's session id, so a subagent's usage
  counts toward its parent session.
- Claude Code deletes transcripts after `cleanupPeriodDays` (30 by default).

### Records
Token counts sit on the `usage` object of `assistant` lines. Burnline decodes
only the fields it needs: the message id, model, timestamp, session id,
working directory, the usage counts, the service tier and the format version.

| Usage field | Burnline field |
|---|---|
| `input_tokens` | input (already uncached) |
| `cache_read_input_tokens` | cached input |
| `cache_creation_input_tokens` | cache write |
| `cache_creation.ephemeral_1h_input_tokens` | 1-hour cache write |
| `output_tokens` | output |
| `output_tokens_details.thinking_tokens` | reasoning (already inside output) |
| `service_tier` (`fast` = Anthropic fast mode) | service tier |

### Quirks
- **One API response is several lines.** Claude Code writes one line per
  content block, each repeating the same `message.id` and usage. The message
  id is therefore the event id. Counting lines would roughly double the totals.
- **Repeated lines are streaming snapshots.** A later one can report more
  output, so storage keeps the most complete copy.
- **A reply can span a quarter-hour boundary**, since each line has its own
  time. Late-history checks judge a reply by every line sharing its id (see
  [ingestion](ingestion.md#writing)).
- Lines without the `"assistant"` marker are skipped before decoding.
- Every line stands alone, so no resume state is needed.

### Quota
Claude's plan limits: the rolling 5-hour window, the weekly window, and a
model's own weekly window where the plan has one (`seven_day_opus` and the
like). Every figure is **account-wide**, across every device and app, and is
labelled so.

1. **Preferred: Claude's usage endpoint** (`ClaudeUsageEndpointReader`). One
   HTTPS GET to `https://api.anthropic.com/api/oauth/usage?cedar_ember=1`,
   the same endpoint Claude Code uses, with Claude Code's own login. It is the
   only source of Claude's banked resets: `cedar_ember` grants, each holding a
   number of resets until it ends. A grant clears Claude's windows as a whole,
   recorded with the quota key `claude`.
2. **Fallback: Claude Code itself** (`ClaudeCodeUsageReader`). Burnline starts
   `claude -p` in stream-json mode and sends the `get_usage` control request.
   Claude Code uses and renews its own login. This source cannot see banked
   resets. Anthropic marks `get_usage` experimental, which is why it is the
   fallback.

**The login.** `KeychainClaudeCredentials` reads the `Claude Code-credentials`
Keychain item, or the `.credentials.json` Claude Code writes where it keeps no
Keychain item, for one request, into a `SecretString`, and drops it. The same
read gives the plan (`subscriptionType`, such as `max` or `pro`), which the
endpoint does not report. The refresh token is never decoded into memory.

- Whether it may be read, and how the last read went, is a
  `ClaudeLoginAccess` the app builds from the **Read Claude Code's login**
  setting and shares with Settings and the Limits page.
- Only the first read on a Mac, or one the user asked for with **Allow…**, may
  show macOS's Keychain prompt. Every other read runs with Keychain
  interaction turned off (`SecKeychainSetUserInteractionAllowed`, process
  wide, so under a lock), and a read macOS would have asked about fails at
  once as needing permission; the fallback is used. This matters because
  Claude Code rewrites its Keychain item each time it renews its login, which
  makes macOS forget the approval every few hours, and a self-signed build
  loses it at each update too; see [privacy and security](privacy-and-security.md).
- Declining the prompt is remembered for the session, so the interface says
  so rather than asking for permission again.
- **An expired token is never renewed.** Renewing would write to Claude Code's
  login, and Burnline is read-only toward providers. The expiry is reported,
  the fallback is used, and Claude Code renews the login next time it runs
  (EC-Q4).
- The request goes through an ephemeral `URLSession` with no cache, cookies or
  credential store, and names itself `Burnline (+https://github.com/igharsha7/Burnline-AI-Usage-Tracker)`
  rather than posing as Claude Code.

**Starting Claude Code inertly.** For the fallback, Claude Code runs with
`--no-session-persistence`, hooks turned off through `--settings`, no tools,
an empty strict MCP configuration, the temporary directory as its working
directory, and only control requests on standard input. No model turn runs and
no session is saved.

## Codex

### Files
- `<home>/sessions/YYYY/MM/DD/rollout-*.jsonl`, one file per thread.
- `<home>/archived_sessions/`, where Codex moves old threads.
- **Codex compresses older threads to `.jsonl.zst` in place**, in both
  directories. On the author's machine 155 of 182 files were compressed,
  holding four-fifths of the lifetime events. macOS has no zstd decoder, so
  Burnline links zstd (`ZstdStream`) and streams archives a chunk at a time,
  reading concatenated frames as one stream as the `zstd` tool does. A damaged
  archive is an unreadable file, not an empty one.

### Records

| Record | What it is |
|---|---|
| `session_meta` | Opens the file: thread id, session, working directory, and the model the base instructions were chosen for. A forked subagent's file repeats its parent's meta after its own, so **the first one wins**, and its records name the parent session. |
| `turn_context` | Starts each turn and names the model. Token records carry no model, so the latest turn's model applies. |
| `token_usage_record` | **The event.** One per model response, keyed by its `response_id`. |
| `event_msg` / `token_count` | Follows most responses with the same usage and a running thread total. **Skipped wherever records exist**, or every response would count twice. |
| `thread_settings_applied` | Names the service tier, which pricing needs. |

`token_usage_record` is also the more complete source: compaction responses
get a record but no `token_count`. On real data that is about 1.3% more
tokens.

**Token arithmetic.** OpenAI reports the whole prompt as `input_tokens`, with
cache reads and cache writes as parts of it. A Codex event's input is
`input_tokens − cached_input_tokens − cache_write_input_tokens`. A cached part
larger than the whole is recorded as a parser error and input counted as zero.
Reasoning tokens are part of output and reported beside it.

**Older files.** Older Codex versions, and a few short threads, write
`token_count` and no records at all. There, `token_count` is the event, keyed
by thread, timestamp and running total, with three cautions learned from real
files:

- a line whose running total did not move is a re-emission, not a request;
- a line with no input and no output reports context size, not usage;
- a forked thread opens by copying its parent's history in a burst of lines
  under a second apart, which the parent already counted.

The timestamp in the key keeps a session resumed in a new process, whose
running total restarts, from colliding with its own earlier requests.

**Model before any turn.** Some short threads have no `turn_context`. Their
`session_meta` still names the model its base instructions were chosen for,
which stands in until a turn says otherwise.

**Resume state.** Model, directory, thread, session, Codex version and whether
the file has token records are set once and used many lines later, so a pass
that resumes mid-file is given `CodexResumeState` from the pass before it.

### Quota
Codex's rate limits. Windows are named by what they measure, not by position:
the protocol's `primary` and `secondary` are positions, so a window's duration
decides what it is. Without a duration, paid plans use 5-hour and weekly
windows and free plans a monthly one, but **not every paid plan has a 5-hour
window**: Pro has only the weekly one, so a primary window that resets more
than five hours from now is taken as weekly. A limit other than the main
`codex` one, such as a model's own, is kept apart under its id (for example
`<id>.five_hour`). A spend-control limit set on the account is reported as what
remains.

1. **Preferred: Codex's app-server** (`CodexAppServerReader`). Burnline starts
   `codex app-server`, completes the `initialize` handshake, and sends
   `account/rateLimits/read`. Codex makes the authenticated request with its
   own login; **Burnline never sees that login**. It is the only source of
   Codex's banked resets, `rateLimitResetCredits`, each with an id, grant time,
   expiry, type and status. A credit of type `codexRateLimits` clears the main
   Codex limit's windows (quota key `codex`). One marked `redeeming` is still
   held: it is spent only once Codex says so.
2. **Fallback: rollout files** (`CodexRolloutQuotaReader`). Codex writes its
   rate limits into session files with each token count. Burnline checks up to
   the five newest files by modification time and takes the reading with the
   newest observation time, so touching an old file cannot make its quota look
   fresh. Free and offline, but only as current as the last Codex session, and
   blind to banked resets.

Multi-limit responses use their dictionary keys when a snapshot omits its limit
id, keeping model limits apart. Durations that are not positive, or overflow
seconds, are ignored.

## Running the providers' tools

Quota readers start the provider's command-line tool as a child process and
speak to it one line of JSON at a time (`LineProcess`).

- **Finding the tool.** An app opened from the Dock inherits only the system's
  `PATH`, so `ExecutableLocator` looks on `PATH`, in the usual install locations,
  and in tool-specific extra places. The tool runs with the user's environment
  plus its own directory and those locations on `PATH`, since a tool may start
  helpers by name.
- **Standard error is discarded.** It can carry anything the tool chooses to
  print, and none of it is needed.
- **Every read ends the process.** When done or timed out, its input is closed
  and it is asked to stop. Two seconds later it is killed, **with its process
  group**, so a helper that ignores SIGTERM cannot keep standard output open
  after the tool has exited. Writes to a pipe suppress SIGPIPE and report an
  error if the tool has gone.
- **Errors are matched, never passed on.** A tool's error text may echo a
  request or a response, so readers map it to a fixed reason (`QuotaReadError`)
  and drop the text.

## Project identity

`ProjectIdentityResolver` turns a working directory into a project by reading
`.git` directly rather than running `git`, since an import resolves thousands
of records. Results are cached per directory within a sync.

1. The directory is normalised: absolute, `.` and `..` removed, symlinks
   resolved where the path still exists, so `/tmp/x` and `/private/tmp/x`
   agree.
2. It walks up to the nearest `.git`. Directories that no longer exist are
   walked too, so a deleted subdirectory of a repository that still exists
   resolves to that repository.
3. A `.git` **file** points elsewhere (`gitdir: <path>`, absolute or relative
   to that directory). A linked worktree's git directory has a `commondir`
   leading back to the main repository, so every worktree is one project
   (EC-P4). A submodule's does not, and it is a project of its own.
4. The remote is `origin`'s URL from the git config, or the first remote's.
   `GitRemote` normalises it to `host/owner/repo` (EC-P8):

   ```
   git@github.com:owner/repo.git                  → github.com/owner/repo
   ssh://git@github.com:22/owner/repo             → github.com/owner/repo
   https://user:token@github.com/owner/repo.git/  → github.com/owner/repo
   ```

   Credentials are dropped, never stored. A local path or `file://` remote
   counts as no remote: it names a directory, no more stable than the
   repository's own path. The repository's name keeps the case its remote
   gives it.
5. With no remote, the identity is the SHA-256 of the repository root
   (EC-P2). Outside any repository, the SHA-256 of the directory (EC-P6).

A monorepo is one project at its root, since its packages have no `.git` of
their own (EC-P5). Two clones of one repository share a remote and are one
project (EC-P3).

**Display names.** A project's derived name is made readable
(`ProjectName.readable`): `Burnline-AI-Usage-Tracker` becomes "Burnline AI
Usage Tracker", `crop_recommendation` "Crop Recommendation". Hyphens between
digits stay, so a date reads as one. A name with a space was written as prose
and is kept. A name the user gives is shown exactly as typed.

## Model identity

`ModelRepository` resolves a raw model string inside the batch's transaction:

1. **Plain form**: lowercased, trimmed, a routing prefix (`anthropic/`)
   removed, and a bracketed variant (`[1m]`, Claude's long-context selector)
   removed, since it is the same model priced by prompt length. So
   `anthropic/Claude-Opus-5[1m]` and `claude-opus-5` are one model.
2. **A value in angle brackets** (`<synthetic>`) is a non-model even before
   the manifest names it (EC-M1).
3. **An alias valid at the event's time** (EC-M2, EC-M4).
4. **The canonical name** itself.
5. **Otherwise a new model**, unpriced, kept visible (EC-M3).

`shared/pricing/model_aliases.json` is synced into `models` and
`model_aliases` at every launch. It adds and updates, and never deletes, since
events point at those rows. Its format:

```json
{
  "schemaVersion": 1,
  "providers": {
    "claude_code": {
      "models": [
        { "canonical": "claude-haiku-4-5", "display": "Claude Haiku 4.5", "family": "haiku",
          "aliases": [ { "raw": "claude-haiku-4-5-20251001" } ] }
      ],
      "nonModels": ["<synthetic>"]
    }
  }
}
```

An alias may carry `validFrom` and `validUntil` (ISO 8601). A newer schema
version is refused. Settings → Data → Repair can re-apply the manifest to
stored events, for names it learned after they arrived, and re-price the
events that moved.

## Future providers

OpenCode and Antigravity are candidates once their local data has been
inspected. A new provider is an adapter, a quota reader if it has quota, a
`ProviderKey` case (its database row is seeded automatically), entries in the
manifests, and the per-provider details the compiler then points to: colour,
logo and labels. Nothing in storage, aggregation or the pages should change.
See
[adding a provider](adding-a-provider.md).

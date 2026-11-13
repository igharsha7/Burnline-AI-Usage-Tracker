# Security policy

Burnline reads AI coding tools' local files and, to read plan limits, a
login those tools keep. A flaw in how it does that matters, so please report
one privately.

## Reporting a vulnerability

**Do not open a public issue, discussion or pull request for a security
problem.**

- **Preferred:** [report it privately on GitHub](https://github.com/igharsha7/Burnline-AI-Usage-Tracker/security/advisories/new)
  (the repository's **Security** tab → **Report a vulnerability**).
- **Otherwise:** email the contact address in [NOTICE](NOTICE).

Please include what you found, the Burnline version or commit, your macOS
version, and the steps to reproduce it. A proof of concept helps; real
credentials, tokens or someone's usage data do not belong in a report.

Burnline is maintained by volunteers. You will get a reply once the report
has been read, and be kept informed while it is fixed. Unless you would rather
not be named, you will be credited in the advisory and the release notes.

## What is in scope

- A credential (Claude Code's login, any token) being stored, logged,
  printed, exported, or sent anywhere other than the request it is read for.
- Prompts, responses, code or file contents reaching the database, logs,
  errors or exports.
- Burnline writing to, moving or deleting a provider's files, or reading
  files outside the provider homes it documents.
- A network request carrying anything beyond what
  [privacy and security](docs/privacy-and-security.md#network) lists.
- A malicious pricing manifest, backup or provider file that can make
  Burnline run code, corrupt or delete its database, or rewrite recorded
  history.
- Anything that lets another local process or user act through Burnline.

## What is not

- The macOS warning on first launch. Burnline is distributed un-notarized by
  choice (see [releasing](docs/releasing.md)).
- Attacks that already need the same user account's full access, such as
  editing Burnline's database directly.
- Vulnerabilities in Claude Code, Codex or other tools themselves. Report
  those to their makers.

## Supported versions

Security fixes go into the latest release only. Update from within
Burnline, or download the latest release, to get them.

# Adding a provider

How to teach Burnline a new AI coding tool, such as OpenCode or
Antigravity. The design keeps provider-specific knowledge inside one adapter
and one quota reader, so nothing else in the app should need to understand
the new tool's files.

Read [providers](providers.md) first for how the two existing adapters work,
and [ingestion](ingestion.md) for what happens to their output.

## Before writing code

Open an issue first with what you found. A provider is worth adding only if
Burnline can measure it honestly:

1. **Inspect what the tool writes locally.** Copy its files somewhere scratch
   before looking; never inspect a provider's files in place (see
   [privacy and security](privacy-and-security.md#toward-providers-read-only)).
2. **Check that token counts exist** per request or per response, with a
   stable id, a timestamp and a model. Without them there is nothing to
   count.
3. **Find how quota is exposed**, if at all: a local file, the tool's own
   command, or an endpoint. Burnline never scrapes a credential it did not
   issue without an explicit decision.
4. **Check pricing.** Its models need prices in LiteLLM (or a manual source)
   and entries in the alias manifest.

A provider Burnline does not read is **absent**, never shown as zero.

## Steps

### 1. The provider key

Add a case to `ProviderKey` (`BurnlineCore/Models/ProviderKey.swift`), with
its raw value (the `providers.key` column, `snake_case`) and `displayName`.
Add it to `ProviderKey.trackable` only when it can really be tracked.

The database seeds a `providers` row for every case on open, so no migration
is needed. The compiler then lists every exhaustive `switch` that needs the
new case: the accent colour and line pattern in `Palette`, the logo in
`ProviderLogo`, the menu-bar letter in `MenuBarTitle`, the company that resets
its usage in `Alerts`, and the setup text in `ProviderSetup`.

### 2. The adapter

Create `BurnlineProviders/<Name>/<Name>Adapter.swift`, a type conforming to
`UsageProviderAdapter`:

```swift
public protocol UsageProviderAdapter: Sendable {
    var provider: ProviderKey { get }
    func prepareForSync()                      // optional
    func detect() -> ProviderDetection
    func watchedDirectories() -> [URL]         // optional; defaults to the detected directory
    func sourceFiles() throws -> [URL]
    func parse(_ file: URL, from offset: Int64, state: String?) throws -> ParseOutput
}
```

| Member | Rules |
|---|---|
| `detect()` | `.installed(dataDirectory:)`, `.notInstalled`, or `.unavailable(reason:)` with a reason fit to show. Not being installed is a state, never an error (EC-I11). |
| Homes | Honour the tool's own environment variable for its home, as `ProviderHomes` does for `CLAUDE_CONFIG_DIR` and `CODEX_HOME`, and any second home (such as Xcode's coding assistant). |
| `sourceFiles()` | Every history file, in a stable order |
| `parse` | Read from `offset` to the last **complete** line. Never advance past a final line without its newline (EC-I2). Use `LineReader` (and `ZstdStream` for compressed files) so files stream rather than load whole (EC-I12). |
| `state` | Opaque resume state, for formats where a record depends on earlier lines (as Codex's does). If you need state and are given none, start the file over: that costs time but never counts twice. |

Each record becomes an `IncomingUsage`:

- `sourceEventID`: the provider's own id for the request or response. The
  database deduplicates on provider + this id (EC-I4), so it must be stable
  across rereads.
- `sessionSourceID`: the provider's session id, or one synthesised from the
  file; never drop an event for lacking one (EC-I7).
- `project`: from the working directory, through the shared
  `ProjectIdentityResolver`; nil when there is none (EC-I6).
- `rawModel` exactly as written; resolution happens in the store.
- `tokens` as `TokenCounts`. Map the provider's fields carefully: whether
  cached input is included in input or separate, and whether reasoning tokens
  are part of output, differ between providers. Write the arithmetic down in
  [providers](providers.md).
- `serviceTier`, `sourceType` (a constant such as `opencode_jsonl`), `file`,
  `schemaVersion` (the tool's format version, when it writes one), `offset`.

**Decode only the fields you need.** Skip lines that cannot hold usage
before decoding them, so message content never becomes a Swift value. A
malformed line becomes a `ParseIssue` with a reason naming the field, never
the line itself (EC-I1). An absent or negative count is zero plus an issue
(EC-I8).

Register the adapter in `LiveIngestion`, in the `adapters` list given to the
`Reconciler`.

### 3. Quota, if the tool has any

Create a reader conforming to `QuotaReader`:

```swift
public protocol QuotaReader: Sendable {
    var provider: ProviderKey { get }
    func read() async throws(QuotaReadError) -> QuotaReading
}
```

- Throw a `QuotaReadError` matched to a fixed reason; never pass the
  provider's error text through, since it may echo a request.
- If there is more than one source, wrap them in a `FallbackQuotaReader`,
  preferred source first, and register it in the `QuotaActor`'s readers in
  `LiveIngestion`.
- If you start the provider's tool, use `ExecutableLocator` to find it and a
  `ProcessLauncher` (`SystemProcessLauncher` in the app, a fake in tests) to
  run it, as the existing readers do, so a hung child is killed
  with its process group, and run it inertly: no session saved, no hooks, no
  model turn.
- Label account-wide usage as such (EC-Q5).

### 4. Models and prices

- Add the provider and its models to `shared/pricing/model_aliases.json`:
  canonical names, display names, families, and aliases for dated or renamed
  ids (EC-M2, EC-M4).
- Map LiteLLM's provider name to the new key in `PROVIDERS` in
  `shared/pricing/tools/update_pricing.py`, and its model prefixes in
  `MODEL_PREFIXES`, with a test in `test_update_pricing.py`.
- Run the generator to append the new prices. Never edit existing versions.

### 5. Interface

- A logo in `BurnlineUI/ProviderLogos` under a license that permits it, with
  the trademark line added to `NOTICE`.
- An accent colour and a line pattern in `Palette`, distinguishable from the
  others for colour-blind users. Check it in the popover, the charts and the
  Limits page.
- Setup text in `ProviderSetup` saying where its history and limits come from.

### 6. Tests

In `BurnlineProvidersTests`, a `<Name>ParserTests` suite with small,
anonymised fixture files written through `TestDirectory`, covering at least:

- a normal record, with its token arithmetic checked field by field;
- every EC-I case that applies: malformed line, truncated final line, a file
  that shrank, the same event in two files, unknown fields, missing project,
  missing session, absent or negative counts, not installed;
- an older format version, if the tool has changed its format;
- resumption from an offset (and from saved state, if used) giving the same
  records as a full read.

And for quota, recorded responses for every outcome in `QuotaReaderTests`.
Name each test with its edge-case identifier (see [testing](testing.md)).

### 7. Documentation

- A section in [providers](providers.md): files, record fields, token
  arithmetic, quirks, quota.
- The provider in [privacy and security](privacy-and-security.md): what is
  read, and any request made.
- Any new edge case in [the register](edge-cases.md).

## Checklist

- [ ] An issue with what the tool writes and how quota is exposed
- [ ] `ProviderKey` case, and every switch the compiler flags
- [ ] Adapter, registered in `LiveIngestion`
- [ ] Quota reader, registered, if any
- [ ] Aliases and pricing generator mapping
- [ ] Logo, accent, setup text, `NOTICE`
- [ ] Parser and quota tests citing edge cases
- [ ] Docs updated
- [ ] `swift test --package-path macos/Packages` and the license-header check pass
- [ ] Optional: `BURNLINE_REAL_HISTORY=1` against your own history, counts only

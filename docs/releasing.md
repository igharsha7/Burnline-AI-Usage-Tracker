# Releasing

How a Burnline release is made and distributed.

> **Status.** No release has been published yet; Burnline is built from
> source today. This page is the plan the first release follows, and the
> checklist every later one reuses. Steps marked *(to build)* do not exist
> yet.

## Distribution

| Route | For | Gatekeeper |
|---|---|---|
| **`.dmg` on GitHub Releases** | Everyone: open it and drag Burnline to Applications | Blocked on first open until allowed in System Settings, once |
| **Homebrew tap** *(to build)* | People who use Homebrew | The same first-open step, unless the cask can clear the quarantine flag itself (to test). Homebrew 5.0 removed `--no-quarantine`. |
| **Build from source** | Contributors | None |

Without notarization, which needs the paid Apple Developer Program, no route
avoids the first-open step for a download: macOS shows it for any
un-notarized app, whichever browser or tool fetched it. It is needed once.
In-app updates are not quarantined, so they do not ask again.

Not distributed through the Mac App Store: GPL-family terms conflict with its
terms, and notarization needs the paid Apple Developer Program, which the
project does not use. See [decisions](decisions.md) and
[licensing](licensing.md#distribution-consequences).

## Versions

Burnline uses semantic versions, `MAJOR.MINOR.PATCH`:

- **Minor** for new capability, such as a new provider. OpenCode and
  Antigravity arrive in `0.2.0`.
- **Patch** for fixes and polish.
- **Major** stays `0` for now.

- `MARKETING_VERSION` in the app target is the user-facing version. It starts
  at `0.1.0`.
- `CURRENT_PROJECT_VERSION` is the build number. It rises with every
  published build, so macOS and Homebrew see an update as newer.
- Each release corresponds to a staging branch: `staging-build-vN` is merged
  into `main` by pull request, and the release is tagged on `main`. See
  [development](development.md#branches).

## Channels

| Channel | Built from | Version | For |
|---|---|---|---|
| **Stable** | A release tag `vX.Y.Z` on `main` | `0.1.0` | Everyone, by default |
| **Nightly** | The `nightly` branch, each night it changed | The next version with a pre-release suffix, such as `0.2.0-nightly.20261111` | People who want the newest work and accept rough edges |

- Both are GitHub Releases: each stable version its own release, nightly one
  rolling pre-release.
- The in-app updater follows the channel chosen in Settings; build numbers
  rise across both channels, so moving between them always compares correctly.
  How it works, and how a nightly looks, is in [updates](updates.md).
- **Nightly can carry migrations no stable release has yet.** A database a
  nightly build has migrated is refused by an older stable build as newer than
  it supports, so going back from nightly to stable means restoring a backup
  taken before. Settings says so before switching.

## Signing

Builds are currently ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`). That is fine
for development and wrong for a release: an ad-hoc signature changes with
every build, so macOS treats each update as a different app, and permissions
granted to the previous one (such as Keychain access to Claude Code's login)
are asked for again.

A release is signed with a **stable self-signed identity** *(to build)*: one
certificate, kept by the maintainer and reused for every release, so the
signature stays the same from one version to the next.

## Checklist

1. **Refresh the bundled prices.** Copy `shared/pricing/pricing.json` from the
   `pricing-data` branch into the release branch, so a user offline on first
   launch still has current prices:

   ```sh
   git fetch origin pricing-data
   git checkout origin/pricing-data -- shared/pricing/pricing.json
   ```

   The file only ever grows; check that the diff adds versions and changes
   none.
2. **Check the bundled data.** Run the full test suite. It loads the shipped
   schema, pricing manifest, model aliases and comparison corpus.
3. **Check the license headers**: `macos/scripts/check-license-headers.sh`.
4. **Check the notices.** Every dependency and third-party asset in the build
   appears in `THIRD-PARTY-NOTICES` and `macos/Burnline/Acknowledgements/`, and
   the About surface reaches them.
5. **Bump the versions** in the app target.
6. **Merge** the staging branch into `main` by pull request, and tag the merge
   commit `vX.Y.Z`.
7. **Archive** a Release build in Xcode and sign it with the release identity
   *(to build)*.
8. **Package** it as a `.dmg` with `create-dmg` *(to build)*: the app beside
   an Applications link on a custom background, so installing is one drag.
   Sign the `.dmg` with the same identity.
9. **Publish** a GitHub Release with the `.dmg`, its SHA-256, release notes, and
   the Gatekeeper instructions below.
10. **Update the tap's cask** with the new version and checksum *(to build)*.
11. **Try both routes** on a clean user account: install from the tap, and
    from the `.dmg` through the Gatekeeper steps. Check onboarding, a first
    import and the About surface.

## Homebrew

Start on a personal tap. The official `homebrew/cask` repository has
notability requirements a new project will not meet.

The tap is a public repository of its own, `igharsha7/homebrew-tap` *(to
build)*; its cask installs the `.dmg` from the GitHub Release and checks its
SHA-256:

```sh
brew install --cask igharsha7/tap/burnline
```

Homebrew 5.0 deprecated `--no-quarantine`, and the official cask repository
no longer accepts apps that fail Gatekeeper, so a personal tap is the only
Homebrew route for an un-notarized app. Whether its cask may clear the
quarantine flag after installing is to be tested on current Homebrew before
the README promises it.

## Opening an un-notarized app

Since macOS 15, Control-clicking the app and choosing Open no longer works
for un-notarized apps. The README and every release must show the route that
does:

1. Open Burnline once. macOS says it cannot verify the developer; choose Done.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the message about Burnline and choose **Open Anyway**.
4. Confirm with your password or Touch ID.

This is needed once, on first install. Versions installed by the in-app
updater are not quarantined and open straight away; a new `.dmg` downloaded
by hand asks again.

## What a release does not do

- It does not migrate anyone's data at install. Migrations run when the new
  version first opens the database, after copying it to `Backups/`.
- It does not track anyone. The in-app updater checks a public feed of
  versions once a day, can be turned off, and sends nothing about the Mac or
  its usage; [privacy and security](privacy-and-security.md#network) lists it
  beside the price fetch and quota reads.

# Releasing

How a Burnline release is made and distributed.

> **Status.** No release has been published yet; Burnline is built from
> source today. Everything the first release needs is in place: this page is
> the checklist it follows, and every later one reuses.

## Distribution

| Route | For | Gatekeeper |
|---|---|---|
| **`.dmg` on GitHub Releases** | Everyone: open it and drag Burnline to Applications | Blocked on first open until allowed in System Settings, once |
| **Homebrew tap** | People who use Homebrew | The same first-open step: the cask keeps the quarantine, and says what to do after installing |
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
| **Nightly** | The `nightly` branch, each time work is merged into it | The next version with a pre-release suffix, such as `0.2.0-nightly.20261111` | People who want the newest work and accept rough edges |

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

A release is signed with a **stable self-signed identity**, "Burnline
Release": one certificate, kept by the maintainer and reused for every
release, so the signature, and the requirement macOS checks it against, stays
the same from one version to the next. Make it once:

```sh
macos/scripts/make-signing-identity.sh
```

It creates the certificate and its private key, imports them into the login
keychain, prints nothing secret, and refuses to make a second one. The
certificate is valid for twenty years. Losing it means the next release is
signed differently, so macOS asks again for what Burnline was allowed; back
up the identity from Keychain Access with the Sparkle key.

## Building a release

```sh
macos/scripts/build-release.sh                       # stable, at the app target's version
macos/scripts/build-release.sh --nightly --version 0.2.0-nightly.20261112 --build 8
```

It builds the Release configuration, then signs it with the release identity
from the inside out: Sparkle's helpers and framework first, keeping their
entitlements, then the app. An identity given to `xcodebuild` would reach
the packages' resource bundles too, which then demand a development team. The
script checks that every nested piece verifies and that the signature names
the certificate, then packs the app into a `.dmg` in `build/release/`. The
image itself is left unsigned: macOS assesses a signed image when it is
opened, and with a self-signed certificate that is a second warning before
the app's own. The app inside is signed, and the image is covered by
Sparkle's signature and the published checksum.

The `.dmg` is made by [dmgbuild](https://github.com/dmgbuild/dmgbuild) (MIT),
installed at a pinned version into a private environment under
`build/release/`. It is a build tool only and never ships. It writes the
window's layout directly, without driving Finder, so a CI runner makes the
same image as a Mac.

The window is drawn by `macos/scripts/dmg/background.swift`: the burn line. A
usage chart runs from Burnline to Applications, and its trend line is a lit
fuse, its burnt bars glowing behind the spark and the rest waiting ahead, so
the way to drag reads at a glance. Below it are the first-open steps. A
nightly's window has the same layout under its night sky. Two details come
from Finder:

- **Icon names sit on light tags.** Finder writes them in dark grey over any
  background image, in either appearance.
- **The window is taller than the background** by its title bar, and the
  bottom of the background is left empty for the path bar Finder may add.

`settings.py` beside it places the icons, at the centres `background.swift`
draws around.

## The release workflow

`.github/workflows/release.yml` builds, signs and publishes every release, so
no release is built on a personal Mac:

| Trigger | Publishes |
|---|---|
| A tag `vX.Y.Z` on `main` | That stable release, as a GitHub Release `vX.Y.Z`. The tag must match the app target's version. |
| A push to `nightly`, which is each merge into it | The `nightly` branch, as the rolling pre-release `nightly-build` |
| Running it by hand | The `nightly` branch again |
| A push to `release-dry-run` | Nothing: a rehearsal that builds, signs and writes the appcast, and keeps them as the run's artifact |

Each run builds with `build-release.sh`, signs the `.dmg` with Sparkle's
EdDSA key, and adds it to `appcast.xml` on the `appcast` branch with
`.github/scripts/appcast.py`, which keeps every stable release and only the
newest nightly. The build number is the workflow's run number, which rises
across both channels, as Sparkle compares it. The rolling nightly's tag is
`nightly-build`, not `nightly`, which is the branch.

The release notes are GitHub's generated notes for a stable release, and the
commits since the last nightly for a nightly. Both pages add the first-open
steps and the `.dmg`'s SHA-256; the updater shows the notes alone.

A nightly runs only when `nightly` moves, so nothing runs while it is idle.
Running it by hand uses the workflow as it is on `main`.

### Secrets

The workflow's secrets live in the repository's `release` environment, which
only `main`, `nightly`, tags `v*` and `release-dry-run` may use:

| Secret | Holds |
|---|---|
| `RELEASE_CERTIFICATE_P12` | The release certificate and its private key, exported from Keychain Access as `.p12`, base64-encoded |
| `RELEASE_CERTIFICATE_PASSWORD` | That export's password |
| `SPARKLE_PRIVATE_KEY` | Sparkle's EdDSA private key, as `generate_keys -x` writes it |
| `HOMEBREW_TAP_TOKEN` | A fine-grained token with write access to `igharsha7/homebrew-tap`'s contents, and nothing else |

The certificate is imported into a temporary keychain that the run deletes,
and the Sparkle key is read from standard input, never written to disk.

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
5. **Bump the versions** in the app target. The build number is set by the
   release workflow; only `MARKETING_VERSION` changes by hand.
6. **Rehearse** by pushing the release commit to `release-dry-run`, and open
   the `.dmg` the run keeps: the icons on the fuse's ends, both names
   readable, the steps uncut. See [the release workflow](#the-release-workflow).
7. **Merge** the staging branch into `main` by pull request.
8. **Tag** the merge commit `vX.Y.Z` and push the tag. The release workflow
   builds, signs and publishes it, and adds it to the appcast; every install
   following stable is offered it within a day.
9. **Read the published release**: its notes, the first-open steps, the
   `.dmg` and its SHA-256.
10. **Check the tap**: the workflow pushed `Casks/burnline.rb` with the new
    version and checksum to `igharsha7/homebrew-tap`.
11. **Try both routes** on a clean user account: install from the tap, and
    from the `.dmg` through the Gatekeeper steps. Check onboarding, a first
    import and the About surface.

## Homebrew

Start on a personal tap. The official `homebrew/cask` repository has
notability requirements a new project will not meet.

The tap is a public repository of its own, `igharsha7/homebrew-tap`; its
cask installs the `.dmg` from the GitHub Release and checks its SHA-256:

```sh
brew install --cask igharsha7/tap/burnline
```

The cask's source is `.github/homebrew/burnline.rb` in this repository, so it
is reviewed like everything else. Each stable release, the release workflow
fills in the version and checksum and pushes it to the tap; the tap is never
edited by hand. The cask:

- declares `auto_updates`, so Homebrew leaves upgrades to Sparkle;
- requires macOS 14;
- removes Burnline's data, preferences and caches with `brew uninstall --zap`,
  and only then;
- keeps the quarantine, and after installing shows the first-open steps.

Homebrew 5.0 removed `--no-quarantine`, and the official cask repository no
longer accepts apps that fail Gatekeeper, so a personal tap is the only
Homebrew route for an un-notarized app. Its cask could clear the quarantine
after installing, and deliberately does not: whoever installs Burnline
allows it once, the same way as from the `.dmg`. Installing from a local
copy of the tap showed the result: the app keeps its quarantine, verifies,
and Gatekeeper asks once, naming `Burnline Release` as its origin.

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

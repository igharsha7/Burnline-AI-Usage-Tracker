# Updates

How Burnline updates itself, the two channels it can follow, and how a
nightly build looks different from a release.

## How it works

Burnline updates through [Sparkle](https://sparkle-project.org) 2, the
standard updater for Mac apps distributed outside the App Store.

- **Once a day** Burnline downloads the appcast, a public list of versions.
  The check can be turned off in Settings → General → Updates.
- **Nothing about you is sent.** The request carries Sparkle's standard
  `User-Agent` (the app's name and version) and nothing else. Sparkle's
  system profiling is off in `Info.plist`.
- **Every update is verified** before it is installed: its archive must be
  signed with the maintainer's EdDSA key, whose public half is in the app's
  `Info.plist` (`SUPublicEDKey`). A build without that key never checks.
- **It never installs by itself.** A scheduled check that finds a version
  does not interrupt: an **Update to 0.2.0** button appears at the foot of
  the dashboard's sidebar and in the popover's footer, and stays until it is
  chosen. Choosing it, or **Check for Updates…** in the app menu, shows
  Sparkle's window with the release notes and Install.
- **Debug builds never update.** They are not the build a feed describes, and
  replacing one with a release would lose the change being tested.

Updates installed this way are not quarantined, so macOS does not ask for
**Open Anyway** again. See [releasing](releasing.md#opening-an-un-notarized-app).

## Channels

| Channel | What it receives | Who for |
|---|---|---|
| **Stable** | Each release, `vX.Y.Z` | Everyone, by default |
| **Nightly** | A build of the newest work each night it changed, and every stable release | People who want new work first and accept rough edges |

Both live in one appcast. A nightly item carries
`<sparkle:channel>nightly</sparkle:channel>`; a stable item carries no
channel. The updater accepts the nightly channel only when Settings follows
it (`UpdateModel.allowedFeedChannels`), and always takes the newest build it
accepts.

Build numbers (`CFBundleVersion`) rise across both channels, because Sparkle
compares them, never the version text.

- **Stable to nightly** asks first. A nightly can carry migrations no stable
  release has yet, and a stable build refuses a database newer than it reads.
- **Nightly to stable** never goes back in time. The nightly stays until a
  stable release has a higher build number; to go back sooner, install the
  stable `.dmg` and restore a backup taken before the nightly. Settings says
  so when the choice is made.

A nightly build follows the nightly channel until told otherwise; a stable
build, stable.

## The nightly look

A nightly must never be mistaken for a release, in a screenshot, a bug
report or the Dock. It wears a night sky, deep blue into purple, wherever
Burnline shows itself:

| Where | What changes |
|---|---|
| App icon | The same flame, ring and bars under a night sky with a crescent moon and stars (`AppIcon-Nightly.icon`) |
| Menu bar | The flame burns in moonlight until it is hot; hot and blazing keep their ember and red |
| Dashboard | A window onto the night sky at the foot of the sidebar on every page: a glowing crescent, stars, **Nightly**, the release it leads to and its date, and the update check. The stars brighten while the pointer is over it. |
| Popover | The moon badge in the footer |
| About and Settings | The badge under the version, and the version with its nightly suffix |
| Diagnostics | The version is reported with ", nightly" |

The colours are the `nightTop`, `nightBottom` and `moonlight` tokens. They
appear only on these marks, never on a surface or a figure, and nothing in
them animates while idle.

## Building a channel

The `BURNLINE_CHANNEL` build setting chooses the channel: `stable` by default,
or `nightly`. It sets `BurnlineChannel` in `Info.plist`, which the app reads,
and the app icon, through `BURNLINE_APP_ICON_stable` and
`BURNLINE_APP_ICON_nightly`:

```sh
xcodebuild -project macos/Burnline.xcodeproj -scheme Burnline \
    -configuration Release BURNLINE_CHANNEL=nightly build
```

A nightly's version is the next release's with a suffix,
`0.2.0-nightly.20261111`; the date after `nightly.` is shown in its badge.

| Setting | Holds |
|---|---|
| `BURNLINE_CHANNEL` | `stable` or `nightly` |
| `BURNLINE_APPCAST_URL` | Where the appcast is published, `SUFeedURL` |
| `SPARKLE_PUBLIC_KEY` | The EdDSA public key, `SUPublicEDKey`. It is public by design, so it is in the project: a release build from source checks the same feed and accepts only updates signed by the maintainer |

`macos/Info.plist` holds the keys Xcode cannot generate, and is merged with
the generated one.

## Publishing

The appcast is `appcast.xml` on the repository's `appcast` branch, served
from `raw.githubusercontent.com` like the price list. Each release's `.dmg`
is a GitHub Release asset; the appcast item points at it, with its EdDSA
signature and length.

- **The private key** is the maintainer's alone. It is made once with
  Sparkle's `generate_keys`, kept in the maintainer's Keychain and as a
  repository secret for the release workflow, and never committed. Losing it
  means no existing install can update again, so it is backed up.
- **The appcast** is written by Sparkle's `generate_appcast`, which signs each
  archive. Nightly items are tagged with the nightly channel.
- **Release notes** are the GitHub Release's notes, linked from each item.

## Trying it in a debug build

| Variable | Effect, debug builds only |
|---|---|
| `BURNLINE_CHANNEL` | Takes that channel's look without a nightly build, `nightly` or `stable`. The app icon follows the build setting, not this. |
| `BURNLINE_DEMO_UPDATE` | Offers that version, such as `0.2.0`, as found, so the update button can be seen. Checking does nothing. |

```sh
BURNLINE_CHANNEL=nightly BURNLINE_DEMO_UPDATE=0.2.0 \
    macos/scripts/demo.sh /path/to/Debug/Burnline.app
```

# Licensing

Burnline is free software under the **GNU Affero General Public License,
version 3**, with one additional term under **Section 7(b)**: the original
author attribution must be preserved. These are obligations, not
preferences, and they bind every change.

| File | Holds |
|---|---|
| `LICENSE` | The verbatim AGPL-3.0 text. **Never edit it.** |
| `NOTICE` | The copyright, the Section 7(b) attribution term, commercial licensing, and the third-party marks and animation |
| `THIRD-PARTY-NOTICES` | The full license text of every bundled dependency, as those licenses require |
| `macos/Burnline/Acknowledgements/` | The same notices, bundled into the app for its About surface |

Copyright (C) 2026 Challapalli Harshavardhan Reddy.

## What the license is chosen to do

The intent is that nobody takes Burnline, closes the source and resells it.

- The AGPL **does not prohibit commercial use.** Anyone may sell Burnline or
  a derivative of it.
- It prohibits a **proprietary** derivative. Anyone who distributes a fork,
  or offers it over a network, must provide its complete source under the
  same license.
- So it removes the incentive to fork commercially rather than forbidding
  commerce. In practice the deterrent is stronger than the letter: many
  organisations forbid AGPL code by policy.

## The attribution term

`NOTICE` requires that any redistribution, modified or not, preserve this
attribution in its Appropriate Legal Notices:

> Burnline
> Originally created by Challapalli Harshavardhan Reddy
> Source: https://github.com/igharsha7/Burnline-AI-Usage-Tracker

- Where the work has an interactive interface, the attribution must be
  reachable from it, such as in an About window.
- A party that modifies Burnline may add its own attribution beside it, but
  may not remove, obscure, alter or replace the original.
- Removing it removes a term Section 7 expressly permits, so it is a license
  violation, not a discourtesy.

## Obligations in the code

### Every source file carries the header

Every `.swift`, `.sql`, `.sh` and `.py` file starts with the copyright line
and names the license, within its first 20 lines:

```swift
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
```

New files are not exempt. `macos/scripts/check-license-headers.sh` checks every
file and runs as a build phase of the app, so a missing header fails the
build.

### The About surface

Section 5(d) of the GPL, which the AGPL incorporates, requires a program with
an interactive interface to display Appropriate Legal Notices. Burnline has
two interfaces (the menu bar and the dashboard), so it must carry them. The
About surface shows:

- the copyright holder;
- the license, with the full text reachable;
- the attribution required by `NOTICE`;
- the source link;
- the third-party notices.

Every implementation, on every platform, must have one. See
[interface](interface.md#about) for where it lives in the macOS app.

### Dependencies must be compatible

A dependency must be compatible with the AGPL:

| Compatible | Not compatible |
|---|---|
| MIT, BSD, Apache-2.0, zlib, MPL-2.0 | Proprietary, GPLv2-only, licenses with field-of-use limits |

This applies to every package added over the life of the project. When adding
one:

1. Check its license, and for a dual-licensed package say which license it is
   used under.
2. Add its full license text to `THIRD-PARTY-NOTICES` and a file to
   `macos/Burnline/Acknowledgements/`.
3. Add it to the dependency table in [architecture](architecture.md#dependencies)
   with its license and why it is needed.

Current dependencies:

| Package | License | Used for |
|---|---|---|
| GRDB.swift 7.11.1 or later | MIT | SQLite access in the store |
| Zstandard 1.5.7, exactly | Dual BSD-3-Clause or GPLv2; **used under BSD-3-Clause** | Reading Codex's compressed session archives |
| lottie-spm 4.6.1 or later | Apache-2.0 | Playing the Streaks card's fire |
| Sparkle 2.10.1 or later | MIT | In-app updates |

## Third-party material

Some bundled assets are not part of Burnline and are not under its license.
Each folder has a README stating where its contents came from.

| Material | Where | Source and license |
|---|---|---|
| Provider logos | `BurnlineUI/ProviderLogos` | Simple Icons, CC0 1.0. Claude is a trademark of Anthropic, PBC; OpenAI of OpenAI; Cursor of Anysphere, Inc. Used only to identify each provider; no endorsement implied. |
| Fire animation | `BurnlineUI/Animations` | The fire emoji from Animated Noto Emoji, copyright Google LLC, CC BY 4.0. Recoloured at run time for each streak tier; shapes and motion unchanged. |
| Silkscreen font | `BurnlineUI/Fonts` | SIL Open Font License 1.1 |

Adding such material needs the same care as a dependency: a license that
permits redistribution, an entry in `NOTICE` or `THIRD-PARTY-NOTICES` where
the license asks for one, and a README in its folder.

## Distribution consequences

GPL-family terms conflict with the Mac App Store's terms, so third parties
cannot redistribute Burnline there. Burnline is distributed directly (see
[releasing](releasing.md)).

## Commercial licensing

A proprietary or closed-source product cannot include Burnline under the
AGPL. Burnline is not meant to be a commercial product. A copyright holder is
not bound by their own license, so the author can still grant other terms for
the code they wrote, and `NOTICE` gives the contact; but code from other
contributors could only be included with each contributor's agreement.

## Contributions and copyright

Contributions are accepted under the project's own terms: the AGPL-3.0 with
the Section 7(b) attribution term, and **no contributor license agreement**
(see [decisions](decisions.md#repository)).

- Each contributor keeps the copyright in what they write, and licenses it to
  everyone under those terms by contributing it.
- A contributor confirms, by opening a pull request, that they have the right
  to contribute the work under those terms.
- Once outside contributions are merged, the project is no longer solely
  owned, so a different license for the whole would need every contributor's
  agreement. This was accepted deliberately.

## Relicensing is one-way

Loosening the license (to a more permissive one) would need every
copyright holder's agreement, contributors included. It cannot meaningfully
be tightened: every
published version stays available under the terms it shipped with, and a fork
may continue from that point.

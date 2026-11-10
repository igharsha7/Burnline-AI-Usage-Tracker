# Design sources

## App icon

A solid flame in front of the two things Burnline watches: a limit's ring
rising on the left and a bar chart of usage on the right, the tallest bar
burning. Both start behind the flame's base and stay below its tip, and the
flame lights the graphite around it.

The icon is `../Burnline/AppIcon.icon`, a layered Icon Composer document that
`../scripts/generate-icon.py` writes from named measurements:

```sh
python3 macos/scripts/generate-icon.py
```

It has four groups, the most an icon may have, front to back: the flame with
its white-hot core (solid glass, nothing shows through), the bars (glass), the
ring, and the glow (light added to the background, with no glass or shadow).
The ring is a slightly flattened oval so its top crosses the flame where the
flame is wide enough to hide its end; the script checks both ends against the
flame's outline and refuses to write an icon where either shows.

**macOS 26 and later** draw the `.icon` itself, with the system's glass, edge
light and shadow, in the Default, Dark, Clear and Tinted appearances.
**macOS 14 and 15** get flat icons Xcode builds from the same document into
`AppIcon.icns`; there is no separate icon set to keep in step.

To see it as macOS renders it, use Icon Composer's `ictool` (inside Xcode's
`Icon Composer.app/Contents/Executables/`):

```sh
ictool macos/Burnline/AppIcon.icon --export-image --output-file icon.png \
    --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
```

Renditions are `Default`, `Dark`, `ClearLight`, `ClearDark`, `TintedLight` and
`TintedDark`; the tinted ones take `--tint-color` and `--tint-strength`. Opening
the document in Icon Composer works too, for adjusting by eye; carry any change
back into the script's measurements so the two do not drift.

#!/usr/bin/env python3
#
# generate-icon.py
# Burnline
#
# Copyright (C) 2026 Challapalli Harshavardhan Reddy
# Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
"""Writes Burnline's app icon as a layered Icon Composer document (`.icon`).

The mark is a solid flame in front of the two things Burnline watches: a
limit's ring rising on the left and a bar chart of usage on the right. Both
start behind the flame's base and stay below its tip, and the flame lights
the graphite around it.

macOS 26 and later draw the `.icon` itself, adding the glass, edge light and
shadow, and offer it in the Default, Dark, Clear and Tinted appearances.
Xcode builds flat icons for macOS 14 and 15 from the same document.

Nightly builds have their own icon, so the two can sit side by side and
never be mistaken: the same mark under a night sky, deep blue into purple,
with a crescent moon and a few stars the flame burns beneath.

    python3 macos/scripts/generate-icon.py [--nightly] [output.icon]

The default output is the app target's `macos/Burnline/AppIcon.icon`, or
`AppIcon-Nightly.icon` with `--nightly`. To look
at the result as macOS renders it, use Icon Composer's `ictool`:

    ictool AppIcon.icon --export-image --output-file icon.png --platform macOS \\
        --rendition Default --width 1024 --height 1024 --scale 1
"""

import json
import math
import sys
from pathlib import Path

CANVAS = 1024

# Ember, from white-hot to deep, as the app's palette has it.
WHITE_HOT, YELLOW, EMBER, DEEP = "#FFF4D6", "#FFD27A", "#FF8A4C", "#E2452B"
SILVER_DARK, SILVER_LIGHT = "#8E929A", "#E6E8EC"
RING_DARK, RING_LIGHT = "#B9BEC6", "#E6E8EC"
GLOW = "#FF7A33"
GRAPHITE = "display-p3:0.11,0.11,0.12,1.0"

# The nightly sky, from the zenith down to the horizon, and its moon and stars.
SKY_TOP, SKY_BOTTOM = "display-p3:0.05,0.07,0.22,1.0", "display-p3:0.27,0.13,0.45,1.0"
MOONLIGHT = "#EEEBFF"
# The crescent: the moon's centre and radius, and the offset of the shadow
# that bites it, all clear of the ring and the flame's tip.
MOON_X, MOON_Y, MOON_RADIUS, MOON_BITE = 200, 186, 84, (38, -28)
# Stars: centre and radius, scattered where nothing else is drawn.
STARS = [(372, 120, 9), (120, 420, 6), (812, 150, 11), (900, 300, 6), (705, 92, 5), (860, 470, 5), (90, 250, 4)]

# The flame: its base centre, height and half-width.
FLAME_X, FLAME_BASE, FLAME_HEIGHT, FLAME_HALF_WIDTH = 512, 880, 770, 270

# The ring, a slightly flattened oval so its top crosses the flame where the
# flame is wide enough to hide its end: centre, radii, the angles it runs
# between (clockwise from three o'clock) and its width.
RING_X, RING_Y, RING_RX, RING_RY = 512, 540, 330, 300
RING_FROM, RING_TO, RING_WIDTH = 110, 275, 58

# The bars: left edge, the line they stand on, width, gap and heights.
BARS_X, BARS_BASE, BAR_WIDTH, BAR_GAP = 615, 835, 74, 20
BAR_HEIGHTS = (330, 505, 675)

# The light the flame casts: centre, radius and strength at the centre.
GLOW_X, GLOW_Y, GLOW_RADIUS, GLOW_STRENGTH = 512, 590, 540, 0.85

# The flame's outline in units of its half-width (x) and height (y, from the
# base up): a tall tongue leaning on its left lick. Cubic segments.
FLAME_START = (0.02, 1)
FLAME_CURVES = [
    ((0.30, 0.80), (1, 0.62), (1, 0.34)),
    ((1, 0.13), (0.56, 0), (0, 0)),
    ((-0.56, 0), (-1, 0.13), (-1, 0.34)),
    ((-1, 0.50), (-0.78, 0.62), (-0.50, 0.70)),
    ((-0.48, 0.57), (-0.36, 0.47), (-0.14, 0.45)),
    ((-0.24, 0.64), (-0.18, 0.86), (0.02, 1)),
]
# The white-hot core, in the same units.
CORE_START = (0, 0.42)
CORE_CURVES = [
    ((0.16, 0.33), (0.42, 0.25), (0.42, 0.15)),
    ((0.42, 0.06), (0.23, 0.03), (0, 0.03)),
    ((-0.23, 0.03), (-0.42, 0.06), (-0.42, 0.15)),
    ((-0.42, 0.25), (-0.16, 0.33), (0, 0.42)),
]


def flame_point(x, y):
    return FLAME_X + x * FLAME_HALF_WIDTH, FLAME_BASE - y * FLAME_HEIGHT


def path(start, curves):
    def point(p):
        x, y = flame_point(*p)
        return f"{x:.1f} {y:.1f}"

    return f"M{point(start)} " + " ".join(f"C{point(a)} {point(b)} {point(c)}" for a, b, c in curves) + " Z"


def outline(start, curves, steps=40):
    """The outline as points, for checking what it hides."""
    points, current = [flame_point(*start)], flame_point(*start)
    for a, b, c in curves:
        p0, p1, p2, p3 = current, flame_point(*a), flame_point(*b), flame_point(*c)
        for i in range(1, steps + 1):
            t = i / steps
            points.append(tuple((1 - t) ** 3 * q0 + 3 * (1 - t) ** 2 * t * q1 + 3 * (1 - t) * t ** 2 * q2 + t ** 3 * q3
                                for q0, q1, q2, q3 in zip(p0, p1, p2, p3)))
        current = p3
    return points


def inside(polygon, x, y):
    crossings = False
    for (x0, y0), (x1, y1) in zip(polygon, polygon[1:] + polygon[:1]):
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            crossings = not crossings
    return crossings


def ring_point(angle):
    return RING_X + RING_RX * math.cos(math.radians(angle)), RING_Y + RING_RY * math.sin(math.radians(angle))


def hidden(polygon, angle):
    """Whether the ring's round end at `angle` lies wholly behind the flame."""
    x, y = ring_point(angle)
    radius = RING_WIDTH / 2
    return all(inside(polygon, x + radius * math.cos(a), y + radius * math.sin(a))
               for a in (i * math.pi / 8 for i in range(16)))


def svg(body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
            f'viewBox="0 0 {CANVAS} {CANVAS}"><defs>{defs}</defs>{body}</svg>')


def linear(name, stops, x1=0, y1=1, x2=0, y2=0):
    body = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
    return f'<linearGradient id="{name}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{body}</linearGradient>'


def radial(name, stops, cx=0.5, cy=0.5, r=0.5):
    body = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
    return f'<radialGradient id="{name}" cx="{cx}" cy="{cy}" r="{r}">{body}</radialGradient>'


def sky():
    """The nightly sky's moon and stars, as one layer of light."""
    bite_x, bite_y = MOON_X + MOON_BITE[0], MOON_Y + MOON_BITE[1]
    moon = (f'<mask id="m"><rect width="{CANVAS}" height="{CANVAS}" fill="white"/>'
            f'<circle cx="{bite_x}" cy="{bite_y}" r="{MOON_RADIUS * 0.86:.1f}" fill="black"/></mask>')
    stars = "".join(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{MOONLIGHT}"/>' for x, y, r in STARS)
    return svg(f'<circle cx="{MOON_X}" cy="{MOON_Y}" r="{MOON_RADIUS}" fill="{MOONLIGHT}" mask="url(#m)"/>{stars}',
               moon)


def groups(nightly=False):
    """The icon's groups, front first: each its layers' SVGs, front first,
    and how the group is drawn. An icon allows at most four groups."""
    core = svg(f'<path d="{path(CORE_START, CORE_CURVES)}" fill="url(#c)"/>',
               radial("c", [(0, WHITE_HOT, 1), (0.55, YELLOW, 1), (1, "#FFB15C", 1)], 0.5, 0.7, 0.6))
    flame = svg(f'<path d="{path(FLAME_START, FLAME_CURVES)}" fill="url(#f)"/>',
                linear("f", [(0, DEEP), (0.55, EMBER), (1, "#FFB070")]))
    bars = "".join(
        f'<rect x="{BARS_X + i * (BAR_WIDTH + BAR_GAP)}" y="{BARS_BASE - height}" width="{BAR_WIDTH}" '
        f'height="{height}" rx="{BAR_WIDTH / 2}" fill="url(#{"h" if i == len(BAR_HEIGHTS) - 1 else "s"})"/>'
        for i, height in enumerate(BAR_HEIGHTS))
    bars = svg(bars, linear("s", [(0, SILVER_DARK), (1, SILVER_LIGHT)])
               + linear("h", [(0, DEEP), (0.6, EMBER), (1, YELLOW)]))
    (x0, y0), (x1, y1) = ring_point(RING_FROM), ring_point(RING_TO)
    large = 1 if (RING_TO - RING_FROM) % 360 > 180 else 0
    ring = svg(f'<path d="M{x0:.1f} {y0:.1f} A{RING_RX} {RING_RY} 0 {large} 1 {x1:.1f} {y1:.1f}" '
               f'stroke="url(#r)" stroke-width="{RING_WIDTH}" stroke-linecap="round" fill="none"/>',
               linear("r", [(0, RING_DARK), (1, RING_LIGHT)]))
    glow = svg(f'<circle cx="{GLOW_X}" cy="{GLOW_Y}" r="{GLOW_RADIUS}" fill="url(#w)"/>',
               radial("w", [(0, GLOW, GLOW_STRENGTH), (0.55, GLOW, GLOW_STRENGTH * 0.85),
                            (0.78, GLOW, GLOW_STRENGTH * 0.3), (1, GLOW, 0)]))
    solid = {"translucency": {"enabled": False, "value": 0}}
    # Light, not an object: no glass, shadow or see-through, added to what is behind.
    light = {"translucency": {"enabled": False, "value": 0}, "specular": False, "shadow": None}
    return [
        ([("core", core, True), ("flame", flame, True)], solid),
        ([("bars", bars, True)], {}),
        ([("ring", ring, False)], {}),
        ([("glow", glow, False)] + ([("sky", sky(), False)] if nightly else []), light),
    ]


def write(output, nightly=False):
    polygon = outline(FLAME_START, FLAME_CURVES)
    for angle in (RING_FROM, RING_TO):
        if not hidden(polygon, angle):
            sys.exit(f"The ring's end at {angle}° shows past the flame; move it until both ends are behind it.")
    tallest = BARS_BASE - max(BAR_HEIGHTS)
    if tallest <= FLAME_BASE - FLAME_HEIGHT or RING_Y - RING_RY <= FLAME_BASE - FLAME_HEIGHT:
        sys.exit("The flame's tip must stand above the ring and the bars.")

    assets = output / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    drawn = []
    for members, effects in groups(nightly):
        group = {"layers": [], "shadow": {"kind": "layer-color", "opacity": 0.5},
                 "translucency": {"enabled": True, "value": 0.35}, "specular": True}
        for name, art, glass in members:
            (assets / f"{name}.svg").write_text(art)
            layer = {"image-name": f"{name}.svg", "name": name, "glass": glass,
                     "position": {"scale": 1, "translation-in-points": [0, 0]}}
            if name in ("glow", "sky"):
                layer["blend-mode"] = "plus-lighter"
            group["layers"].append(layer)
        for key, value in effects.items():
            if value is None:
                group.pop(key, None)
            else:
                group[key] = value
        drawn.append(group)
    fill = {"linear-gradient": [SKY_TOP, SKY_BOTTOM]} if nightly else {"automatic-gradient": GRAPHITE}
    icon = {"fill": fill, "groups": drawn,
            "supported-platforms": {"circles": ["watchOS"], "squares": "shared"}}
    (output / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")


if __name__ == "__main__":
    arguments = sys.argv[1:]
    nightly = "--nightly" in arguments
    paths = [a for a in arguments if a != "--nightly"]
    name = "AppIcon-Nightly.icon" if nightly else "AppIcon.icon"
    default = Path(__file__).resolve().parent.parent / "Burnline" / name
    write(Path(paths[0]) if paths else default, nightly)

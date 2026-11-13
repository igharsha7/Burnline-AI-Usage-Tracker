#!/usr/bin/env python3
#
# appcast.py
# Burnline
#
# Copyright (C) 2026 Challapalli Harshavardhan Reddy
# Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
"""Adds a build to Burnline's appcast, the feed Sparkle checks for updates.

The feed holds every stable release, newest first, and only the newest
nightly: a nightly's download is replaced by the next one, so an older nightly
item would point at a file its signature no longer matches. Stable items
carry no channel; nightly items carry `<sparkle:channel>nightly`, which only
an app following nightly accepts. See docs/updates.md.

    appcast.py appcast.xml --channel stable --version 0.1.0 --build 12 \\
        --url https://…/Burnline-0.1.0.dmg --signature 'sparkle:edSignature="…" length="…"' \\
        --notes notes.md --link https://…/releases/tag/v0.1.0 --minimum-system 14.0

`--signature` takes what Sparkle's `sign_update` prints. The notes are
Markdown; their headings, bullets and paragraphs become the HTML Sparkle
shows above Install.
"""

import argparse
import html
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

TITLE = "Burnline"
NIGHTLY = "nightly"


def sparkle(tag: str) -> str:
    return f"{{{SPARKLE}}}{tag}"


def notes_html(markdown: str) -> str:
    """The notes as simple HTML: headings, bullet lists and paragraphs, with
    inline code and links kept. Anything else is shown as text."""

    def inline(text: str) -> str:
        text = html.escape(text)
        text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
        text = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', text)
        return re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)

    parts: list[str] = []
    bullets: list[str] = []
    paragraph: list[str] = []

    def flush() -> None:
        if bullets:
            parts.append("<ul>" + "".join(f"<li>{b}</li>" for b in bullets) + "</ul>")
            bullets.clear()
        if paragraph:
            parts.append(f"<p>{' '.join(paragraph)}</p>")
            paragraph.clear()

    for line in markdown.splitlines():
        stripped = line.strip()
        if not stripped:
            flush()
        elif heading := re.match(r"#{1,6}\s+(.*)", stripped):
            flush()
            parts.append(f"<h3>{inline(heading.group(1))}</h3>")
        elif bullet := re.match(r"[-*]\s+(.*)", stripped):
            if paragraph:
                flush()
            bullets.append(inline(bullet.group(1)))
        else:
            if bullets:
                flush()
            paragraph.append(inline(stripped))
    flush()
    return "\n".join(parts)


def signature_fields(line: str) -> tuple[str, str]:
    """The signature and length from `sign_update`'s output."""
    signature = re.search(r'sparkle:edSignature="([^"]+)"', line)
    length = re.search(r'length="(\d+)"', line)
    if not signature or not length:
        raise ValueError(f"not sign_update output: {line!r}")
    return signature.group(1), length.group(1)


def load(path: Path) -> ET.ElementTree:
    if path.exists():
        return ET.parse(path)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = TITLE
    return ET.ElementTree(rss)


def add(tree: ET.ElementTree, args: argparse.Namespace, now: datetime) -> None:
    channel = tree.getroot().find("channel")
    assert channel is not None
    items = channel.findall("item")
    for item in items:
        build = item.findtext(sparkle("version"))
        is_nightly = item.findtext(sparkle("channel")) == NIGHTLY
        if build == args.build:
            raise ValueError(f"build {args.build} is already in the appcast")
        if args.channel == NIGHTLY and is_nightly:
            channel.remove(item)

    signature, length = signature_fields(args.signature)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"{TITLE} {args.version}"
    ET.SubElement(item, "pubDate").text = format_datetime(now)
    ET.SubElement(item, sparkle("version")).text = args.build
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.minimum_system
    if args.channel == NIGHTLY:
        ET.SubElement(item, sparkle("channel")).text = NIGHTLY
    ET.SubElement(item, sparkle("fullReleaseNotesLink")).text = args.link
    ET.SubElement(item, "description").text = notes_html(Path(args.notes).read_text())
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": length,
        "type": "application/octet-stream",
        sparkle("edSignature"): signature,
    })

    # Newest first, after the channel's own elements.
    first = next((i for i, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(first, item)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("appcast", type=Path)
    parser.add_argument("--channel", choices=["stable", NIGHTLY], required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--notes", required=True)
    parser.add_argument("--link", required=True)
    parser.add_argument("--minimum-system", required=True)
    args = parser.parse_args(argv)

    tree = load(args.appcast)
    try:
        add(tree, args, datetime.now(timezone.utc))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/bin/sh
#
#  sync-labels.sh
#  Burnline
#
#  Copyright (C) 2026 Challapalli Harshavardhan Reddy
#  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
#
# Creates or updates the repository's labels from .github/labels.yml.
# A label with `renamedFrom` is renamed from that one if it exists, so issues
# keep their labels. Labels not in the file are never deleted.
#
#   .github/scripts/sync-labels.sh [owner/repo]
#
# Needs `gh`, signed in with write access to the repository, and python3.

set -eu

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
repo=${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
existing=$(gh label list --repo "$repo" --limit 500 --json name --jq '.[].name')

python3 - "$repo_root/.github/labels.yml" <<'PY' |
import sys
# A small reader for this file's flat shape, so no YAML package is needed.
labels, current = [], None
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.split(" #")[0].rstrip() if not raw.lstrip().startswith("#") else ""
    if not line.strip():
        continue
    if line.startswith("- "):
        current = {}
        labels.append(current)
        line = line[2:]
    key, _, value = line.strip().partition(":")
    current[key.strip()] = value.strip().strip('"')
for label in labels:
    print("\t".join([label["name"], label["color"], label["description"], label.get("renamedFrom", "")]))
PY
while IFS="$(printf '\t')" read -r name color description renamed; do
    if [ -n "$renamed" ] && printf '%s\n' "$existing" | grep -qxF "$renamed" \
        && ! printf '%s\n' "$existing" | grep -qxF "$name"; then
        gh label edit "$renamed" --repo "$repo" --name "$name" --color "$color" --description "$description"
        echo "renamed  $renamed -> $name"
    else
        gh label create "$name" --repo "$repo" --color "$color" --description "$description" --force
        echo "synced   $name"
    fi
done

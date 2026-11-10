#!/bin/bash
#
#  demo.sh
#  Burnline
#
#  Copyright (C) 2026 Challapalli Harshavardhan Reddy
#  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
#
# Runs a debug build on a demo store of invented usage, for screenshots and
# for trying the app without real history:
#
#   macos/scripts/demo.sh /path/to/Debug/Burnline.app [directory]
#
# Writes half a year of invented Claude Code and Codex use and a week of
# quota to <directory> (a new temporary one by default), then launches the
# app on it with invented limits. The app runs inside a sandbox profile that
# denies reading every real provider home and the real store, so nothing real
# can reach the demo, whatever the app looks for.

set -euo pipefail

app=${1:?usage: demo.sh /path/to/Debug/Burnline.app [directory]}
directory=${2:-$(mktemp -d "${TMPDIR:-/tmp}/burnline-demo.XXXXXX")}
root=$(cd "$(dirname "$0")/../.." && pwd)
suite=burnline-demo

mkdir -p "$directory/claude/projects" "$directory/codex/sessions"

echo "Writing the demo store to $directory/store…"
BURNLINE_DEMO_STORE="$directory/store" BURNLINE_DEMO_END=$(date +%s) \
  swift test --package-path "$root/macos/Packages" --filter DemoStoreTests >/dev/null 2>&1

cat > "$directory/deny-real.sb" <<EOF
(version 1)
(allow default)
(deny file-read* file-write*
  (subpath "$HOME/.claude")
  (subpath "$HOME/.codex")
  (subpath "$HOME/.config/claude")
  (subpath "$HOME/Library/Developer/Xcode/CodingAssistant")
  (subpath "$HOME/Library/Application Support/Burnline"))
EOF

# Onboarding done, both providers tracked, the tour seen, an invented name.
defaults delete "$suite" >/dev/null 2>&1 || true
defaults write "$suite" onboardingCompleted -bool YES
defaults write "$suite" trackedProviders -array claude_code codex
defaults write "$suite" tourSeen -bool YES
defaults write "$suite" userName Alex

echo "Launching. Quit Burnline to end the demo."
exec env BURNLINE_STORE_DIR="$directory/store" BURNLINE_SKIP_KEYCHAIN=1 BURNLINE_DEFAULTS_SUITE="$suite" \
  BURNLINE_DEMO_QUOTA="$directory/store/demo-quota.json" \
  CLAUDE_CONFIG_DIR="$directory/claude" CODEX_HOME="$directory/codex" \
  sandbox-exec -f "$directory/deny-real.sb" "$app/Contents/MacOS/Burnline"

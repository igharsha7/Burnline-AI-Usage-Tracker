#!/bin/sh
#
#  coverage.sh
#  Burnline
#
#  Copyright (C) 2026 Challapalli Harshavardhan Reddy
#  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
#
# Runs the package's tests with coverage and prints line coverage per module,
# counting only Burnline's own sources: not dependencies, tests or test
# support.
#
# Core, Store, Providers and Services may not lose coverage: --check fails
# when one falls below its figure in coverage-baseline.json. UI is not gated;
# SwiftUI view bodies keep its figure low, so read it per file instead.
#
#   macos/scripts/coverage.sh                    # per module
#   macos/scripts/coverage.sh --files            # and per file, least covered first
#   macos/scripts/coverage.sh --check            # fail if a gated module dropped (CI)
#   macos/scripts/coverage.sh --update-baseline  # record today's figures as the floor
#   macos/scripts/coverage.sh --no-run ...       # use the last coverage run
#
set -eu
packages="$(cd "$(dirname "$0")/../Packages" && pwd)"
baseline="$(cd "$(dirname "$0")" && pwd)/coverage-baseline.json"
files=0; run=1; mode=report
for argument in "$@"; do
    case "$argument" in
        --files) files=1 ;;
        --no-run) run=0 ;;
        --check) mode=check ;;
        --update-baseline) mode=update ;;
        *) echo "usage: $0 [--files] [--no-run] [--check | --update-baseline]" >&2; exit 2 ;;
    esac
done
if [ "$run" = 1 ]; then
    swift test --package-path "$packages" --enable-code-coverage
fi
report="$(swift test --package-path "$packages" --show-codecov-path)"
[ -f "$report" ] || { echo "no coverage report at $report; run without --no-run" >&2; exit 1; }

python3 - "$report" "$packages/Sources/" "$files" "$mode" "$baseline" <<'PY'
import json, sys
report, sources, show_files, mode, baseline = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4], sys.argv[5]
# Modules that may not lose coverage, and how far a figure may wobble
# between runs (a few lines in timing-dependent code) before it counts.
GATED = ["BurnlineCore", "BurnlineStore", "BurnlineProviders", "BurnlineServices"]
TOLERANCE = 0.1
modules, per_file = {}, []
for entry in json.load(open(report))["data"][0]["files"]:
    name = entry["filename"]
    if not name.startswith(sources):
        continue
    module, _, path = name[len(sources):].partition("/")
    if module == "BurnlineTestSupport":
        continue
    lines = entry["summary"]["lines"]
    covered, total = modules.get(module, (0, 0))
    modules[module] = (covered + lines["covered"], total + lines["count"])
    per_file.append((lines["percent"], lines["count"], f"{module}/{path}"))
print(f"\n{'module':<22}{'lines':>8}{'covered':>9}")
for module, (covered, total) in sorted(modules.items()):
    print(f"{module:<22}{total:>8}{100 * covered / max(total, 1):>8.1f}%")
if show_files:
    print()
    for percent, count, path in sorted(per_file):
        print(f"{percent:6.1f}%  {count:>5}  {path}")

current = {m: round(100 * c / max(t, 1), 1) for m, (c, t) in modules.items() if m in GATED}
if mode == "update":
    with open(baseline, "w") as out:
        json.dump(dict(sorted(current.items())), out, indent=2)
        out.write("\n")
    print(f"\nrecorded the floor in {baseline}")
elif mode == "check":
    floor = json.load(open(baseline))
    dropped = [(m, floor[m], current.get(m, 0.0)) for m in floor if current.get(m, 0.0) < floor[m] - TOLERANCE]
    print()
    for module, was, now in dropped:
        print(f"coverage fell in {module}: {was}% -> {now}%. Add tests for the new or changed code.")
    if dropped:
        sys.exit(1)
    print("no gated module lost coverage")
PY

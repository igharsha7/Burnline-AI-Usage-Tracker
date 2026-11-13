#!/usr/bin/env python3
#
#  perf_compare.py
#  Burnline
#
#  Copyright (C) 2026 Challapalli Harshavardhan Reddy
#  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
#
# The performance gate's verdict. Reads the figures the performance suites
# wrote for the pull request (and, when there is one, for its base branch,
# measured on the same runner) and fails if any figure is outside its budget
# or has regressed against the base by more than noise allows:
#
#   python3 .github/scripts/perf_compare.py --head <dir>... [--base <dir>...] --out result.json
#
# Each side may be measured more than once, one directory per run; the best
# run of each figure counts, since noise on a shared runner only adds time.
#
# Prints a table, writes the verdict as JSON for ci_report.py, and exits 1 on
# failure. The suites and budgets are described in docs/performance.md.

import argparse
import json
import sys
from pathlib import Path

# How much worse than the base a figure may be before it counts as a
# regression, by unit: a relative share, and for times a floor in the unit
# itself, because a shared runner moves a 2 ms figure by more than 25%.
TOLERANCE = {
    "ms": (0.25, 3.0),
    "events/s": (0.25, 0.0),
    "bytes": (0.03, 0.0),
}
DEFAULT_TOLERANCE = (0.25, 0.0)


def load(directories: list[Path]) -> dict[str, dict]:
    """Every figure from the given runs, keeping each one's best value."""
    metrics: dict[str, dict] = {}
    for directory in directories:
        for file in sorted(directory.glob("*.json")) if directory.is_dir() else []:
            for metric in json.loads(file.read_text()).get("metrics", []):
                best = metrics.get(metric["id"])
                better = (metric["value"] < best["value"] if metric["better"] == "lower"
                          else metric["value"] > best["value"]) if best else True
                if better:
                    metrics[metric["id"]] = metric
    return metrics


def within_budget(metric: dict) -> bool:
    if metric["better"] == "lower":
        return metric["value"] <= metric["budget"]
    return metric["value"] >= metric["budget"]


def regression(metric: dict, base: dict) -> float | None:
    """How much worse than the base, as a share, if beyond tolerance."""
    share, floor = TOLERANCE.get(metric["unit"], DEFAULT_TOLERANCE)
    was, now = base["value"], metric["value"]
    if was <= 0:
        return None
    worse = (now - was) if metric["better"] == "lower" else (was - now)
    if worse <= floor or worse / was <= share:
        return None
    return worse / was


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--head", type=Path, nargs="+", required=True)
    parser.add_argument("--base", type=Path, nargs="*", default=[])
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    head, base = load(args.head), load(args.base)
    if not head:
        print("No performance figures were written: the suites did not run.")
        result = {"ran": False, "compared": False, "failed": True, "rows": []}
        if args.out:
            args.out.write_text(json.dumps(result, indent=2))
        return 1

    rows = []
    for metric in head.values():
        before = base.get(metric["id"])
        row = {**metric, "base": before["value"] if before else None, "status": "ok", "change": None}
        if before and before["value"]:
            row["change"] = (metric["value"] - before["value"]) / before["value"]
        if not within_budget(metric):
            row["status"] = "over budget"
        elif before and regression(metric, before) is not None:
            row["status"] = "regressed"
        rows.append(row)

    failed = any(row["status"] != "ok" for row in rows)
    result = {"ran": True, "compared": bool(base), "failed": failed, "rows": rows}
    if args.out:
        args.out.write_text(json.dumps(result, indent=2))

    width = max(len(row["title"]) for row in rows)
    for row in rows:
        base_text = f"base {row['base']:.2f}" if row["base"] is not None else "no base"
        change = f" ({row['change']:+.0%})" if row["change"] is not None else ""
        print(f"{row['title']:<{width}}  {row['value']:>10.2f} {row['unit']:<8} budget {row['budget']:<8g} "
              f"{base_text}{change}  {row['status']}")
    print("Performance gate:", "FAILED" if failed else "passed",
          "" if base else "(no base figures; budgets only)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

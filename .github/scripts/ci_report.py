#!/usr/bin/env python3
#
#  ci_report.py
#  Burnline
#
#  Copyright (C) 2026 Challapalli Harshavardhan Reddy
#  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
#
# Turns the CI logs into the report posted on a pull request: what passed,
# what failed and why, and which page to read to fix it. Run by ci.yml:
#
#   python3 .github/scripts/ci_report.py <logs-dir> <out-dir>
#
# Reads each check's outcome from the environment (TESTS, HEADERS, COVERAGE,
# APP, PERF: success, failure or skipped, and PERF also unaffected when the
# pull request changes nothing that affects speed) and writes <out-dir>/report.md and
# <out-dir>/meta.json. Everything quoted from the logs comes from the pull
# request's own code, so it is shown only inside code spans, with mentions
# and markup made harmless.

import json
import os
import re
import sys
from pathlib import Path

# Marks the bot's comment, so each run updates it rather than adding another.
MARKER = "<!-- burnline-ci-report -->"
# How many failures of one kind are listed before "and N more".
LISTED = 10
# GitHub refuses comments longer than 65,536 characters; stay well inside.
MAX_REPORT = 60_000

ICON = {"success": "✅", "failure": "❌", "skipped": "⏭️", "unaffected": "⏭️", "cancelled": "⏹️", "": "⏭️"}


def safe(text: str, limit: int = 300) -> str:
    """A line from the logs as an inline code span that cannot mention,
    link or format anything, with paths shown from the repository root."""
    workspace = os.environ.get("GITHUB_WORKSPACE")
    if workspace:
        text = text.replace(workspace.rstrip("/") + "/", "")
    text = " ".join(text.split())[:limit]
    text = text.replace("`", "'").replace("@", "@​")
    return f"`{text}`" if text else "``"


def plain(text: str, limit: int = 80) -> str:
    """Text from the pull request shown as is when it is only letters, digits
    and plain punctuation, which cannot mention, link or format anything;
    otherwise as a code span."""
    text = " ".join(text.split())[:limit]
    return text if re.fullmatch(r"[A-Za-z0-9 ,.()/%-]+", text) else safe(text, limit)


def read(logs: Path, name: str) -> str:
    try:
        return (logs / name).read_text(errors="replace")
    except OSError:
        return ""


def doc(path: str) -> str:
    """A link to a page of the docs, on the branch the pull request targets."""
    repo = os.environ.get("GITHUB_REPOSITORY", "igharsha7/Burnline-AI-Usage-Tracker")
    base = os.environ.get("BASE_REF") or "main"
    return f"https://github.com/{repo}/blob/{base}/{path}"


def listed(items: list[str]) -> list[str]:
    lines = [f"- {item}" for item in items[:LISTED]]
    if len(items) > LISTED:
        lines.append(f"- …and {len(items) - LISTED} more; see the full log.")
    return lines


def tests_section(log: str, outcome: str) -> tuple[str, list[str]]:
    summary = re.findall(r"Test run with (\d+) tests? in (\d+) suites? (passed|failed)", log)
    if outcome == "success":
        count = f"{summary[-1][0]} tests" if summary else "all tests"
        return f"{count} passed", []

    issues: dict[str, str] = {}
    for name, where, what in re.findall(r'✘ Test "?(.+?)"? recorded an issue at (\S+?):\d+(?::\d+)?: (.+)', log):
        issues.setdefault(name, f"{safe(name, 150)} at {safe(where, 120)}: {safe(what)}")
    if issues:
        detail = [f"**{len(issues)} failing test{'s' if len(issues) != 1 else ''}:**", *listed(list(issues.values())),
                  "",
                  f"Run `swift test --package-path macos/Packages --filter \"<test name>\"` to reproduce. "
                  f"How tests are written: [testing]({doc('docs/testing.md')})."]
        return f"{len(issues)} failing", detail

    errors = sorted({line.strip() for line in log.splitlines() if re.search(r"\berror:", line)})
    if errors:
        detail = ["**The package did not build:**", *listed([safe(e) for e in errors]),
                  "", "Run `swift build --package-path macos/Packages --build-tests` locally."]
        return "did not build", detail
    if "Test run with" not in log and outcome == "failure":
        return "stopped", ["The test run ended without a result, which usually means a test crashed or hung. "
                           "See the full log."]
    return outcome or "not run", []


def headers_section(log: str, outcome: str) -> tuple[str, list[str]]:
    if outcome == "success":
        return "every source file has the header", []
    missing = re.findall(r"error: (\S+) is missing the AGPL license header", log)
    detail = ["**Files missing the license header:**", *listed([safe(m) for m in missing]), "",
              f"Copy the header from any existing source file. See [license headers]({doc('docs/development.md')}#license-headers)."]
    return f"{len(missing)} file{'s' if len(missing) != 1 else ''} missing it", detail


def coverage_section(log: str, outcome: str) -> tuple[str, list[str]]:
    table = re.findall(r"^(Burnline\w+)\s+(\d+)\s+([\d.]+)%$", log, re.MULTILINE)
    figures = ", ".join(f"{m.removeprefix('Burnline')} {p}%" for m, _, p in table)
    if outcome == "success":
        return figures or "no module lost coverage", []
    if outcome in ("skipped", ""):
        return "not checked: the tests did not pass", []
    drops = re.findall(r"coverage fell in (\w+): ([\d.]+)% -> ([\d.]+)%", log)
    detail = ["**Coverage fell below its floor:**",
              *listed([f"{safe(m)}: {was}% → {now}%" for m, was, now in drops]), "",
              "Add tests for the new or changed code. If coverage rose instead, record the new floor with "
              "`macos/scripts/coverage.sh --update-baseline` in this pull request. "
              f"See [coverage]({doc('docs/testing.md')}#coverage)."]
    return figures or "fell", detail


def app_section(log: str, outcome: str) -> tuple[str, list[str]]:
    if outcome == "success":
        return "builds", []
    errors = sorted({line.strip() for line in log.splitlines() if " error: " in line or line.startswith("error:")})
    detail = ["**The app target did not build:**", *listed([safe(e) for e in errors]), "",
              "Build it with `open macos/Burnline.xcodeproj`, or run `xcodebuild -project macos/Burnline.xcodeproj "
              "-scheme Burnline build`. App-target code lives in `macos/Burnline/`; see "
              f"[where things go]({doc('docs/development.md')}#where-things-go)."]
    return "did not build", detail


def number(value) -> str:
    """A figure from the performance results, which the pull request's code wrote."""
    if not isinstance(value, (int, float)):
        return "?"
    return f"{value:,.0f}" if abs(value) >= 100 else f"{value:.2f}"


def perf_section(text: str, outcome: str) -> tuple[str, list[str]]:
    if outcome == "unaffected":
        return "not measured: nothing that affects speed changed", []
    if outcome in ("skipped", ""):
        return "not run", []
    try:
        result = json.loads(text)
        rows = [r for r in result.get("rows", []) if isinstance(r, dict)]
    except (ValueError, AttributeError):
        result, rows = {}, []
    reproduce = ("Reproduce with `BURNLINE_PERF=/tmp/perf swift test --package-path macos/Packages -c release "
                 "--no-parallel --filter PerformanceTests`, before and after your change.")
    if not result.get("ran"):
        return "did not run", ["The performance suites wrote no figures, which usually means they did not build "
                               "or a test crashed. See the full log.", "", reproduce]

    def line(row: dict) -> str:
        base = row.get("base")
        change = row.get("change")
        compared = (f"; base {number(base)}" + (f", {change:+.0%}" if isinstance(change, (int, float)) else "")
                    if isinstance(base, (int, float)) else "")
        return (f"{plain(str(row.get('title', '?')))}: {number(row.get('value'))} {plain(str(row.get('unit', '')), 20)} "
                f"(budget {number(row.get('budget'))}{compared})")

    failing = [r for r in rows if r.get("status") != "ok"]
    table = ["<details><summary>Every figure</summary>", "", "| Measure | This PR | Base | Budget |", "|---|---|---|---|",
             *[f"| {plain(str(r.get('title', '?')))} | {number(r.get('value'))} {plain(str(r.get('unit', '')), 20)} | "
               f"{number(r.get('base')) if r.get('base') is not None else '–'} | {number(r.get('budget'))} |" for r in rows],
             "", "</details>"]
    scope = "against the base branch and the budgets" if result.get("compared") else "against the budgets (no base figures)"
    if outcome == "success" and not failing:
        return f"{len(rows)} figures within budget, checked {scope}", table

    over = [r for r in failing if r.get("status") == "over budget"]
    regressed = [r for r in failing if r.get("status") == "regressed"]
    detail = []
    if over:
        detail += ["**Over budget:**", *listed([line(r) for r in over]), ""]
    if regressed:
        detail += ["**Slower than the base branch, beyond run-to-run noise** (both measured on the same runner):",
                   *listed([line(r) for r in regressed]), ""]
    sections = sorted({str(r.get("doc", "")) for r in failing if str(r.get("doc", "")).replace("-", "").isalnum()})
    page = doc("docs/performance.md")
    links = ", ".join(f"[{s.replace('-', ' ')}]({page}#{s})" for s in sections) or f"[performance]({page})"
    detail += [reproduce, "", f"Budgets and what they protect: {links}. "
               "A pull request that fails this check is not merged until it is fixed, or the maintainer agrees "
               "the budget should change.", "", *table]
    return f"{len(failing)} failing", detail


def main() -> int:
    logs, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    checks = [
        ("Test suite", "TESTS", "tests.log", tests_section),
        ("License headers", "HEADERS", "headers.log", headers_section),
        ("Coverage floor", "COVERAGE", "coverage.log", coverage_section),
        ("App build", "APP", "app.log", app_section),
        ("Performance", "PERF", "perf-result.json", perf_section),
    ]
    rows, details = [], []
    failed = False
    for title, variable, log_name, section in checks:
        outcome = os.environ.get(variable, "")
        failed |= outcome == "failure"
        result, detail = section(read(logs, log_name), outcome)
        rows.append(f"| {ICON.get(outcome, '❔')} {title} | {result} |")
        if detail:
            details += [f"### {title}", "", *detail, ""]

    toolchain = read(logs, "toolchain.log").splitlines()
    run_url = os.environ.get("RUN_URL", "")
    sha = os.environ.get("HEAD_SHA", "")[:7]
    heading = ("## ❌ CI found something to fix" if failed else "## ✅ CI passed")
    intro = ("Every check below must pass before this pull request is reviewed. "
             "Each failure says what went wrong and where to read about it."
             if failed else "Every check passed. A maintainer will review this pull request.")
    report = [MARKER, heading, "", intro, "", "| Check | Result |", "|---|---|", *rows, "", *details,
              "---",
              f"Commit `{sha}` · [full log]({run_url}) · {safe(toolchain[0]) if toolchain else ''} · "
              f"[contributing guide]({doc('CONTRIBUTING.md')}). "
              "This comment is updated on every push."]
    text = "\n".join(report)
    if len(text) > MAX_REPORT:
        text = text[:MAX_REPORT] + "\n\n…the report was cut short; see the full log."
    (out / "report.md").write_text(text + "\n")
    (out / "meta.json").write_text(json.dumps({
        "pr": int(os.environ["PR_NUMBER"]) if os.environ.get("PR_NUMBER", "").isdigit() else None,
        "head_sha": os.environ.get("HEAD_SHA", ""),
        "failed": failed,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())

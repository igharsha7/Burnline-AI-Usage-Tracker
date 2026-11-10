#!/usr/bin/env python3
#
# update_pricing.py
# Burnline
#
# Copyright (C) 2026 Challapalli Harshavardhan Reddy
# Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
"""Turns LiteLLM's current price list into Burnline's append-only price history.

LiteLLM publishes one table of today's rates. Burnline needs rates over time,
so that an old event keeps the price it was charged. This script compares the
table with `pricing.json` and only ever appends:

- a tier or prompt-length band never seen before starts at the Unix epoch:
  "this was the price from the start". It is `exact` for a model new to the
  manifest, whose history begins now, and `reconstructed` for one already
  there (or for every row with --seed), whose earlier price is assumed;
- a rate that changed starts a new version on the day it was observed,
  `exact`, leaving the old version in place so its events keep their cost.

Existing versions are never edited, removed, or reordered, so history cannot
move. Run daily by `.github/workflows/update-pricing.yml`; standard library only.

    python3 shared/pricing/tools/update_pricing.py            # fetch and update
    python3 shared/pricing/tools/update_pricing.py --litellm prices.json --seed
"""

import argparse
import datetime
import json
import re
import sys
import urllib.request
from decimal import Decimal
from pathlib import Path

LITELLM_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
EPOCH = "1970-01-01T00:00:00Z"
SOURCE = "litellm"
MANIFEST_SCHEMA_VERSION = 1

# LiteLLM's provider names, and the Burnline provider whose tools bill there.
PROVIDERS = {"anthropic": "claude_code", "openai": "codex"}
# Model families those tools run. Other entries (image, audio, embeddings,
# resellers' copies under "provider/model") are not usage Burnline sees.
MODEL_PREFIXES = ("claude-", "gpt-", "codex-")
MODES = {"chat", "responses"}
# Tiers a coding tool can run at. Batch pricing never applies to interactive use.
OPENAI_TIERS = ("priority", "flex", "ultrafast")

# LiteLLM field stems for each Burnline rate component.
COMPONENTS = {
    "input": "input_cost_per_token",
    "cachedInput": "cache_read_input_token_cost",
    "cacheWrite": "cache_creation_input_token_cost",
    "output": "output_cost_per_token",
}
BAND = re.compile(r"^input_cost_per_token_above_(\d+)k_tokens(?:_(\w+))?$")


def number(value):
    """A finite, non-negative decimal rate; booleans are not JSON numbers."""
    if isinstance(value, bool) or not isinstance(value, (int, float, Decimal)):
        return None
    value = Decimal(str(value))
    return value if value.is_finite() and value >= 0 else None


def per_million(value):
    """A per-token decimal as a per-million string, rounded half to even
    to the nanodollar, without passing through binary floating point."""
    text = format((Decimal(str(value)) * 1_000_000).quantize(Decimal("1e-9")), "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


def rates_for(entry, suffix, standard=None):
    """The rate set for one tier or band suffix, or None without input and
    output rates. A missing cache rate is scaled from the standard set by this
    tier's input multiple, as providers price cache tiers proportionally."""
    input_rate = number(entry.get(COMPONENTS["input"] + suffix))
    output_rate = number(entry.get(COMPONENTS["output"] + suffix))
    if input_rate is None or output_rate is None:
        return None
    rates = {"input": input_rate, "output": output_rate}
    for name in ("cachedInput", "cacheWrite"):
        own = number(entry.get(COMPONENTS[name] + suffix))
        if own is None and standard is not None and standard.get(name) is not None and standard["input"] > 0:
            own = standard[name] * input_rate / standard["input"]
        if own is not None:
            rates[name] = own
    return rates


def one_hour_rate(entry, suffix):
    return number(entry.get("cache_creation_input_token_cost_above_1hr" + suffix))


def scaled(rates, multiple):
    return {name: value * multiple for name, value in rates.items()}


def rows_for(name, entry):
    """Every (tier, band, rates) LiteLLM gives for one model."""
    provider = entry.get("litellm_provider")
    standard = rates_for(entry, "")
    if standard is None:
        return []
    hour = one_hour_rate(entry, "")
    if provider == "anthropic" and hour is not None:
        standard["cacheWriteOneHour"] = hour
    rows = [("standard", 0, standard)]

    bands = {}
    for field in entry:
        match = BAND.match(field)
        if match and (match.group(2) is None or match.group(2) in OPENAI_TIERS):
            bands.setdefault(int(match.group(1)) * 1000, set()).add(match.group(2) or "standard")
    for threshold, tiers in bands.items():
        if "standard" in tiers:
            suffix = f"_above_{threshold // 1000}k_tokens"
            band = rates_for(entry, suffix, standard)
            if band:
                hour = one_hour_rate(entry, suffix)
                if provider == "anthropic" and hour is not None:
                    band["cacheWriteOneHour"] = hour
                rows.append(("standard", threshold, band))

    if provider == "openai":
        for tier in OPENAI_TIERS:
            tiered = rates_for(entry, f"_{tier}", standard)
            if tiered:
                rows.append((tier, 0, tiered))
            for threshold, tiers in bands.items():
                if tier in tiers:
                    band = rates_for(entry, f"_above_{threshold // 1000}k_tokens_{tier}", tiered or standard)
                    if band:
                        rows.append((tier, threshold, band))
    elif provider == "anthropic":
        specific = entry.get("provider_specific_entry")
        fast = number(specific.get("fast")) if isinstance(specific, dict) else None
        if fast is not None and fast > 0:
            rows += [("fast", threshold, scaled(rates, fast)) for _, threshold, rates in list(rows)]
    return rows


def current_rows(litellm):
    for name, entry in litellm.items():
        if "/" in name or not isinstance(entry, dict) or not name.startswith(MODEL_PREFIXES):
            continue
        provider = PROVIDERS.get(entry.get("litellm_provider"))
        if provider is None or entry.get("mode") not in MODES:
            continue
        for tier, band, rates in rows_for(name, entry):
            yield (provider, name, tier, band), {key: per_million(value) for key, value in rates.items()}


def key_of(version):
    return (version["provider"], version["model"], version["tier"], version.get("abovePromptTokens", 0))


def update(manifest, litellm, today, seed=False):
    """Appends to `manifest` in place; returns the versions added."""
    versions = manifest["versions"]
    latest = {}
    for version in versions:
        if version["source"] != SOURCE:
            continue
        key = key_of(version)
        if key not in latest or version["validFrom"] > latest[key]["validFrom"]:
            latest[key] = version
    known_models = {(v["provider"], v["model"]) for v in versions}

    added = []
    for key, rates in sorted(current_rows(litellm)):
        provider, model, tier, band = key
        previous = latest.get(key)
        if previous is not None and previous["perMillion"] == rates:
            continue
        if previous is None:
            valid_from = EPOCH
            confidence = "reconstructed" if seed or (provider, model) in known_models else "exact"
        else:
            valid_from = today
            confidence = "exact"
            if previous["validFrom"] >= valid_from:
                continue   # Already changed today; the next run records any further change.
        version = {"provider": provider, "model": model, "validFrom": valid_from, "tier": tier}
        if band:
            version["abovePromptTokens"] = band
        version.update({"source": SOURCE, "confidence": confidence, "perMillion": rates})
        added.append(version)
    return added


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--litellm", default=LITELLM_URL, help="URL or path of LiteLLM's price JSON")
    parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parent.parent / "pricing.json")
    parser.add_argument("--seed", action="store_true", help="mark every new row reconstructed (first run)")
    parser.add_argument("--today", help="observation date, YYYY-MM-DD (default: today, UTC)")
    args = parser.parse_args()

    if args.litellm.startswith("https://"):
        with urllib.request.urlopen(args.litellm, timeout=60) as response:
            litellm = json.load(response, parse_float=Decimal)
    else:
        litellm = json.loads(Path(args.litellm).read_text(), parse_float=Decimal)

    now = datetime.datetime.now(datetime.timezone.utc)
    today = (args.today or now.strftime("%Y-%m-%d")) + "T00:00:00Z"
    if args.manifest.exists():
        manifest = json.loads(args.manifest.read_text())
        if manifest.get("schemaVersion") != MANIFEST_SCHEMA_VERSION:
            sys.exit(f"unsupported manifest schema {manifest.get('schemaVersion')}")
    else:
        manifest = {"schemaVersion": MANIFEST_SCHEMA_VERSION, "versions": []}

    added = update(manifest, litellm, today, seed=args.seed)
    if not added:
        print("no price changes")
        return
    original = list(manifest["versions"])
    manifest["versions"] = sorted(original + added,
                                  key=lambda v: (*key_of(v), v["validFrom"], v["source"]))
    assert all(v in manifest["versions"] for v in original), "append-only violated"
    manifest["generatedAt"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    ordered = {"schemaVersion": manifest["schemaVersion"], "generatedAt": manifest["generatedAt"],
               "source": LITELLM_URL, "versions": manifest["versions"]}
    args.manifest.write_text(json.dumps(ordered, indent=1) + "\n")
    print(f"added {len(added)} versions")
    for version in added:
        print(f"  {version['provider']} {version['model']} {version['tier']} "
              f"{version.get('abovePromptTokens', 0)} from {version['validFrom']} ({version['confidence']})")


if __name__ == "__main__":
    main()

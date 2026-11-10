#
# test_update_pricing.py
# Burnline
#
# Copyright (C) 2026 Challapalli Harshavardhan Reddy
# Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
"""Tests for update_pricing.py. Run: python3 -m unittest discover shared/pricing/tools"""

import copy
import unittest
import json
from decimal import Decimal

import update_pricing as up

TODAY = "2026-11-01T00:00:00Z"
OPUS = {"litellm_provider": "anthropic", "mode": "chat", "input_cost_per_token": 4e-06,
        "output_cost_per_token": 2e-05, "cache_read_input_token_cost": 2e-07,
        "cache_creation_input_token_cost": 5e-06, "cache_creation_input_token_cost_above_1hr": 8e-06,
        "provider_specific_entry": {"fast": 2}}
SOL = {"litellm_provider": "openai", "mode": "responses", "input_cost_per_token": 2e-06,
       "output_cost_per_token": 1e-05, "cache_read_input_token_cost": 1e-07,
       "input_cost_per_token_priority": 4e-06, "output_cost_per_token_priority": 2e-05,
       "input_cost_per_token_above_272k_tokens": 4e-06, "output_cost_per_token_above_272k_tokens": 1.5e-05,
       "input_cost_per_token_batches": 1e-06, "output_cost_per_token_batches": 5e-06}
TABLE = {"claude-opus-5-5": OPUS, "gpt-6.1-sol": SOL, "openai/gpt-6.1-sol": SOL,
         "gpt-image-2": {"litellm_provider": "openai", "mode": "image_generation",
                         "input_cost_per_token": 1e-06, "output_cost_per_token": 1e-06}}


def manifest():
    return {"schemaVersion": 1, "versions": []}


class UpdateTests(unittest.TestCase):
    def test_EC_R8_long_prompt_one_hour_cache_rates_are_kept(self):
        entry = copy.deepcopy(OPUS)
        entry.update({"input_cost_per_token_above_200k_tokens": 8e-06,
                      "output_cost_per_token_above_200k_tokens": 4e-05,
                      "cache_creation_input_token_cost_above_1hr_above_200k_tokens": 18e-06})
        rows = up.update(manifest(), {"claude-opus-5-5": entry}, TODAY)
        band = next(v for v in rows if v["tier"] == "standard" and v.get("abovePromptTokens") == 200000)
        self.assertEqual(band["perMillion"].get("cacheWriteOneHour"), "18")
        del entry["cache_creation_input_token_cost_above_1hr_above_200k_tokens"]
        rows = up.update(manifest(), {"claude-opus-5-5": entry}, TODAY)
        band = next(v for v in rows if v["tier"] == "standard" and v.get("abovePromptTokens") == 200000)
        self.assertNotIn("cacheWriteOneHour", band["perMillion"])

    def test_EC_R6_decimal_rates_stay_decimal_through_tiers_and_scaling(self):
        entry = json.loads(json.dumps(SOL), parse_float=Decimal)
        # Decimal arithmetic must distinguish the two sides of a nanodollar tie.
        entry["input_cost_per_token"] = Decimal("0.0000000000000015")
        entry["cache_read_input_token_cost"] = Decimal("0.0000000000000005")
        entry["input_cost_per_token_priority"] = Decimal("0.0000000000000045")
        rows = up.update(manifest(), {"gpt-6.1-sol": entry}, TODAY)
        standard = next(v for v in rows if v["tier"] == "standard" and not v.get("abovePromptTokens"))
        priority = next(v for v in rows if v["tier"] == "priority")
        self.assertEqual(standard["perMillion"]["input"], "0.000000002")
        self.assertEqual(priority["perMillion"]["cachedInput"], "0.000000002")
        self.assertEqual(up.per_million(Decimal("0.0000000000000014999999999999999")), "0.000000001")

    def test_EC_R6_invalid_numeric_rates_are_not_published(self):
        for value in (True, float("inf"), float("nan"), -1):
            with self.subTest(value=value):
                entry = copy.deepcopy(OPUS)
                entry["input_cost_per_token"] = value
                self.assertEqual(up.update(manifest(), {"claude-opus-5-5": entry}, TODAY), [])
        entry = copy.deepcopy(OPUS)
        entry["cache_creation_input_token_cost_above_1hr"] = -1
        rows = up.update(manifest(), {"claude-opus-5-5": entry}, TODAY)
        self.assertTrue(all("cacheWriteOneHour" not in row["perMillion"] for row in rows))

    def test_rates_are_exact_decimals_per_million(self):
        self.assertEqual(up.per_million(2.5e-06), "2.5")
        self.assertEqual(up.per_million(4e-06), "4")
        self.assertEqual(up.per_million(5e-06 * 2), "10")
        self.assertEqual(up.per_million(7.5e-08), "0.075")

    def test_tiers_bands_and_fast_mode_become_rows_and_others_are_skipped(self):
        added = up.update(manifest(), TABLE, TODAY, seed=True)
        keys = {up.key_of(v) for v in added}
        self.assertEqual(keys, {
            ("claude_code", "claude-opus-5-5", "standard", 0), ("claude_code", "claude-opus-5-5", "fast", 0),
            ("codex", "gpt-6.1-sol", "standard", 0), ("codex", "gpt-6.1-sol", "standard", 272000),
            ("codex", "gpt-6.1-sol", "priority", 0),
        })
        fast = next(v for v in added if v["tier"] == "fast")
        self.assertEqual(fast["perMillion"]["cacheWriteOneHour"], "16")
        # A priority cache rate LiteLLM omits scales with the tier's input multiple.
        priority = next(v for v in added if v["tier"] == "priority")
        self.assertEqual(priority["perMillion"]["cachedInput"], "0.2")
        self.assertTrue(all(v["validFrom"] == up.EPOCH and v["confidence"] == "reconstructed" for v in added))

    def test_unchanged_rates_add_nothing(self):
        m = manifest()
        m["versions"] = up.update(m, TABLE, TODAY, seed=True)
        self.assertEqual(up.update(m, TABLE, TODAY), [])

    def test_a_changed_rate_appends_a_version_from_today_and_keeps_the_old(self):
        m = manifest()
        m["versions"] = up.update(m, TABLE, "2026-10-01T00:00:00Z", seed=True)
        before = copy.deepcopy(m["versions"])
        cheaper = copy.deepcopy(TABLE)
        cheaper["gpt-6.1-sol"]["output_cost_per_token"] = 8e-06
        added = up.update(m, cheaper, TODAY)
        self.assertEqual([(v["tier"], v.get("abovePromptTokens", 0)) for v in added], [("standard", 0)])
        self.assertEqual(added[0]["validFrom"], TODAY)
        self.assertEqual(added[0]["confidence"], "exact")
        self.assertEqual(added[0]["perMillion"]["output"], "8")
        self.assertEqual(m["versions"], before)

    def test_a_new_model_is_exact_from_the_start(self):
        m = manifest()
        m["versions"] = up.update(m, {"claude-opus-5-5": OPUS}, TODAY, seed=True)
        added = up.update(m, TABLE, TODAY)
        self.assertTrue(added and all(v["model"] == "gpt-6.1-sol" for v in added))
        self.assertTrue(all(v["confidence"] == "exact" and v["validFrom"] == up.EPOCH for v in added))


if __name__ == "__main__":
    unittest.main()

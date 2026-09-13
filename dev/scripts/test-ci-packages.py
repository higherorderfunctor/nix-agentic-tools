#!/usr/bin/env python3
"""Exercise the package coverage gate without evaluating or building Nix."""

import copy
import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("ci_packages", Path(__file__).with_name("ci-packages.py"))
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)


class CoverageTest(unittest.TestCase):
    def setUp(self):
        self.names = ["alpha", "beta", "delta", "epsilon", "gamma", "new-package", "kiro-cli-workflows"]
        self.plans = [ci.partition(self.names, i, 5) for i in range(5)]

    def test_added_package_is_covered_and_patched_kiro_excluded(self):
        ci.validate_coverage(self.plans, 5)
        names = [n for p in self.plans for n in p["packages"]]
        self.assertEqual(names.count("new-package"), 1)
        self.assertNotIn("kiro-cli-workflows", names)

    def test_missing_duplicate_or_different_source_shards_fail(self):
        changed = copy.deepcopy(self.plans)
        changed[0]["universe"].append("unexpected")
        for plans in (self.plans[:-1], [self.plans[0]] * 5, changed):
            with self.subTest(plans=plans), self.assertRaises(ValueError):
                ci.validate_coverage(plans, 5)

    def test_empty_enumeration_and_empty_shard_fail(self):
        for names in ([], ["alpha"]):
            with self.assertRaises(ValueError):
                ci.partition(names, 4, 5)

    def test_aliases_share_a_successfully_built_derivation(self):
        plan = {"packages": ["alpha", "alias"]}
        results = [
            {"attr": "alpha", "type": "EVAL", "success": True, "drvPath": "/nix/store/same.drv"},
            {"attr": "alias", "type": "EVAL", "success": True, "drvPath": "/nix/store/same.drv"},
            {"attr": "alpha", "type": "BUILD", "success": True},
        ]
        ci.validate_results(plan, {"results": results})
        results[1]["drvPath"] = "/nix/store/different.drv"
        with self.assertRaises(ValueError):
            ci.validate_results(plan, {"results": results})

    def test_cached_and_built_results_pass(self):
        plan = {"packages": ["alpha", "beta"]}
        results = [
            {"attr": "alpha", "type": "EVAL", "success": True, "cacheStatus": "cached"},
            {"attr": "beta", "type": "EVAL", "success": True},
            {"attr": "beta", "type": "BUILD", "success": True},
        ]
        ci.validate_results(plan, results)
        ci.validate_results(plan, {"results": results})
        for broken in (
            [], {}, {"results": []}, results[:-1], results[1:], results + [results[0]],
            results + [{"attr": "beta", "type": "CACHIX", "success": False}],
        ):
            with self.subTest(results=broken), self.assertRaises(ValueError):
                ci.validate_results(plan, broken)
        for change in ({"success": False}, {"skipped": True}, {"error": "eval failed"}):
            broken = copy.deepcopy(results)
            broken[0].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                ci.validate_results(plan, broken)


if __name__ == "__main__":
    unittest.main()

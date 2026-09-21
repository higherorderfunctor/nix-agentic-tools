#!/usr/bin/env python3
"""Exercise the package coverage gate without evaluating or building Nix."""

import copy
import importlib.util
import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("ci_packages", Path(__file__).with_name("ci-packages.py"))
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)


class CacheAssertionTest(unittest.TestCase):
    def test_patched_cache_assertion_requires_complete_enumeration(self):
        workflow = Path(__file__).parents[2] / ".github/workflows/ci.yml"
        step = workflow.read_text().split("      - name: Assert the patched output is not published\n", 1)[1]
        lines = []
        for line in step.split("        run: |\n", 1)[1].splitlines():
            if line and not line.startswith("          "):
                break
            lines.append(line)
        script = textwrap.dedent("\n".join(lines))
        # Execute the workflow's shell, replacing only the external services.
        services = r'''set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
nix() {
  if [ "$1" = derivation ]; then
    printf '%s\n' '{"base":{"outputs":{"out":{"path":"/nix/store/base-kiro"}}}}'
    return
  fi
  case "$MODE" in
    fail) return 1 ;;
    partial) printf '%s\n' "$OUT"; return 1 ;;
    empty) return ;;
    missing) printf '%s\n' /nix/store/unrelated; return ;;
    *) printf '%s\n' "$OUT" /nix/store/base-kiro ;;
  esac
}
curl() {
  case "$*" in *nix-cache-info*) return ;; esac
  printf 'narinfo\n' >> "$RUNNER_TEMP/queries"
  printf '%s' "$HTTP_CODE"
}
'''
        with tempfile.TemporaryDirectory() as directory:
            queries = Path(directory) / "queries"
            for mode, http_code, success, queried in (
                ("fail", "404", False, False),
                ("partial", "404", False, False),
                ("empty", "404", False, False),
                ("missing", "404", False, False),
                ("complete", "404", True, True),
                ("complete", "200", False, True),
                ("complete", "503", False, True),
            ):
                with self.subTest(mode=mode, http_code=http_code):
                    queries.unlink(missing_ok=True)
                    env = dict(os.environ, CACHE="https://cache.invalid", HTTP_CODE=http_code,
                               MODE=mode, OUT="/nix/store/patched-kiro", RUNNER_TEMP=directory,
                               SYSTEM="x86_64-linux")
                    result = subprocess.run(["bash", "-c", services + script], env=env,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
                    self.assertEqual(queries.exists(), queried, result.stdout + result.stderr)


class CoverageTest(unittest.TestCase):
    def setUp(self):
        self.names = ["alpha", "beta", "delta", "epsilon", "gamma", "new-package", "qwen3-embedding-0.6b-q8_0", "kiro-cli-workflows"]
        self.plans = [ci.partition(self.names, i, 5) for i in range(5)]

    def test_added_package_is_covered_and_patched_kiro_excluded(self):
        ci.validate_coverage(self.plans, 5)
        names = [n for p in self.plans for n in p["packages"]]
        self.assertEqual(names.count("new-package"), 1)
        self.assertNotIn("kiro-cli-workflows", names)
        self.assertEqual(names.count("qwen3-embedding-0.6b-q8_0"), 1)

    def test_quoted_flat_attribute_receipt_matches_enumeration(self):
        name = "qwen3-embedding-0.6b-q8_0"
        results = {"results": [{"type": "EVAL", "attr": json.dumps(name),
                                "success": True, "cacheStatus": "local"}]}
        ci.validate_result_coverage([name], results)
        results["results"][0]["attr"] = '"qwen3-embedding-0"."6b-q8_0"'
        with self.assertRaises(ValueError):
            ci.validate_result_coverage([name], results)

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

    def test_update_coverage_distinguishes_incomplete_from_ordinary_red(self):
        expected = ["alpha", "alias", "cached", "compiler-failure"]
        complete_red = [
            {"attr": "alpha", "type": "EVAL", "success": True, "drvPath": "/nix/store/same.drv"},
            {"attr": "alias", "type": "EVAL", "success": True, "drvPath": "/nix/store/same.drv"},
            {"attr": "cached", "type": "EVAL", "success": True, "cacheStatus": "cached"},
            {"attr": "compiler-failure", "type": "EVAL", "success": True, "drvPath": "/nix/store/red.drv"},
            {"attr": "alpha", "type": "BUILD", "success": True},
            {"attr": "compiler-failure", "type": "BUILD", "success": False, "error": "compiler failed"},
        ]
        self.assertEqual(ci.validate_result_coverage(expected, complete_red), complete_red)
        for incomplete in (
            {"results": []},
            complete_red[1:],
            [row for row in complete_red if row.get("attr") != "alias"],
            [row for row in complete_red if row.get("type") != "BUILD"],
        ):
            with self.subTest(results=incomplete), self.assertRaises(ValueError):
                ci.validate_result_coverage(expected, incomplete)


if __name__ == "__main__":
    unittest.main()

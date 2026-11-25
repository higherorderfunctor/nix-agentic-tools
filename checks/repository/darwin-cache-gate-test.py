"""Offline positive and negative controls for the required Darwin CI gate."""

import io
import json
import runpy
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

SCRIPT, FIXTURES = map(Path, sys.argv[1:])
GATE = runpy.run_path(SCRIPT)
EXPECTED = json.loads((FIXTURES / "expected.json").read_text())
PLAN = (FIXTURES / "dry-run.txt").read_text()
# Nix 2.35.6 Darwin plan rows and v4 metadata, reduced to the fields the
# scanner reads, with synthetic records for the exclusion edge cases.
RECORDS = json.dumps({
    "version": 4,
    "derivations": json.loads((FIXTURES / "derivations.json").read_text()),
})
DOWNLOAD, = EXPECTED["downloads"]
COMPILER, = EXPECTED["compilerBuilds"]
CHECK, = EXPECTED["checkDrvs"]
PACKAGE, = EXPECTED["packageDrvs"]
CHECKS = {"ordinary-check": CHECK, "kiro-kas-dispatch": EXPECTED["alreadyBuiltCheck"]}
ROOTS = {
    "cache": {
        "extra-substituters": ["https://fixture.cachix.org"],
        "extra-trusted-public-keys": ["fixture.cachix.org-1:test"],
    },
    "packages": {"native-package": PACKAGE},
    "runtime": {"home-services": EXPECTED["homeServices"]},
}


def run_scan(checks=CHECKS):
    GATE["scan"](checks, ROOTS, built_checks=["kiro-kas-dispatch"], dry_run=False)


def build_response(log):
    return subprocess.CompletedProcess([], 0, stderr=log)


def scan_responses(*remaining):
    drvs = subprocess.CompletedProcess([], 0, stdout=RECORDS)
    return [build_response(PLAN), drvs, drvs, *remaining]


class CacheGateTest(unittest.TestCase):
    def test_scan_realizes_only_the_retained_download(self):
        responses = scan_responses(build_response(f"this derivation will be built:\n  {DOWNLOAD}\n"), None)
        with patch("subprocess.run", side_effect=responses) as nix, redirect_stdout(io.StringIO()) as stdout:
            run_scan()
        plan, _, closure, replan, realize = nix.call_args_list
        self.assertIn(f"{ROOTS['runtime']['home-services']}^*\n", plan.kwargs["input"])
        self.assertIn("--recursive", closure.args[0])
        self.assertEqual(closure.kwargs["input"].splitlines(), sorted([PACKAGE, CHECKS["kiro-kas-dispatch"]]))
        self.assertIn("--dry-run", replan.args[0])
        self.assertNotIn("--dry-run", realize.args[0])
        for call in [replan, realize]:
            self.assertEqual(call.kwargs["input"], f"{DOWNLOAD}^*\n")
        for call in [plan, replan, realize]:
            options = call.args[0]
            self.assertEqual(options[options.index("substituters") + 1], "https://cache.nixos.org https://fixture.cachix.org")
            self.assertEqual(options[options.index("extra-substituters") + 1], "")
            self.assertEqual(options[options.index("fallback") + 1], "false")
        self.assertIn(f"::warning::Uncached Darwin compiler builds (not built by this gate):%0A{COMPILER}\n", stdout.getvalue())
        self.assertIn(f"Fixed-output candidate: {DOWNLOAD}\n", stdout.getvalue())
        self.assertIn(f"Verifying {DOWNLOAD}\n", stdout.getvalue())

    def test_scan_preserves_realization_failure(self):
        failure = subprocess.CalledProcessError(1, ["nix", "build"])
        responses = scan_responses(build_response(f"this derivation will be built:\n  {DOWNLOAD}\n"), failure)
        with patch("subprocess.run", side_effect=responses), redirect_stdout(io.StringIO()):
            with self.assertRaises(subprocess.CalledProcessError) as result:
                run_scan()
        self.assertIs(result.exception, failure)

    def test_scan_warns_and_skips_a_download_with_an_uncached_build_dependency(self):
        blocked = build_response(f"these 2 derivations will be built:\n  {DOWNLOAD}\n  {COMPILER}\n")
        with patch("subprocess.run", side_effect=scan_responses(blocked, blocked)) as nix, redirect_stdout(io.StringIO()) as stdout:
            run_scan()
        self.assertEqual(nix.call_count, 5)
        for call in nix.call_args_list:
            if call.args[0][1] == "build":
                self.assertIn("--dry-run", call.args[0])
        self.assertIn(f"::warning::Cannot check fixed output {DOWNLOAD} without building:%0A{COMPILER}\n", stdout.getvalue())

    def test_scan_rejects_missing_plan_probe(self):
        for plan in [f"these will be realized:\n  {DOWNLOAD}\n", f"this derivation will be built:\n  {DOWNLOAD}\n"]:
            with self.subTest(plan=plan), patch("subprocess.run", return_value=build_response(plan)) as nix, redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(ValueError, "uncached home-services probe"):
                    run_scan()
                self.assertEqual(nix.call_count, 1)

    def test_scan_rejects_empty_roots_before_calling_nix(self):
        with patch("subprocess.run") as nix, self.assertRaisesRegex(ValueError, "nonempty"):
            run_scan(checks={})
        nix.assert_not_called()

    def test_parser_rejects_a_truncated_build_block(self):
        with self.assertRaisesRegex(ValueError, "malformed Nix dry-run build block"):
            GATE["planned_builds"]("this derivation will be built:\n")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])

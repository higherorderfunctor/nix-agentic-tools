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
RECORDS = json.loads((FIXTURES / "derivations.json").read_text())
DERIVATION_RESPONSE = subprocess.CompletedProcess([], 0, stdout=json.dumps({"version": 4, "derivations": RECORDS}))
DOWNLOAD, = EXPECTED["downloads"]
DOWNLOAD_PLAN = f"this derivation will be built:\n  {DOWNLOAD}\n"
COMPILER, = EXPECTED["compilerBuilds"]
CHECK, = EXPECTED["checkDrvs"]
PACKAGE, = EXPECTED["packageDrvs"]
HOME_SERVICES = EXPECTED["homeServices"]
HOME_SERVICES_OUTPUT = RECORDS[Path(HOME_SERVICES).name]["env"]["out"]
CHECKS = {"ordinary-check": CHECK, "kiro-kas-dispatch": EXPECTED["alreadyBuiltCheck"]}
ROOTS = {
    "cache": {
        "extra-substituters": ["https://fixture.cachix.org"],
        "extra-trusted-public-keys": ["fixture.cachix.org-1:test"],
    },
    "packages": {"native-package": PACKAGE},
    "runtime": {"home-services": HOME_SERVICES},
}


def run_scan(checks=CHECKS, roots=ROOTS):
    GATE["scan"](checks, roots, built_checks=["kiro-kas-dispatch"], dry_run=False)


def build_response(log):
    return subprocess.CompletedProcess([], 0, stderr=log)


def scan_responses(*remaining):
    return [build_response(PLAN), DERIVATION_RESPONSE, DERIVATION_RESPONSE, *remaining]


class CacheGateTest(unittest.TestCase):
    def test_scan_realizes_only_the_retained_download(self):
        responses = scan_responses(build_response(DOWNLOAD_PLAN), None)
        with patch("subprocess.run", side_effect=responses) as nix, redirect_stdout(io.StringIO()) as stdout:
            run_scan()
        plan, _, closure, replan, realize = nix.call_args_list
        self.assertIn("--dry-run", plan.args[0])
        self.assertCountEqual(
            plan.kwargs["input"].splitlines(),
            [f"{path}^*" for path in (CHECK, CHECKS["kiro-kas-dispatch"], HOME_SERVICES, PACKAGE)],
        )
        self.assertIn("--recursive", closure.args[0])
        self.assertEqual(closure.kwargs["input"].splitlines(), sorted([PACKAGE, CHECKS["kiro-kas-dispatch"]]))
        self.assertIn("--dry-run", replan.args[0])
        self.assertNotIn("--dry-run", realize.args[0])
        self.assertIs(realize.kwargs.get("check"), True)
        for call in [replan, realize]:
            self.assertEqual(call.kwargs["input"], f"{DOWNLOAD}^*\n")
        for call in [plan, replan, realize]:
            options = call.args[0]
            self.assertEqual(options[options.index("substituters") + 1], "https://cache.nixos.org https://fixture.cachix.org")
            self.assertEqual(options[options.index("extra-substituters") + 1], "")
            self.assertEqual(options[options.index("fallback") + 1], "false")
        output = stdout.getvalue()
        reports = [
            line for line in output.splitlines()
            if line.startswith(("::warning::", "Fixed-output candidate:"))
        ]
        self.assertCountEqual(
            reports,
            [
                f"::warning::Uncached Darwin compiler builds (not built by this gate):%0A{COMPILER}",
                f"Fixed-output candidate: {DOWNLOAD}",
            ],
        )
        self.assertIn(f"Verifying {DOWNLOAD}\n", output)

    def test_scan_preserves_realization_failure(self):
        failure = subprocess.CalledProcessError(1, ["nix", "build"])
        responses = scan_responses(build_response(DOWNLOAD_PLAN), failure)
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
        plans = {
            # A fetched output is not evidence that the probe was planned to build.
            "probe is only fetched": (
                DOWNLOAD_PLAN
                + "this path will be fetched (0.02 MiB download, 0.04 MiB unpacked):\n"
                f"  {HOME_SERVICES_OUTPUT}\n"
            ),
            "unrecognized plan": f"these will be realized:\n  {DOWNLOAD}\n",
        }
        for case, plan in plans.items():
            with (
                self.subTest(case=case),
                patch("subprocess.run", return_value=build_response(plan)) as nix,
                redirect_stdout(io.StringIO()),
            ):
                with self.assertRaisesRegex(ValueError, "did not report the uncached home-services probe"):
                    run_scan()
                nix.assert_called_once()

    def test_scan_rejects_empty_roots_before_calling_nix(self):
        cases = {
            "checks": ({}, ROOTS),
            "packages": (CHECKS, {**ROOTS, "packages": {}}),
            "runtime": (CHECKS, {**ROOTS, "runtime": {}}),
        }
        for missing, (checks, roots) in cases.items():
            with self.subTest(missing=missing), patch("subprocess.run") as nix:
                with self.assertRaisesRegex(ValueError, "requires nonempty check, package and consumer roots"):
                    run_scan(checks=checks, roots=roots)
                nix.assert_not_called()

    def test_parser_rejects_a_truncated_build_block(self):
        with self.assertRaisesRegex(ValueError, "malformed Nix dry-run build block"):
            GATE["planned_builds"]("this derivation will be built:\n")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])

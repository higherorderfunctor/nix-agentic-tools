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
        # Pin the roots and the work done: this gate verifies the wheel even
        # with preferLocalBuild, but never takes over existing build jobs.
        responses = scan_responses(build_response(DOWNLOAD_PLAN), None)
        with patch("subprocess.run", side_effect=responses) as nix, redirect_stdout(io.StringIO()) as stdout:
            run_scan()
        plan, _, closure, replan, realize = nix.call_args_list
        self.assertCountEqual(
            plan.kwargs["input"].splitlines(),
            [f"{path}^*" for path in (CHECK, CHECKS["kiro-kas-dispatch"], HOME_SERVICES, PACKAGE)],
        )
        self.assertIn("--recursive", closure.args[0])
        self.assertEqual(closure.kwargs["input"].splitlines(), sorted([PACKAGE, CHECKS["kiro-kas-dispatch"]]))
        self.assertNotIn("--dry-run", realize.args[0])
        self.assertIs(realize.kwargs.get("check"), True)
        self.assertEqual(realize.kwargs["input"], f"{DOWNLOAD}^*\n")
        # All three calls need the same cache policy; a fallback or a remote
        # builder can compile the dependency this gate was meant only to fetch.
        cache_options = {
            "builders": "",
            "extra-substituters": "",
            "extra-trusted-public-keys": "fixture.cachix.org-1:test",
            "fallback": "false",
            "substituters": "https://cache.nixos.org https://fixture.cachix.org",
        }
        for call in [plan, replan, realize]:
            options = call.args[0]
            for option, value in cache_options.items():
                with self.subTest(option=option, command=options):
                    self.assertEqual(options[options.index(option) + 1], value)
        # Structured allowSubstitutes=false wins over the legacy env value.
        # Neither a native dependency nor its alias with the same output path
        # is a download candidate; ordinary checks are excluded by drv path.
        # Only the unrelated compiler build is warned about, not the wrapper
        # that uses stdenv without a compiler or the compiler dependency of
        # the already-built check. The fetched output needs no work either.
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

    def test_scan_preserves_realization_failure(self):
        # A failed fixed output must escape the scanner, not become a warning.
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
        # The individual retry can still need a compiler. Neither that retry
        # nor the batch replan is allowed to realize the blocked download.
        plan, _, _, replan, retry = nix.call_args_list
        for call in [plan, replan, retry]:
            self.assertEqual(call.args[0][1:3], ["build", "--dry-run"])
        for call in [replan, retry]:
            self.assertEqual(call.kwargs["input"], f"{DOWNLOAD}^*\n")
        self.assertIn(f"::warning::Cannot check fixed output {DOWNLOAD} without building:%0A{COMPILER}\n", stdout.getvalue())

    def test_scan_rejects_an_untrustworthy_plan(self):
        plans = {
            # A plan with no recognized builds is not a successful no-op.
            "no recognized build header": (
                f"these will be realized:\n  {DOWNLOAD}\n",
                "did not report the uncached home-services probe",
            ),
            # Even a .drv store path in the fetch block is not a planned build.
            "probe derivation is only fetched": (
                DOWNLOAD_PLAN
                + "this path will be fetched (0.02 MiB download, 0.04 MiB unpacked):\n"
                f"  {HOME_SERVICES}\n",
                "did not report the uncached home-services probe",
            ),
            # A changed build header must fail even if the probe is listed.
            "unrecognized build header": (
                f"these derivations will be built:\n  {HOME_SERVICES}\n",
                "unexpected Nix dry-run header",
            ),
        }
        for case, (plan, message) in plans.items():
            with (
                self.subTest(case=case),
                patch("subprocess.run", return_value=build_response(plan)) as nix,
                redirect_stdout(io.StringIO()),
            ):
                with self.assertRaisesRegex(ValueError, message):
                    run_scan()
                nix.assert_called_once()

    def test_scan_rejects_empty_roots_before_calling_nix(self):
        # Dropping any one conjunct lets the gate silently scan a partial plan.
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
        # A recognized header with a missing row must not yield a partial plan.
        with self.assertRaisesRegex(ValueError, "malformed Nix dry-run build block"):
            GATE["planned_builds"]("this derivation will be built:\n")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])

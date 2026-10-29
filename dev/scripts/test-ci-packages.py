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


def ci_step_script(name):
    """The dedented `run:` body of the ci.yml step called `name`."""
    workflow = Path(__file__).parents[2] / ".github/workflows/ci.yml"
    step = workflow.read_text().split(f"      - name: {name}\n", 1)[1]
    lines = []
    for line in step.split("        run: |\n", 1)[1].splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line)
    return textwrap.dedent("\n".join(lines))


class CachixPushFilterTest(unittest.TestCase):
    def test_every_credentialed_cachix_step_filters_kiro_and_codeql(self):
        # cachix-action with a token pushes every path the job realizes, so the
        # audit is by credential: any step holding the token must exclude kiro
        # and the CodeQL engines, whose terms forbid distributing them.
        steps = 0
        for workflow in sorted((Path(__file__).parents[2] / ".github/workflows").glob("*.yml")):
            for chunk in workflow.read_text().split("uses: cachix/cachix-action@")[1:]:
                step = chunk.split("\n      - ", 1)[0]
                if "CACHIX_AUTH_TOKEN" in step:
                    steps += 1
                    self.assertIn("pushFilter: kiro-cli|codeql\n", step + "\n", workflow.name)
        self.assertGreater(steps, 0)

    def test_devenv_update_lane_does_not_push(self):
        # The devenv lane's shell-entry check realizes the patched Kiro inside
        # the shell's closure, which pushFilter does not cover (2026-10-17).
        workflow = Path(__file__).parents[2] / ".github/workflows/update.yml"
        step = workflow.read_text().split("uses: cachix/cachix-action@", 1)[1].split("\n      - ", 1)[0]
        self.assertIn("skipPush: ${{ matrix.name == 'devenv' }}\n", step + "\n")


class CacheAssertionTest(unittest.TestCase):
    def test_patched_cache_assertion_requires_complete_enumeration(self):
        script = ci_step_script("Assert the patched output is not published")
        # The macOS leg runs this step with /bin/bash 3.2, which has neither.
        self.assertNotRegex(script, r"\b(mapfile|readarray)\b")
        # Execute the workflow's shell, replacing only the external services.
        # Exported, so dev/scripts/assert-not-published.sh, which the step
        # calls, sees the same mocks.
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
    root-only) printf '%s\n' "$OUT"; return ;;
    *) printf '%s\n' "$OUT" /nix/store/base-kiro ;;
  esac
}
curl() {
  case "$*" in *nix-cache-info*) return ;; esac
  printf 'narinfo\n' >> "$RUNNER_TEMP/queries"
  printf '%s' "$HTTP_CODE"
}
export -f curl nix
'''
        with tempfile.TemporaryDirectory() as directory:
            queries = Path(directory) / "queries"
            for mode, http_code, success, queried in (
                ("fail", "404", False, False),
                ("partial", "404", False, False),
                ("empty", "404", False, False),
                ("missing", "404", False, False),
                # A listing with its root but no kiro path asks nothing.
                ("root-only", "404", False, False),
                ("complete", "404", True, True),
                ("complete", "200", False, True),
                ("complete", "503", False, True),
            ):
                with self.subTest(mode=mode, http_code=http_code):
                    queries.unlink(missing_ok=True)
                    env = dict(os.environ, CACHE="https://cache.invalid", HTTP_CODE=http_code,
                               MODE=mode, RUNNER_TEMP=directory,
                               OUT="/nix/store/patched-other" if mode == "root-only" else "/nix/store/patched-kiro",
                               SYSTEM="x86_64-linux")
                    result = subprocess.run(["bash", "-c", services + script], env=env,
                                            capture_output=True, text=True,
                                            cwd=Path(__file__).parents[2])
                    self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
                    self.assertEqual(queries.exists(), queried, result.stdout + result.stderr)


    def test_codeql_assertion_requires_every_engine_source_and_database(self):
        script = ci_step_script("Assert no CodeQL engine or database is published")
        # Two engines, each with its source, the Kimchi release database, and
        # the network check with its fixture database and customized engine.
        # MODE drops one source, every engine, the fixture database or the
        # customized engine, or fails an evaluation; PUBLISHED names the hash
        # whose narinfo answers 200.
        services = r'''set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
nix() {
  case "$MODE" in empty) return ;; esac
  case "$*" in
    *codeql.database.drvPath*)
      [ "$MODE" != nodb ] || return 1
      printf '%s' /nix/store/f-kimchi-codeql-database-1.drv
      return
      ;;
    *kimchi-codeql-network.drvPath*)
      [ "$MODE" != no-check ] || return 1
      printf '%s' /nix/store/g-kimchi-codeql-network-check.drv
      return
      ;;
  esac
  printf '%s\n' /nix/store/a-codeql-bare-1.drv /nix/store/b-codeql-full-1.drv
}
nix-store() {
  case "$2:$3" in
    --requisites:*/f-kimchi-codeql-database-1.drv)
      printf '%s\n' /nix/store/a-codeql-bare-1.drv /nix/store/f-kimchi-codeql-database-1.drv \
        /nix/store/g-kimchi-codeql-network-check.drv /nix/store/e-glibc-1.drv
      [ "$MODE" = no-fixture ] || printf '%s\n' /nix/store/h-kimchi-codeql-database-network-fixture.drv
      [ "$MODE" = no-customized ] || printf '%s\n' /nix/store/i-codeql-javascript-customized-1.drv
      ;;
    --requisites:*)
      printf '%s\n' /nix/store/a-codeql-bare-1.drv /nix/store/b-codeql-full-1.drv \
        /nix/store/c-codeql-linux64.zip.drv /nix/store/e-glibc-1.drv
      [ "$MODE" = missing ] || printf '%s\n' /nix/store/d-codeql-bundle-linux64.tar.zst.drv
      ;;
    --outputs:*) shift 2; for drv in "$@"; do printf '%s\n' "${drv%.drv}"; done ;;
  esac
}
curl() {
  case "$*" in *nix-cache-info*) return ;; esac
  printf 'narinfo\n' >> "$RUNNER_TEMP/queries"
  case "$*" in
    */"$PUBLISHED".narinfo*) printf 200 ;;
    *) printf '%s' "$HTTP_CODE" ;;
  esac
}
export -f curl nix nix-store
'''
        with tempfile.TemporaryDirectory() as directory:
            queries = Path(directory) / "queries"
            for mode, http_code, published, success, queried in (
                ("empty", "404", "", False, False),
                ("missing", "404", "", False, False),
                ("nodb", "404", "", False, False),
                ("no-check", "404", "", False, False),
                ("no-fixture", "404", "", False, False),
                ("no-customized", "404", "", False, False),
                ("complete", "404", "", True, True),
                ("complete", "200", "", False, True),
                # The fixture database or the customized engine alone published.
                ("complete", "404", "h", False, True),
                ("complete", "404", "i", False, True),
            ):
                with self.subTest(mode=mode, http_code=http_code, published=published):
                    queries.unlink(missing_ok=True)
                    env = dict(os.environ, CACHE="https://cache.invalid", HTTP_CODE=http_code,
                               MODE=mode, PUBLISHED=published or "none", RUNNER_TEMP=directory)
                    result = subprocess.run(["bash", "-c", services + script], env=env,
                                            capture_output=True, text=True,
                                            cwd=Path(__file__).parents[2])
                    self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
                    self.assertEqual(queries.exists(), queried, result.stdout + result.stderr)
                    if success:
                        # Four engine derivations, the release and fixture
                        # databases, the check and the customized engine; the
                        # engine the check needs again is asked once.
                        self.assertEqual(len(queries.read_text().splitlines()), 8)

class CheckBundlesTest(unittest.TestCase):
    def bundle(self, rows):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "matrix.json").write_text(json.dumps({"include": rows}))
            result = subprocess.run(
                ["bash", "-c", ci_step_script("Bundle uncached checks into at most four workers")],
                env=dict(os.environ, GITHUB_OUTPUT=f"{directory}/output", RUNNER_TEMP=directory),
                capture_output=True, text=True,
            )
            if result.returncode:
                return result.stderr
            return json.loads((Path(directory) / "bundled-matrix.json").read_text())["include"]

    def test_hestia_rows_bundle_into_at_most_four_workers(self):
        # Hestia's row shape: `os` is a runs-on label list.
        rows = [{"installables": f"/nix/store/{i}-check.drv^*", "name": f"group-{i}", "os": ["ubuntu-latest"]}
                for i in range(9)]
        bundles = self.bundle(rows)
        self.assertEqual(len(bundles), 4)
        self.assertTrue(all(b["os"] == ["ubuntu-latest"] for b in bundles))
        self.assertCountEqual(" ".join(b["installables"] for b in bundles).split(),
                              [row["installables"] for row in rows])
        self.assertEqual(self.bundle([]), [])

    def test_multiple_runner_os_labels_are_rejected(self):
        self.assertIn("multiple runner OS labels", self.bundle([
            {"installables": "/nix/store/first.drv^*", "os": ["ubuntu-latest"]},
            {"installables": "/nix/store/second.drv^*", "os": ["macos-latest"]},
        ]))


class CoverageTest(unittest.TestCase):
    def setUp(self):
        self.names = ["alpha", "beta", "codeql-javascript", "codeql-new-engine", "delta", "epsilon", "gamma", "new-package", "kiro-cli-rollout-canary"]
        self.plans = [ci.partition(self.names, i, 2) for i in range(2)]

    def test_added_package_is_covered_and_unpublishable_excluded(self):
        ci.validate_coverage(self.plans, 2)
        names = [n for p in self.plans for n in p["packages"]]
        self.assertEqual(names.count("new-package"), 1)
        self.assertNotIn("kiro-cli-rollout-canary", names)
        # Every engine, including one added later, by prefix.
        self.assertFalse([n for n in names if n.startswith("codeql-")])

    def test_update_lanes_build_every_package_but_the_engines(self):
        packages = ci.update_packages(self.names)
        self.assertIn("kiro-cli-rollout-canary", packages)
        self.assertFalse([n for n in packages if n.startswith("codeql-")])
        with self.assertRaises(ValueError):
            ci.update_packages(["codeql-javascript"])

    def test_missing_duplicate_or_different_source_shards_fail(self):
        changed = copy.deepcopy(self.plans)
        changed[0]["universe"].append("unexpected")
        for plans in (self.plans[:-1], [self.plans[0]] * 2, changed):
            with self.subTest(plans=plans), self.assertRaises(ValueError):
                ci.validate_coverage(plans, 2)

    def test_coverage_reads_both_download_artifact_layouts(self):
        # download-artifact v5+ extracts a lone pattern match straight into
        # the path, and two or more matches into per-artifact directories.
        script = Path(__file__).with_name("ci-packages.py")
        for count in (1, 2):
            plans = [ci.partition(self.names, i, count) for i in range(count)]
            with self.subTest(count=count), tempfile.TemporaryDirectory() as root:
                for i, plan in enumerate(plans):
                    folder = Path(root) / f"packages-x86_64-linux-{i}" if count > 1 else Path(root)
                    folder.mkdir(exist_ok=True)
                    (folder / "receipt.json").write_text(json.dumps(plan))
                subprocess.run([os.sys.executable, str(script), "coverage", root, str(count)], check=True)

    def test_empty_enumeration_and_empty_shard_fail(self):
        for names in ([], ["alpha"]):
            with self.assertRaises(ValueError):
                ci.partition(names, 1, 2)

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

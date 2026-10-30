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
from unittest import mock

SPEC = importlib.util.spec_from_file_location("ci_packages", Path(__file__).with_name("ci-packages.py"))
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)

EXTRACTED_SPEC = importlib.util.spec_from_file_location("ci_extracted_facts", Path(__file__).with_name("ci-extracted-facts.py"))
extracted = importlib.util.module_from_spec(EXTRACTED_SPEC)
EXTRACTED_SPEC.loader.exec_module(extracted)


def ci_step_script(name, workflow_name="ci.yml"):
    """The dedented `run:` body of a named CI workflow step."""
    workflow = Path(__file__).parents[2] / ".github/workflows" / workflow_name
    step = workflow.read_text().split(f"      - name: {name}\n", 1)[1]
    lines = []
    for line in step.split("        run: |\n", 1)[1].splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line)
    return textwrap.dedent("\n".join(lines))


class ExtractedFactsTest(unittest.TestCase):
    def test_collector_carries_only_regeneration_deltas_onto_behind_main_head(self):
        collect = ci_step_script("Commit native extracted facts as the update bot", "extracted-facts.yml")
        services = r'''set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
gh() { :; }
git() {
  case "$1" in
    commit|push) printf '%s\n' "$*" >> "$RUNNER_TEMP/commands" ;;
    fetch) ;;
    *) command git "$@" ;;
  esac
}
export -f gh git
'''
        for mode in ("changed", "conflict", "multiple-owners", "noop"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                repo, runner = root / "source", root / "runner"
                repo.mkdir()
                (runner / "facts").mkdir(parents=True)
                def git(*args):
                    return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args], cwd=repo, text=True, stderr=subprocess.DEVNULL).strip()
                git("init", "--quiet", "--initial-branch=main")
                git("config", "user.name", "Fixture")
                git("config", "user.email", "fixture@example.test")
                changed = repo / "packages/kimchi/extracted/extracted.json"
                unchanged = repo / "packages/kimchi/extracted/unrelated.json"
                second = repo / "packages/semble/extracted/extracted.json"
                for path in (changed, unchanged, second):
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('head\n')
                git("add", ".")
                git("commit", "--quiet", "-m", "fixture head")
                head = git("rev-parse", "HEAD")
                unchanged.write_text('main-only\n')
                if mode == "conflict":
                    changed.write_text('main-conflict\n')
                git("add", ".")
                git("commit", "--quiet", "-m", "fixture merge-ref changes")
                if mode != "noop":
                    changed.write_text('regenerated\n')
                git("add", str(changed.relative_to(repo)))
                (runner / "facts/kimchi.patch").write_text(git("diff", "--cached", "--binary", "--full-index") + ('\n' if mode != "noop" else ''))
                git("reset", "--hard", "HEAD")
                if mode == "multiple-owners":
                    second.write_text('second-regeneration\n')
                    git("add", str(second.relative_to(repo)))
                    (runner / "facts/semble.patch").write_text(git("diff", "--cached", "--binary", "--full-index") + '\n')
                    git("reset", "--hard", "HEAD")
                # No third owner's artifact: a failed leg must not block these.
                output = root / "output"
                env = dict(os.environ, GITHUB_OUTPUT=str(output), HEAD_REF="feature/facts", HEAD_SHA=head,
                           RUNNER_TEMP=str(runner), SYSTEM="x86_64-linux")
                result = subprocess.run(["bash", "-c", services + collect], cwd=repo, env=env, capture_output=True, text=True)
                commands = (runner / "commands").read_text().splitlines() if (runner / "commands").exists() else []
                self.assertEqual(git("rev-parse", "HEAD"), head)
                self.assertEqual(unchanged.read_text(), 'head\n')
                if mode == "conflict":
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("conflict", result.stderr.lower())
                    self.assertEqual(commands, [])
                    self.assertFalse(output.exists())
                    continue
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(changed.read_text(), 'head\n' if mode == "noop" else 'regenerated\n')
                expected = [] if mode == "noop" else [str(changed.relative_to(repo))]
                if mode == "multiple-owners":
                    expected.append(str(second.relative_to(repo)))
                self.assertEqual(git("diff", "--cached", "--name-only").splitlines(), expected)
                self.assertEqual(sum(command.startswith("commit ") for command in commands), int(mode != "noop"))
                self.assertEqual(commands.count("push origin HEAD:refs/heads/feature/facts"), int(mode != "noop"))
                if mode == "noop":
                    self.assertFalse(output.exists())
                else:
                    self.assertTrue(commands[0].startswith("commit -m chore(extracted): record x86_64-linux extracted facts -m Regenerated owners:"))
                    self.assertEqual(output.read_text(), 'published=true\n')

    def test_collector_runs_after_owner_failure_but_not_cancellation(self):
        workflow = (Path(__file__).parents[2] / ".github/workflows/extracted-facts.yml").read_text()
        job = workflow.split("\n  commit:\n", 1)[1]
        expression = " ".join(job.split("    if: >-\n", 1)[1].split("    runs-on:", 1)[0].split())
        for cancelled, repository, expected in ((False, "same", True), (True, "same", False), (False, "fork", False)):
            with self.subTest(cancelled=cancelled, repository=repository):
                # The status function prevents Actions from adding success(), so
                # this expression also runs after a failing producer matrix.
                condition = expression.replace("!cancelled()", str(not cancelled))
                condition = condition.replace("github.event.pull_request.head.repo.full_name", repr(repository)).replace("github.repository", repr("same"))
                self.assertEqual(eval(condition.replace("&&", " and "), {"__builtins__": {}}), expected)

    def test_fork_diagnostic_downloads_delta_to_scratch_then_applies_it(self):
        diagnostic = ci_step_script("Fail on stale native extracted facts", "extracted-facts.yml")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "checkout"
            source.mkdir()
            path = "packages/kimchi/extracted/extracted.json"
            artifact = root / "artifact/kimchi.patch"
            artifact.parent.mkdir(parents=True, exist_ok=True)
            artifact.write_text('fresh\n')
            old = source / path
            old.parent.mkdir(parents=True, exist_ok=True)
            old.write_text('stale\n')
            scratch = root / "scratch"
            scratch.mkdir()
            env = dict(os.environ, ARTIFACT=str(root / "artifact"), OWNER="kimchi", RUN_ID="123", SYSTEM="x86_64-linux", TMPDIR=str(scratch))
            result = subprocess.run(["bash", "-c", diagnostic], cwd=source, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            commands = "\n".join(line.strip() for line in result.stdout.splitlines() if line.startswith("  "))
            services = r'''set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
gh() {
  python3 - "$ARTIFACT" "$7" <<'EXCLUSIVE_DOWNLOAD'
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
assert destination.resolve() != Path.cwd()
for path in source.rglob('*'):
    if path.is_file():
        target = destination / path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as stream:
            stream.write(path.read_bytes())
EXCLUSIVE_DOWNLOAD
}
git() {
  [ "$1:$2:$3" = apply:--3way:--index ]
  cp "$4" packages/kimchi/extracted/extracted.json
}
export -f gh git
'''
            result = subprocess.run(["bash", "-c", services + commands], cwd=source, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(old.read_text(), 'fresh\n')

    def test_kimchi_producer_includes_report_in_regeneration_delta(self):
        produce = ci_step_script("Produce native extracted facts", "extracted-facts.yml")
        services = r'''set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
nix() { printf '%s\n' "$*" >> "$RUNNER_TEMP/commands"; }
git() {
  printf '%s\n' "$*" >> "$RUNNER_TEMP/commands"
  case "$1" in
    add) ;;
    diff) if [ "$DIRTY" = true ]; then printf 'egress report delta\n'; fi ;;
    *) return 1 ;;
  esac
}
export -f git nix
'''
        for dirty in ("false", "true"):
            with self.subTest(dirty=dirty), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"
                env = dict(os.environ, DIRTY=dirty, GITHUB_OUTPUT=str(output), OWNER="kimchi", RUNNER_TEMP=directory, SYSTEM="x86_64-linux")
                result = subprocess.run(["bash", "-c", services + produce], cwd=directory, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(output.read_text(), f"changed={dirty}\n")
                commands = (Path(directory) / "commands").read_text().splitlines()
                self.assertEqual(commands[0], "run .#.checks.x86_64-linux.kimchi-extracted.passthru.regenerate")
                self.assertIn("--command bash dev/skills/kimchi-egress-report/scripts/regenerate.sh", commands[1])
                self.assertEqual(commands[2], "add -- packages/kimchi/extracted packages/kimchi/egress-report.json")
                self.assertEqual(commands[3], "diff --cached --binary --full-index -- packages/kimchi/extracted packages/kimchi/egress-report.json")
                self.assertEqual((Path(directory) / "facts/kimchi.patch").read_text(), 'egress report delta\n' if dirty == "true" else '')

    def test_linux_planner_selects_darwin_only_change_in_handled_inputs(self):
        old = {"kiro-cli": {"drvPaths": {"aarch64-darwin": "old-darwin", "x86_64-linux": "same-linux"}}}
        head = {"kiro-cli": {"drvPaths": {"aarch64-darwin": "new-darwin", "x86_64-linux": "same-linux"}}}
        with mock.patch.object(extracted, "derivations", side_effect=[head, old]):
            with mock.patch.object(extracted.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
                self.assertEqual(extracted.plan(Path("/fixture"), "x86_64-linux", "pull_request", "base"), ["kiro-cli"])

    def test_planner_compares_changed_and_new_extraction_inputs(self):
        old = {"changed": {"drvPath": "old"}, "unchanged": {"drvPath": "same"}}
        head = {"changed": {"drvPath": "new"}, "new-owner": {"drvPath": "added"}, "unchanged": old["unchanged"]}
        for system in ("aarch64-darwin", "x86_64-linux"):
            for wrapper_changed, expected in ((0, ["changed", "new-owner"]), (1, list(head))):
                with self.subTest(system=system, wrapper_changed=wrapper_changed):
                    with mock.patch.object(extracted, "derivations", side_effect=[head, old]) as derivations:
                        with mock.patch.object(extracted.subprocess, "run", return_value=subprocess.CompletedProcess([], wrapper_changed)):
                            self.assertEqual(extracted.plan(Path("/fixture"), system, "pull_request", "base"), expected)
                    self.assertEqual(derivations.call_args_list, [mock.call(Path("/fixture"), system), mock.call(Path("/fixture"), system, base="base")])

    def test_planner_dispatch_and_missing_base_select_all(self):
        head = {"owner": {"drvPath": "fresh"}}
        for event, base in (("workflow_dispatch", "base"), ("push", ""), ("push", "0" * 40)):
            with self.subTest(event=event, base=base):
                with mock.patch.object(extracted, "derivations", return_value=head) as derivations:
                    self.assertEqual(extracted.plan(Path("/fixture"), "x86_64-linux", event, base), ["owner"])
                derivations.assert_called_once()

    def test_planner_failures_select_all_or_retry_names(self):
        head = {"owner": {"drvPath": "fresh"}}
        for results, expected_calls in (
            ([head, ValueError("base has old output shape")], [mock.call(Path("/fixture"), "x86_64-linux"), mock.call(Path("/fixture"), "x86_64-linux", base="base")]),
            ([ValueError("head drv unavailable"), ["owner"]], [mock.call(Path("/fixture"), "x86_64-linux"), mock.call(Path("/fixture"), "x86_64-linux", names_only=True)]),
        ):
            with self.subTest(results=results):
                with mock.patch.object(extracted, "derivations", side_effect=results) as derivations:
                    with mock.patch.object(extracted, "report_failure") as report:
                        self.assertEqual(extracted.plan(Path("/fixture"), "x86_64-linux", "pull_request", "base"), ["owner"])
                self.assertEqual(derivations.call_args_list, expected_calls)
                report.assert_called_once()

    def test_planner_uses_system_at_both_revisions_and_names_fallback(self):
        root = Path("/fixture")
        for system in ("aarch64-darwin", "x86_64-linux"):
            for base, names_only in ((None, False), ("base", False), (None, True)):
                with self.subTest(system=system, base=base, names_only=names_only):
                    with mock.patch.object(extracted.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, '{}')) as run:
                        self.assertEqual(extracted.derivations(root, system, base=base, names_only=names_only), {})
                    command = run.call_args.args[0]
                    if names_only and system == "x86_64-linux":
                        self.assertEqual(command[-4:], ["--file", "checks/extracted/owners.nix", "--apply", "builtins.attrNames"])
                        self.assertFalse(any("#ciExtractedFacts" in argument for argument in command))
                    else:
                        flake = "git+file:///fixture?rev=base" if base else "."
                        self.assertEqual(command[-1], f"{flake}#ciExtractedFacts.{system}")
                    self.assertEqual("builtins.attrNames" in command, names_only)

    def test_producer_orders_linux_before_darwin_without_package_success_gate(self):
        workflow = (Path(__file__).parents[2] / ".github/workflows/ci.yml").read_text()
        for system in ("linux", "darwin"):
            job = workflow.split(f"\n  extracted-facts-{system}:\n", 1)[1].split("\n  # Preserve" if system == "darwin" else "\n  extracted-facts-darwin:", 1)[0]
            dependencies = job.split("    if:", 1)[0]
            if system == "darwin":
                self.assertIn("extracted-facts-linux", dependencies)
                self.assertNotIn("build-packages", dependencies)
            else:
                self.assertIn("build-packages", dependencies)
            expression = " ".join(job.split("    if: >-\n", 1)[1].split("    uses:", 1)[0].split())
            for cancelled, plan_result, owners, linux_result, published, expected in (
                (False, "success", '["owner"]', "success", "", True),
                (False, "success", '["owner"]', "skipped", "", True),
                (False, "success", '["owner"]', "failure", "", system == "linux"),
                (False, "success", '["owner"]', "cancelled", "", system == "linux"),
                (False, "success", '["owner"]', "success", "true", system == "linux"),
                (True, "success", '["owner"]', "success", "", False),
                (False, "failure", '["owner"]', "success", "", False),
                (False, "success", "[]", "success", "", False),
            ):
                with self.subTest(system=system, cancelled=cancelled, plan_result=plan_result, owners=owners, linux_result=linux_result, published=published):
                    condition = expression.replace("!cancelled()", str(not cancelled))
                    for key, value in (
                        ("needs.extracted-facts-linux.outputs.published", published),
                        ("needs.extracted-facts-linux.result", linux_result),
                        ("needs.plan-extracted-facts.result", plan_result),
                        (f"needs.plan-extracted-facts.outputs.{system}-matrix", owners),
                    ):
                        condition = condition.replace(key, repr(value))
                    condition = condition.replace("&&", " and ").replace("||", " or ")
                    self.assertEqual(eval(condition, {"__builtins__": {}}), expected)

    def test_required_build_context_accounts_for_both_producers(self):
        script = ci_step_script("Require successful package workers")
        defaults = dict(os.environ, EXTRACTED_DARWIN_MATRIX='["owner"]', EXTRACTED_DARWIN_RESULT="success",
                        EXTRACTED_LINUX_MATRIX='["owner"]', EXTRACTED_LINUX_RESULT="success",
                        PLAN_RESULT="success", RESULT="success")
        cases = [({}, True), ({"RESULT": "failure"}, False), ({"PLAN_RESULT": "failure"}, False)]
        for system in ("DARWIN", "LINUX"):
            for result in ("cancelled", "failure", "skipped", ""):
                cases.append(({f"EXTRACTED_{system}_RESULT": result}, False))
            cases.append(({f"EXTRACTED_{system}_RESULT": "skipped", f"EXTRACTED_{system}_MATRIX": "[]"}, True))
        for changes, success in cases:
            with self.subTest(changes=changes):
                result = subprocess.run(["bash", "-c", script], env=dict(defaults, **changes), capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)


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

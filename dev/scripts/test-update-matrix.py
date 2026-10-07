#!/usr/bin/env python3
"""Check update isolation and PR preservation with local Git fixtures only."""

# cspell:ignore execv

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
WORKFLOW = SCRIPTS.parents[1] / ".github" / "workflows" / "update.yml"
SPEC = importlib.util.spec_from_file_location("update_matrix", SCRIPTS / "update-matrix.py")
matrix = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(matrix)
GITHUB_SPEC = importlib.util.spec_from_file_location("update_github", SCRIPTS / "update-github.py")
github = importlib.util.module_from_spec(GITHUB_SPEC)
GITHUB_SPEC.loader.exec_module(github)


class MatrixTest(unittest.TestCase):
    def test_update_preparation_inherits_only_read_repository_permissions(self):
        workflow = WORKFLOW.read_text()
        permissions = workflow.split("\npermissions:\n", 1)[1].split("\nenv:\n", 1)[0]
        self.assertEqual(permissions.strip(), "contents: read")
        update_job = workflow.split("\n  update:\n", 1)[1].split("\n  cleanup:\n", 1)[0]
        self.assertNotIn("\n    permissions:", update_job)

    def test_discovery_and_subset(self):
        lock = {"root": "root", "nodes": {"root": {"inputs": {"nixpkgs": "nixpkgs"}}}}
        targets = {"demo": {"flags": ["--use-update-script"], "git": None}}
        plan = matrix.discover(lock, targets)
        self.assertEqual([r["name"] for r in plan["include"]], ["nixpkgs", "demo"])
        self.assertEqual(matrix.discover(lock, targets, "demo")["include"], [plan["include"][1]])
        for requested in ("missing", "demo,demo"):
            with self.assertRaises(ValueError):
                matrix.discover(lock, targets, requested)
        with self.assertRaises(ValueError):
            matrix.discover(lock, {"nixpkgs": {}})

    def test_reports_require_normal_target_completion(self):
        for report, status in (
            ("UPDATED: demo | 1 -> 2", "UPDATED"),
            ("NO UPDATES: demo", "NO UPDATES"),
            ("HELD BACK: demo (hash failed)", "HELD BACK"),
            ("HELD BACK: demo | 1 -> 2 (hash failed)", "HELD BACK"),
        ):
            self.assertEqual(matrix.report_status(report + "\n", "demo"), status)
        for report in ("", "UPDATED: another", "UPDATED: demo\nNO UPDATES: demo"):
            with self.assertRaises(ValueError):
                matrix.report_status(report, "demo")

    def test_cleanup_requires_every_receipt_on_the_same_base(self):
        plan = {"include": [{"name": "demo"}, {"name": "nixpkgs"}]}
        receipts = [
            {"base": "base", "name": "demo", "status": "HELD BACK", "touched": ["update/demo"]},
            {"base": "base", "name": "nixpkgs", "status": "NO UPDATES", "touched": []},
        ]
        self.assertEqual(matrix.collect(plan, receipts, "base"), ["update/demo"])
        for broken in ([], receipts[:1], receipts + receipts, [dict(receipts[0], touched=[]), receipts[1]]):
            with self.assertRaises(ValueError):
                matrix.collect(plan, broken, "base")
        with self.assertRaises(ValueError):
            matrix.collect(plan, receipts, "different-base")

    def test_post_receipt_diagnostic_failure_still_reaches_fail_closed_cleanup(self):
        workflow = WORKFLOW.read_text()
        cleanup = workflow.split("\n  cleanup:\n", 1)[1].split("\n  annotations:\n", 1)[0]
        self.assertIn("if: ${{ !cancelled() && needs.discover.result == 'success' && !inputs.targets }}", " ".join(cleanup.split()))
        self.assertIn("update-matrix.py\" collect", cleanup)

        plan = {"include": [{"name": "demo"}, {"name": "nixpkgs"}]}
        receipts = [
            {"base": "base", "name": "demo", "status": "UPDATED", "touched": ["update/demo"]},
            {"base": "base", "name": "nixpkgs", "status": "NO UPDATES", "touched": []},
        ]
        self.assertEqual(matrix.collect(plan, receipts, "base"), ["update/demo"])
        with self.assertRaises(ValueError):
            matrix.collect(plan, receipts[:1], "base")

    def test_failed_verification_rides_only_an_updated_receipt(self):
        with tempfile.TemporaryDirectory() as logs:
            self.assertIsNone(matrix.verify_failures(logs, "nixpkgs", "UPDATED"))
            record = Path(logs) / "verify-failed-nixpkgs.txt"
            record.write_text("ciPackages.x86_64-linux.pnpm_12\nciPackages.x86_64-linux.oxlint\n")
            self.assertEqual(matrix.verify_failures(logs, "nixpkgs", "UPDATED"), ["ciPackages.x86_64-linux.pnpm_12", "ciPackages.x86_64-linux.oxlint"])
            self.assertIsNone(matrix.verify_failures(logs, "nixpkgs", "HELD BACK"))
            self.assertIsNone(matrix.verify_failures(logs, "other", "UPDATED"))
            record.write_text("\n")
            self.assertEqual(matrix.verify_failures(logs, "nixpkgs", "UPDATED"), ["<failed attributes not reported>"])

    def test_verdict_names_target_attributes_and_pr_only_on_failure(self):
        self.assertIsNone(matrix.verification_verdict({"name": "nixpkgs", "status": "UPDATED"}, "https://example.test/pull/7", ""))
        level, lines = matrix.verification_verdict({"name": "nixpkgs", "status": "UPDATED", "verifyFailed": ["a", "b"]}, "https://example.test/pull/7", "")
        self.assertEqual(level, "error")
        self.assertIn("nixpkgs", lines[0])
        self.assertIn("a, b", lines[1])
        self.assertIn("https://example.test/pull/7", lines[2])
        self.assertIn("none", matrix.verification_verdict({"name": "nixpkgs", "verifyFailed": ["a"]}, "", "")[1][2])

    def test_verdict_skips_a_preserved_lane_even_after_publication(self):
        # A human took the branch over, possibly after this run published it.
        # Preservation wins: the lane is skipped with a notice, never red.
        prepared = {"name": "nixpkgs", "status": "UPDATED", "verifyFailed": ["a"]}
        for published in ("", "https://example.test/pull/7"):
            level, lines = matrix.verification_verdict(prepared, published, "2 non-bot commit(s) are on the remote branch (PR #7).")
            self.assertEqual(level, "notice")
            self.assertIn("update/nixpkgs", lines[0])
            self.assertIn("non-bot commit(s)", lines[1])
            self.assertIn("a", lines[2])
        self.assertIsNone(matrix.verification_verdict({"name": "nixpkgs", "status": "UPDATED"}, "", "reason"))

    def test_verdict_runs_after_publication_and_receipt_without_cancelling_siblings(self):
        workflow = WORKFLOW.read_text()
        update = workflow.split("\n  update:\n", 1)[1].split("\n  cleanup:\n", 1)[0]
        self.assertIn("fail-fast: false", update)
        verdict = update.index('update-matrix.py" verdict')
        self.assertLess(update.index("update-publish.sh"), verdict)
        self.assertLess(update.index("name: update-receipt-"), verdict)
        step = update[update.rindex("- name:", 0, verdict):verdict]
        self.assertIn("if: ${{ !cancelled() }}", step)


class GitHubTest(unittest.TestCase):
    def test_push_requires_authenticated_actor_exact_ref_and_head(self):
        activity = {"activity_type": "force_push", "actor": {"login": "nix-agentic-tools-bot[bot]"}, "after": "head", "ref": "refs/heads/update/demo"}
        self.assertTrue(github.bot_push([activity], "update/demo", "head"))
        for change in ({"actor": {"login": "human"}}, {"after": "other"}, {"ref": "refs/heads/other"}, {"actor": None}):
            self.assertFalse(github.bot_push([dict(activity, **change)], "update/demo", "head"))
        self.assertFalse(github.bot_push([], "update/demo", "head"))

    def test_inline_review_scan_paginates_and_preserves_incomplete_threads(self):
        def page(nodes, more=False):
            return {"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": nodes, "pageInfo": {"hasNextPage": more, "endCursor": "next"}}}}}}
        bot = {"comments": {"nodes": [{"author": {"login": "copilot-pull-request-reviewer"}}], "pageInfo": {"hasNextPage": False}}}
        human = {"comments": {"nodes": [{"author": {"login": "human"}}], "pageInfo": {"hasNextPage": False}}}
        allowed = {"copilot-pull-request-reviewer"}
        with mock.patch.object(github, "github", side_effect=[page([bot], True), page([bot])]) as api:
            self.assertTrue(github.bot_review_threads("example/repo", 1, allowed))
            self.assertIn("cursor=next", api.call_args.args)
        with mock.patch.object(github, "github", side_effect=[page([bot], True), page([human])]):
            self.assertFalse(github.bot_review_threads("example/repo", 1, allowed))
        bot["comments"]["pageInfo"]["hasNextPage"] = True
        self.assertFalse(github.bot_thread(bot, allowed))

    def test_auto_merge_retry_distinguishes_human_and_automatic_disables(self):
        allowed = {"nix-agentic-tools-bot[bot]"}
        human = {"__typename": "AutoMergeDisabledEvent", "actor": {"login": "human"}, "disabler": {"login": "human"}, "reason": None, "reasonCode": None}
        automatic = {"__typename": "AutoMergeDisabledEvent", "actor": None, "disabler": None, "reason": "The pull request has a merge conflict", "reasonCode": "MERGE_CONFLICT"}
        bot = {"__typename": "AutoMergeDisabledEvent", "actor": {"login": "nix-agentic-tools-bot[bot]"}, "disabler": None, "reason": None, "reasonCode": None}
        enabled = {"__typename": "AutoMergeEnabledEvent", "actor": {"login": "human"}, "enabler": {"login": "human"}}
        self.assertEqual(github.auto_merge_retry([human], allowed), "human-disabled")
        for events in ([], [automatic], [bot], [enabled]):
            self.assertEqual(github.auto_merge_retry(events, allowed), "allowed")
        with self.assertRaises(ValueError):
            github.auto_merge_retry([dict(automatic, reason=None, reasonCode=None)], allowed)

    def test_close_retry_distinguishes_human_and_bot_cleanup(self):
        bot = {"__typename": "ClosedEvent", "actor": {"login": "nix-agentic-tools-bot[bot]"}}
        human = {"__typename": "ClosedEvent", "actor": {"login": "human"}}
        allowed = {"nix-agentic-tools-bot[bot]"}
        self.assertEqual(github.close_retry([bot], allowed), "automatic")
        self.assertEqual(github.close_retry([human], allowed), "human")
        for malformed in ([], [bot, human], [{"__typename": "ClosedEvent", "actor": None}]):
            with self.subTest(events=malformed), self.assertRaises(ValueError):
                github.close_retry(malformed, allowed)


class PublishTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "source"
        self.remote = self.root / "remote.git"
        self.repo.mkdir()
        self.git("init", "--bare", str(self.remote))
        self.git("init", "-b", "main")
        self.git("config", "core.hooksPath", "/dev/null")
        self.git("config", "user.name", "Bot")
        self.git("config", "user.email", "bot@example.test")
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "origin", "main")
        self.git("checkout", "-b", "update/demo")
        self.commit("new")
        self.git("checkout", "main")
        stub = self.root / "gh"
        stub.write_text("""#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
with open(os.environ['GH_CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')
def closed_path(number):
    return Path(os.environ['RUNNER_TEMP']) / ('closed' if number == '1' else f'closed-{number}')
if sys.argv[1:3] == ['pr', 'list']:
    limit = int(sys.argv[sys.argv.index('--limit') + 1]) if '--limit' in sys.argv else 30
    key = 'CLOSED_PR_LIST' if '--state' in sys.argv and sys.argv[sys.argv.index('--state') + 1] == 'closed' else 'PR_LIST'
    print(json.dumps(json.loads(os.environ.get(key, '[]'))[:limit]))
if sys.argv[1:3] == ['pr', 'view']:
    number = sys.argv[3]
    closed = closed_path(number)
    if os.environ.get('PR_VIEW_FAIL'): sys.exit(1)
    views_key = 'POST_CLOSE_VIEWS' if closed.exists() and 'POST_CLOSE_VIEWS' in os.environ else 'PR_VIEWS'
    if views_key in os.environ:
        view = json.loads(os.environ[views_key])[number]
    else:
        view = json.loads(os.environ.get('POST_CLOSE_VIEW', os.environ['PR_VIEW']) if closed.exists() else os.environ['PR_VIEW'])
    view.setdefault('state', 'CLOSED' if closed.exists() else 'OPEN')
    if os.environ.get('ARM_RACE_TIP'):
        view['headRefOid'] = os.environ['ARM_RACE_TIP']
        subprocess.check_call(['git', '--git-dir', os.environ['REMOTE'], 'update-ref', 'refs/heads/update/demo', view['headRefOid']])
    if os.environ.get('PR_VIEW_REMOTE_HEAD'):
        view['headRefOid'] = subprocess.check_output(['git', '--git-dir', os.environ['REMOTE'], 'rev-parse', 'refs/heads/update/demo'], text=True).strip()
    disabled = Path(os.environ['RUNNER_TEMP'], 'auto-merge-disabled').exists()
    enabled = os.environ.get('AUTO_MERGE_ENABLED') or (os.environ.get('AUTO_MERGE_ENABLED_AFTER_ARM') and Path(os.environ['RUNNER_TEMP'], 'arm-attempted').exists())
    enabled_by = os.environ.get('AUTO_MERGE_ENABLED_BY', 'app/nix-agentic-tools-bot')
    if os.environ.get('PR_AUTO_MERGE_RAW'):
        view['autoMergeRequest'] = json.loads(os.environ['PR_AUTO_MERGE_RAW'])
    else:
        view['autoMergeRequest'] = {'enabledAt': 'fixture', 'enabledBy': {'login': enabled_by}} if enabled and not disabled else None
    print(json.dumps(view))
if sys.argv[1:3] == ['pr', 'close']: closed_path(sys.argv[3]).touch()
if sys.argv[1] == 'api':
    if any(arg.endswith('/activity') for arg in sys.argv):
        ref = next(arg.removeprefix('ref=') for arg in sys.argv if arg.startswith('ref='))
        if os.environ.get('ACTIVITY_ERROR'): sys.exit(1)
        if os.environ.get('ACTIVITY_EMPTY'):
            print('[]')
            sys.exit(0)
        head = subprocess.check_output(['git', 'rev-parse', 'refs/remotes/origin/' + ref.removeprefix('refs/heads/')], text=True).strip()
        actor = os.environ.get('PUSH_ACTOR', 'nix-agentic-tools-bot[bot]')
        print(json.dumps([{'activity_type': 'push', 'actor': {'login': actor}, 'ref': ref, 'after': head}]))
    elif 'graphql' in sys.argv:
        number = next(arg.removeprefix('number=') for arg in sys.argv if arg.startswith('number='))
        closed = closed_path(number)
        query = next((arg for arg in sys.argv if arg.startswith('query=')), '')
        if 'timelineItems' in query:
            key = 'CLOSE_EVENTS' if 'CLOSED_EVENT' in query else 'AUTO_MERGE_EVENTS'
            events = json.loads(os.environ.get(key, '[]'))
            print(json.dumps({'data': {'repository': {'pullRequest': {'timelineItems': {'nodes': events}}}}}))
        else:
            threads = json.loads(os.environ.get('REVIEW_THREADS', '{"nodes": [], "pageInfo": {"hasNextPage": false}}'))
            if closed.exists() and 'POST_CLOSE_THREADS' in os.environ:
                threads = json.loads(os.environ['POST_CLOSE_THREADS'])
            print(json.dumps({'data': {'repository': {'pullRequest': {'reviewThreads': threads}}}}))
    elif any(arg.endswith('/comments') and '/issues/' in arg for arg in sys.argv): print(os.environ.get('PR_COMMENTS', '[]'))
    else: print(os.environ['COMMIT_PAGES'])
if sys.argv[1:3] == ['pr', 'merge']:
    if '--disable-auto' in sys.argv:
        if os.environ.get('FAIL_DISABLE'): sys.exit(1)
        Path(os.environ['RUNNER_TEMP'], 'auto-merge-disabled').touch()
    else:
        Path(os.environ['RUNNER_TEMP'], 'arm-attempted').touch()
        if os.environ.get('FAIL_ARM'): sys.exit(1)
if sys.argv[1:3] == ['pr', 'close'] and os.environ.get('RACE_TIP'):
    subprocess.check_call(['git', '--git-dir', os.environ['REMOTE'], 'update-ref', 'refs/heads/update/demo', os.environ['RACE_TIP']])
if sys.argv[1:3] == ['pr', 'create']:
    if os.environ.get('FAIL_CREATE'): sys.exit(1)
    print('https://github.com/example/example/pull/1')
if sys.argv[1:3] == ['pr', 'reopen']:
    closed = closed_path(sys.argv[3])
    attempts = Path(os.environ['RUNNER_TEMP'], 'reopen-attempts')
    count = int(attempts.read_text()) + 1 if attempts.exists() else 1
    attempts.write_text(str(count))
    if count <= int(os.environ.get('REOPEN_FAILURES', '0')): sys.exit(17)
    closed.unlink(missing_ok=True)
""")
        stub.chmod(0o755)
        sleep_stub = self.root / "sleep"
        sleep_stub.write_text("#!/usr/bin/env bash\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\nexit 0\n")
        sleep_stub.chmod(0o755)
        self.env = dict(os.environ, BRANCH_NAME="main", GITHUB_REPOSITORY="example/example", GH_CALLS=str(self.root / "calls"), PATH=str(self.root) + os.pathsep + os.environ["PATH"], RUNNER_TEMP=str(self.root), UPDATE_BASE_SHA=self.base, UPDATE_TARGET="demo")
        self.env.update(PR_VIEW=json.dumps(dict(self.own_pr(), headRefOid=self.git("rev-parse", "update/demo"))), REMOTE=str(self.remote))
        (self.root / "prepared.json").write_text(json.dumps({"status": "UPDATED"}))

    def git(self, *args):
        return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", *args], cwd=self.repo, text=True, stderr=subprocess.DEVNULL).strip()

    def commit(self, text):
        (self.repo / "data").write_text(text)
        self.git("add", "data")
        self.git("commit", "-m", "chore(packages): update demo")

    def publish(self, **env):
        (self.root / "auto-merge-disabled").unlink(missing_ok=True)
        (self.root / "arm-attempted").unlink(missing_ok=True)
        return subprocess.run(["bash", str(SCRIPTS / "update-publish.sh")], cwd=self.repo, env=dict(self.env, **env), text=True, capture_output=True)

    def assert_skipped(self, result, reason):
        """The lane is a Renovate-style skip: green, a notice, touched once, reason recorded."""
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("::notice title=Update lane skipped::Leaving update/demo untouched:", result.stdout)
        self.assertNotIn("::error", result.stdout)
        self.assertIn(reason, (self.root / "skip").read_text())
        self.assertEqual((self.root / "touched-branches").read_text(), "update/demo\n")

    def comments(self):
        """Bodies of every comment this publish posted."""
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        return [call[call.index("--body") + 1] for call in calls if call[:2] == ["pr", "comment"]]

    def assert_left(self, result, reason, comment=True):
        """Not the bot's own last push: skipped, nothing mutated, and one marked
        comment only for a human edit (<comment>)."""
        self.assert_skipped(result, reason)
        calls = (self.root / "calls").read_text()
        for mutation in ('["pr", "edit"', '["pr", "merge"', '["pr", "create"'):
            self.assertNotIn(mutation, calls)
        self.assertNotIn("Pushing update/demo", result.stdout)
        bodies = self.comments()
        self.assertEqual(len(bodies), 1 if comment else 0, bodies)
        if comment:
            self.assertIn("<!-- update-bot-left: update/demo ", bodies[0])
            self.assertIn("changed since this bot last updated it", bodies[0])
            self.assertIn("until the branch is deleted", bodies[0])

    def matrix_command(self, command):
        return subprocess.run(["python3", str(SCRIPTS / "update-matrix.py"), command], cwd=self.repo, env=self.env, text=True, capture_output=True)

    def push_human_commit(self):
        """Put a human fix on the remote branch on top of the bot's commit."""
        self.git("checkout", "update/demo")
        bot_tip = self.git("rev-parse", "HEAD")
        self.git("config", "user.email", "human@example.test")
        self.commit("human fix")
        human_tip = self.git("rev-parse", "HEAD")
        self.git("push", "origin", "update/demo")
        self.git("reset", "--hard", bot_tip)
        self.git("checkout", "main")
        self.git("config", "user.email", "bot@example.test")
        return human_tip

    def test_completed_branch_is_published_and_pr_created(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), self.git("rev-parse", "update/demo"))
        self.assertIn('["pr", "create"', (self.root / "calls").read_text())
        self.assertEqual((self.root / "touched-branches").read_text(), "update/demo\n")
        self.assertEqual((self.root / "published-pr").read_text(), "https://github.com/example/example/pull/1\n")

    def test_recorded_verification_failure_reaches_the_verdict_after_publication(self):
        logs = self.repo / ".update-logs"
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; record_verify_failure demo "$2"', "_", str(SCRIPTS / "update-common.sh"), "attr.one\nattr.two"],
            cwd=self.repo, env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(matrix.verify_failures(logs, "demo", "UPDATED"), ["attr.one", "attr.two"])
        (self.root / "prepared.json").write_text(json.dumps({"name": "demo", "status": "UPDATED", "verifyFailed": ["attr.one", "attr.two"]}))
        published = self.publish()
        self.assertEqual(published.returncode, 0, published.stderr)
        verdict = subprocess.run(["python3", str(SCRIPTS / "update-matrix.py"), "verdict"], cwd=self.repo, env=self.env, text=True, capture_output=True)
        self.assertNotEqual(verdict.returncode, 0)
        self.assertIn("::error title=Update build verification failed::demo", verdict.stdout)
        self.assertIn("attr.one, attr.two", verdict.stdout)
        self.assertIn("https://github.com/example/example/pull/1", verdict.stdout)

    def test_new_pr_arms_on_its_own_push_without_reading_push_activity(self):
        # The bot's own push this run is its last push: origin at that SHA is
        # enough, so there is no activity read and no re-read loop.
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertNotIn("/activity", calls)
        self.assertEqual(calls.count('["pr", "view"'), 1)
        self.assertIn('"--auto"', calls)

    def test_pr_view_lag_is_skipped_and_failure_is_red_without_retry(self):
        # GitHub's PR view disagreeing with origin is lag the next sweep
        # self-heals: a quiet skip, no comment. A failed PR view is an API
        # error: red. Neither is retried.
        (self.root / "prepared.json").write_text(json.dumps({"name": "demo", "status": "UPDATED", "verifyFailed": ["attr.one"]}))
        for env, lag in (({"PR_VIEW": json.dumps(dict(self.own_pr(), headRefOid=self.base))}, True), ({"PR_VIEW_FAIL": "1"}, False)):
            with self.subTest(lag=lag):
                (self.root / "calls").unlink(missing_ok=True)
                self.git("--git-dir", str(self.remote), "update-ref", "-d", "refs/heads/update/demo")
                self.git("update-ref", "-d", "refs/remotes/origin/update/demo")
                result = self.publish(**env)
                calls = (self.root / "calls").read_text()
                self.assertEqual(calls.count('["pr", "view"'), 1)
                self.assertNotIn('["pr", "merge"', calls)
                self.assertEqual(len(self.comments()), 0)
                if lag:
                    self.assert_skipped(result, "another repository, base, head branch, author or head")
                    verdict = self.matrix_command("verdict")
                    self.assertEqual(verdict.returncode, 0, verdict.stdout + verdict.stderr)
                    self.assertIn("::notice title=Update lane skipped::", verdict.stdout)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("::error::Could not read GitHub's view of", result.stdout)
                    self.assertEqual((self.root / "skip").read_text(), "")

    def test_human_auto_merge_disable_before_arming_is_retained(self):
        disabled = [{"__typename": "AutoMergeDisabledEvent", "actor": {"login": "human"}, "disabler": {"login": "human"}, "reason": None, "reasonCode": None}]
        result = self.publish(AUTO_MERGE_EVENTS=json.dumps(disabled))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Retaining explicit human auto-merge disable", result.stdout)
        self.assertNotIn('["pr", "merge"', (self.root / "calls").read_text())

    def test_inherited_app_auto_merge_survives_human_push(self):
        self.git("checkout", "update/demo")
        bot_tip = self.git("rev-parse", "HEAD")
        self.git("config", "user.email", "human@example.test")
        self.commit("human fix")
        human_tip = self.git("rev-parse", "HEAD")
        self.git("push", "origin", "update/demo")
        self.git("reset", "--hard", bot_tip)
        self.git("checkout", "main")
        self.git("config", "user.email", "bot@example.test")
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), PUSH_ACTOR="human", AUTO_MERGE_ENABLED="1")
        self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), human_tip)
        self.assert_left(result, f"non-bot commits are on {human_tip}")
        self.assertFalse((self.root / "auto-merge-disabled").exists())

    def test_pr_creation_failure_is_not_a_successful_publication(self):
        self.assertNotEqual(self.publish(FAIL_CREATE="1").returncode, 0)

    def test_no_updates_never_enters_pr_publication(self):
        self.git("branch", "-f", "update/demo", self.base)
        (self.root / "prepared.json").write_text(json.dumps({"status": "NO UPDATES"}))
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "touched-branches").read_text(), "")
        self.assertNotIn('["pr",', (self.root / "calls").read_text())
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/update/demo"), "")

    def land_push_after_checkout(self, parent, email="human@example.test"):
        """Move origin's update/demo onto a commit by <email> the checkout never fetched."""
        self.git("checkout", "-b", "other", parent)
        self.git("config", "user.email", email)
        self.commit("concurrent work")
        tip = self.git("rev-parse", "HEAD")
        self.git("checkout", "main")
        self.git("config", "user.email", "bot@example.test")
        self.git("push", "origin", f"{tip}:refs/heads/update/demo")
        self.git("branch", "-D", "other")
        return tip

    def test_origin_moved_after_checkout_is_left_whoever_moved_it(self):
        # Origin's live head is read with git before anything is touched. It
        # moved off the checkout's head -- created where none was, or advanced
        # by a human or by other bot commits -- so the bot leaves it. Only a
        # human's commits on an open PR earn a comment.
        for existing, email in ((False, "human@example.test"), (True, "human@example.test"), (True, "bot@example.test")):
            with self.subTest(existing=existing, email=email):
                for ref in ("refs/heads/update/demo", "refs/pull/1/head"):
                    subprocess.run(["git", "--git-dir", str(self.remote), "update-ref", "-d", ref], capture_output=True)
                (self.root / "calls").unlink(missing_ok=True)
                bot_tip = self.git("rev-parse", "update/demo")
                if existing:
                    self.git("push", "origin", "update/demo")
                tip = self.land_push_after_checkout(bot_tip, email)
                self.git("update-ref", *(["refs/remotes/origin/update/demo", bot_tip] if existing else ["-d", "refs/remotes/origin/update/demo"]))
                result = self.publish(PR_LIST=json.dumps([self.own_pr()] if existing else []))
                expected = bot_tip if existing else "(none)"
                self.assert_left(result, f"origin's head is {tip}, not the bot's last push {expected}.", comment=existing and email.startswith("human"))
                self.assertTrue(self.git("ls-remote", "origin", "refs/heads/update/demo").startswith(tip))

    def test_rejected_push_after_origin_moved_is_left(self):
        # The lease is the head the gate accepted. A push landing between the
        # gate and the bot's push rejects it, and origin having moved decides.
        self.git("push", "origin", "update/demo")
        bot_tip = self.git("rev-parse", "update/demo")
        new_base, _ = self.prepare_behind_base_refresh()
        tip = self.land_push_after_checkout(bot_tip)
        self.git("--git-dir", str(self.remote), "update-ref", "refs/heads/update/demo", bot_tip)
        self.git("update-ref", "refs/remotes/origin/update/demo", bot_tip)
        hook = self.remote / "hooks" / "pre-receive"
        hook.write_text(f"#!/usr/bin/env bash\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\nenv -u GIT_QUARANTINE_PATH git update-ref refs/heads/update/demo {tip}\nexit 1\n")
        hook.chmod(0o755)
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), UPDATE_BASE_SHA=new_base)
        self.assertIn("Pushing update/demo", result.stdout)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"origin's head is {tip}", (self.root / "skip").read_text())
        calls = (self.root / "calls").read_text()
        self.assertNotIn('["pr", "edit"', calls)
        self.assertNotIn('["pr", "merge"', calls)
        self.assertEqual(len(self.comments()), 1)
        self.assertTrue(self.git("ls-remote", "origin", "refs/heads/update/demo").startswith(tip))

    def test_unreadable_origin_is_red_and_never_left(self):
        self.git("remote", "set-url", "origin", str(self.root / "missing.git"))
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("::error::Could not read origin's update/demo.", result.stdout)
        self.assertEqual((self.root / "skip").read_text(), "")
        self.assertNotIn('["pr", "comment"', (self.root / "calls").read_text())

    def test_rejected_push_with_unmoved_origin_is_red(self):
        hook = self.remote / "hooks" / "pre-receive"
        hook.write_text("#!/usr/bin/env bash\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\nexit 1\n")
        hook.chmod(0o755)
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("::error::Could not push update/demo.", result.stdout)
        self.assertEqual((self.root / "skip").read_text(), "")
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/update/demo"), "")
        self.assertNotIn('["pr", "create"', (self.root / "calls").read_text())

    def test_held_back_target_preserves_pr_without_pushing(self):
        (self.root / "prepared.json").write_text(json.dumps({"status": "HELD BACK"}))
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "touched-branches").read_text(), "update/demo\n")
        self.assertNotIn('["pr",', (self.root / "calls").read_text())
        self.assertEqual((self.root / "published-pr").read_text(), "")
        # A hold-back on a bot-only branch still counts toward escalation.
        self.assertEqual((self.root / "skip").read_text(), "")
        self.assertNotIn("Preserving", result.stdout)

    def test_held_back_target_on_a_human_branch_is_left(self):
        human_tip = self.push_human_commit()
        (self.root / "prepared.json").write_text(json.dumps({"base": self.base, "name": "demo", "status": "HELD BACK"}))
        result = self.publish()
        self.assert_skipped(result, f"non-bot commits are on {human_tip}")
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/update/demo").split()[0], human_tip)
        self.assertEqual(self.matrix_command("receipt").returncode, 0)
        receipt = json.loads((self.root / "update-receipt.json").read_text())
        self.assertIn("non-bot commits", receipt["skip"])
        self.assertEqual(matrix.collect({"include": [{"name": "demo"}]}, [receipt], self.base), ["update/demo"])

    def test_held_back_target_reads_origins_live_head(self):
        # The job-start ref still shows the bot's push, but origin moved since:
        # the hold-back is a skip, never counted toward escalation.
        self.git("push", "origin", "update/demo")
        tip = self.land_push_after_checkout(self.git("rev-parse", "update/demo"))
        self.git("update-ref", "refs/remotes/origin/update/demo", self.git("rev-parse", "update/demo"))
        (self.root / "prepared.json").write_text(json.dumps({"status": "HELD BACK"}))
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]))
        self.assert_left(result, f"origin's head is {tip}")
        self.assertNotIn("preparation held back", result.stdout)

    def test_preserved_branch_with_failed_verification_skips_the_lane(self):
        # The operator's case: the branch failed, a human is pushing an outside
        # fix that takes more than a day. Every sweep must leave it alone and
        # stay green.
        human_tip = self.push_human_commit()
        (self.root / "prepared.json").write_text(json.dumps({"name": "demo", "status": "UPDATED", "verifyFailed": ["attr.one"]}))
        posted = []
        for sweep in range(2):
            with self.subTest(sweep=sweep):
                # One comment per head: the second sweep finds the first's marker.
                (self.root / "calls").unlink(missing_ok=True)
                result = self.publish(PR_LIST=json.dumps([self.own_pr()]), PR_COMMENTS=json.dumps(posted))
                self.assert_left(result, f"non-bot commits are on {human_tip}", comment=sweep == 0)
                posted += [{"user": {"login": "nix-agentic-tools-bot[bot]"}, "body": body} for body in self.comments()]
                self.assertEqual(self.git("ls-remote", "origin", "refs/heads/update/demo").split()[0], human_tip)
                verdict = self.matrix_command("verdict")
                self.assertEqual(verdict.returncode, 0, verdict.stdout + verdict.stderr)
                self.assertIn("::notice title=Update lane skipped::demo", verdict.stdout)
                self.assertIn("update/demo", verdict.stdout)
                self.assertIn("non-bot commits", verdict.stdout)
                self.assertNotIn("::error", verdict.stdout)

    def test_rebase_only_refresh_with_failed_verification_is_a_skip(self):
        # Same patch, newer base: the PR is refreshed, but it proposes nothing
        # new, so a failed build is a notice naming the PR, not a red lane.
        new_base, _ = self.prepare_behind_base_refresh()
        (self.root / "prepared.json").write_text(json.dumps({"name": "demo", "status": "UPDATED", "verifyFailed": ["attr.one"]}))
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), PR_VIEW_REMOTE_HEAD="1", UPDATE_BASE_SHA=new_base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Pushing update/demo", result.stdout)
        self.assertIn("PR #1 already proposes this patch", (self.root / "skip").read_text())
        verdict = self.matrix_command("verdict")
        self.assertEqual(verdict.returncode, 0, verdict.stdout + verdict.stderr)
        self.assertIn("::notice title=Update lane skipped::demo", verdict.stdout)
        self.assertIn("pull/1", verdict.stdout)
        self.assertNotIn("::error", verdict.stdout)

    def test_new_version_on_existing_pr_with_failed_verification_is_red(self):
        new_base, _ = self.prepare_behind_base_refresh()
        self.git("checkout", "update/demo")
        self.commit("newer upstream version")
        new_tip = self.git("rev-parse", "HEAD")
        self.git("checkout", "main")
        (self.root / "prepared.json").write_text(json.dumps({"name": "demo", "status": "UPDATED", "verifyFailed": ["attr.one"]}))
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), PR_VIEW_REMOTE_HEAD="1", UPDATE_BASE_SHA=new_base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), new_tip)
        self.assertEqual((self.root / "skip").read_text(), "")
        verdict = self.matrix_command("verdict")
        self.assertNotEqual(verdict.returncode, 0)
        self.assertIn("::error title=Update build verification failed::demo", verdict.stdout)
        self.assertIn("pull/1", verdict.stdout)

    def own_pr(self):
        return {"author": {"login": "app/nix-agentic-tools-bot"}, "baseRefName": "main", "headRefName": "update/demo", "headRepository": {"nameWithOwner": "example/example"}, "isCrossRepository": False, "mergeable": "MERGEABLE", "number": 1}

    def closed_pr(self, head=None):
        return dict(self.own_pr(), closedAt="2026-09-13T00:00:00Z", headRefOid=head or self.git("rev-parse", "update/demo"))

    def install_pull_ref(self, head=None):
        head = head or self.git("rev-parse", "update/demo")
        self.git("push", "origin", f"{head}:refs/pull/1/head")
        return head

    def create_remote_only_pull_head(self):
        archive = self.root / "closed-pr"
        subprocess.run(
            ["git", "clone", "--branch", "main", str(self.remote), str(archive)],
            check=True,
            capture_output=True,
        )
        subprocess.run(["git", "config", "user.name", "Bot"], cwd=archive, check=True)
        subprocess.run(["git", "config", "user.email", "bot@example.test"], cwd=archive, check=True)
        (archive / "data").write_text("older closed proposal")
        subprocess.run(["git", "add", "data"], cwd=archive, check=True)
        subprocess.run(["git", "commit", "-m", "chore(packages): update demo"], cwd=archive, check=True, capture_output=True)
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=archive, text=True).strip()
        subprocess.run(
            ["git", "push", "origin", "HEAD:refs/pull/1/head"],
            cwd=archive,
            check=True,
            capture_output=True,
        )
        return head

    def test_unchanged_pr_retries_auto_merge(self):
        self.git("push", "origin", "update/demo")
        env = {"PR_LIST": json.dumps([self.own_pr()])}
        result = self.publish(**env)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = ["pr", "merge", "1", "--squash", "--auto", "--match-head-commit", self.git("rev-parse", "update/demo")]
        self.assertIn(json.dumps(expected), (self.root / "calls").read_text())
        # A failed enable is red. The rollback undoes only an enable the App owns
        # afterwards (this run's own); one a human made meanwhile stays.
        for enabled_by, rollback in ((None, False), ("app/nix-agentic-tools-bot", True), ("human", False)):
            with self.subTest(enabled_by=enabled_by):
                (self.root / "calls").unlink()
                after = {"AUTO_MERGE_ENABLED_AFTER_ARM": "1", "AUTO_MERGE_ENABLED_BY": enabled_by} if enabled_by else {}
                self.assertNotEqual(self.publish(**env, **after, FAIL_ARM="1").returncode, 0)
                merge_calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines() if json.loads(line)[:2] == ["pr", "merge"]]
                self.assertEqual(merge_calls, [expected] + ([["pr", "merge", "1", "--disable-auto"]] if rollback else []))

    def test_preexisting_auto_merge_is_not_removed_when_an_enable_would_fail(self):
        self.git("push", "origin", "update/demo")
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), AUTO_MERGE_ENABLED="1", FAIL_ARM="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertNotIn('["pr", "merge"', calls)
        self.assertEqual(sum("timelineItems" in line for line in calls.splitlines()), 1)
        self.assertFalse((self.root / "auto-merge-disabled").exists())

    def test_malformed_auto_merge_prior_state_fails_before_mutation(self):
        self.git("push", "origin", "update/demo")
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), PR_AUTO_MERGE_RAW=json.dumps({}))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('["pr", "merge"', (self.root / "calls").read_text())

    def test_unchanged_pr_preserves_explicit_human_auto_merge_disable(self):
        self.git("push", "origin", "update/demo")
        human_disable = [{"__typename": "AutoMergeDisabledEvent", "actor": {"login": "human"}, "disabler": {"login": "human"}, "reason": None, "reasonCode": None}]
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), AUTO_MERGE_EVENTS=json.dumps(human_disable))
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertNotIn('["pr", "merge"', calls)
        self.assertEqual((self.root / "touched-branches").read_text(), "update/demo\n")

    def test_unchanged_pr_self_heals_after_automatic_auto_merge_disable(self):
        self.git("push", "origin", "update/demo")
        automatic_disable = [{"__typename": "AutoMergeDisabledEvent", "actor": None, "disabler": None, "reason": "merge conflict", "reasonCode": "MERGE_CONFLICT"}]
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), AUTO_MERGE_EVENTS=json.dumps(automatic_disable))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"--auto"', (self.root / "calls").read_text())

    def test_ordinary_comment_does_not_veto_unchanged_pr(self):
        self.git("push", "origin", "update/demo")
        view = dict(self.own_pr(), comments=[{"author": {"login": "human"}}], headRefOid=self.git("rev-parse", "update/demo"))
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), PR_VIEW=json.dumps(view))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"--auto"', (self.root / "calls").read_text())

    def prepare_behind_base_refresh(self):
        self.git("push", "origin", "update/demo")
        self.git("checkout", "main")
        (self.repo / "base-extra").write_text("main advanced")
        self.git("add", "base-extra")
        self.git("commit", "-m", "main advances")
        new_base = self.git("rev-parse", "HEAD")
        self.git("checkout", "-B", "update/demo", "main")
        self.commit("new")
        new_tip = self.git("rev-parse", "HEAD")
        self.git("checkout", "main")
        return new_base, new_tip

    def test_human_auto_merge_hold_survives_behind_base_refresh(self):
        new_base, new_tip = self.prepare_behind_base_refresh()
        human_disable = [{"__typename": "AutoMergeDisabledEvent", "actor": {"login": "human"}, "disabler": {"login": "human"}, "reason": None, "reasonCode": None}]
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), AUTO_MERGE_EVENTS=json.dumps(human_disable), UPDATE_BASE_SHA=new_base)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertIn('["pr", "edit", "1"', calls)
        self.assertNotIn('["pr", "merge"', calls)
        self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), new_tip)
        self.assertEqual((self.root / "touched-branches").read_text(), "update/demo\n")

    def test_automatic_disable_self_heals_after_behind_base_refresh(self):
        new_base, new_tip = self.prepare_behind_base_refresh()
        automatic_disable = [{"__typename": "AutoMergeDisabledEvent", "actor": None, "disabler": None, "reason": "merge conflict", "reasonCode": "MERGE_CONFLICT"}]
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), AUTO_MERGE_EVENTS=json.dumps(automatic_disable), PR_VIEW_REMOTE_HEAD="1", UPDATE_BASE_SHA=new_base)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertIn('["pr", "edit", "1"', calls)
        self.assertIn('"--auto"', calls)
        self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), new_tip)

    def test_late_head_race_is_left_without_changing_auto_merge(self):
        self.git("push", "origin", "update/demo")
        self.git("checkout", "-b", "human", "update/demo")
        self.git("config", "user.email", "human@example.test")
        self.commit("concurrent human work")
        tip = self.git("rev-parse", "HEAD")
        self.git("push", "origin", "human")
        self.git("checkout", "main")
        self.git("config", "user.email", "bot@example.test")
        bot_tip = self.git("rev-parse", "update/demo")
        for fresh_update in (False, True):
            with self.subTest(fresh_update=fresh_update):
                # Each sweep starts from a fresh checkout of origin.
                self.git("--git-dir", str(self.remote), "update-ref", "refs/heads/update/demo", bot_tip)
                self.git("update-ref", "refs/remotes/origin/update/demo", bot_tip)
                (self.root / "calls").unlink(missing_ok=True)
                if fresh_update:
                    self.git("checkout", "update/demo")
                    self.commit("newer upstream version")
                    self.git("checkout", "main")
                result = self.publish(PR_LIST=json.dumps([self.own_pr()]), ARM_RACE_TIP=tip, AUTO_MERGE_ENABLED="1")
                self.assert_skipped(result, "GitHub shows 1 with another repository, base, head branch, author or head")
                calls = (self.root / "calls").read_text()
                self.assertNotIn('["pr", "merge"', calls)
                self.assertEqual(len(self.comments()), 0)
                if fresh_update:
                    self.assertIn('["pr", "edit", "1"', calls)
                self.assertTrue(self.git("ls-remote", "origin", "refs/heads/update/demo").startswith(tip))

    def test_pr_with_changed_base_is_not_armed(self):
        self.git("push", "origin", "update/demo")
        tip = self.git("rev-parse", "update/demo")
        view = dict(self.own_pr(), baseRefName="another-base", headRefOid=tip)
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), PR_VIEW=json.dumps(view), AUTO_MERGE_ENABLED="1")
        self.assert_left(result, "another repository, base", comment=False)
        self.assertTrue(self.git("ls-remote", "origin", "refs/heads/update/demo").startswith(tip))

    def test_app_pr_on_another_base_preserves_the_stable_branch(self):
        self.git("push", "origin", "update/demo")
        remote_tip = self.git("rev-parse", "refs/remotes/origin/update/demo")
        new_base, _ = self.prepare_behind_base_refresh()
        changed_base = dict(self.own_pr(), baseRefName="release")
        result = self.publish(PR_LIST=json.dumps([changed_base]), UPDATE_BASE_SHA=new_base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), remote_tip)
        calls = (self.root / "calls").read_text()
        self.assertNotIn('["pr", "create"', calls)
        self.assertNotIn('["pr", "edit"', calls)
        self.assertNotIn('["pr", "merge"', calls)
        self.assertNotIn("Pushing update/demo", result.stdout)
        self.assertEqual((self.root / "touched-branches").read_text(), "update/demo\n")

    def test_human_closed_identical_proposal_is_preserved(self):
        self.git("push", "origin", "update/demo")
        closed = self.closed_pr(self.install_pull_ref())
        human_close = [{"__typename": "ClosedEvent", "actor": {"login": "human"}}]
        (self.root / "prepared.json").write_text(json.dumps({"name": "demo", "status": "UPDATED", "verifyFailed": ["attr.one"]}))
        result = self.publish(
            CLOSED_PR_LIST=json.dumps([closed]),
            CLOSE_EVENTS=json.dumps(human_close),
        )
        self.assert_left(result, "human-closed PR #1 already proposed this update", comment=False)
        calls = (self.root / "calls").read_text()
        self.assertNotIn('["pr", "create"', calls)
        self.assertNotIn('["pr", "merge"', calls)
        self.assertNotIn("Pushing update/demo", result.stdout)
        verdict = self.matrix_command("verdict")
        self.assertEqual(verdict.returncode, 0, verdict.stdout + verdict.stderr)
        self.assertIn("::notice title=Update lane skipped::", verdict.stdout)

    def test_unclassified_closed_proposal_fails_before_publication(self):
        self.git("push", "origin", "update/demo")
        result = self.publish(CLOSED_PR_LIST=json.dumps([self.closed_pr()]), CLOSE_EVENTS="[]")
        self.assertNotEqual(result.returncode, 0)
        calls = (self.root / "calls").read_text()
        self.assertNotIn('["pr", "create"', calls)
        self.assertNotIn('["pr", "merge"', calls)
        self.assertNotIn("Pushing update/demo", result.stdout)

    def test_bot_closed_identical_proposal_may_be_recreated(self):
        self.git("push", "origin", "update/demo")
        bot_close = [{"__typename": "ClosedEvent", "actor": {"login": "nix-agentic-tools-bot[bot]"}}]
        result = self.publish(CLOSED_PR_LIST=json.dumps([self.closed_pr()]), CLOSE_EVENTS=json.dumps(bot_close))
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertIn('["pr", "create"', calls)
        self.assertIn('["pr", "merge"', calls)

    def test_human_closed_older_proposal_does_not_suppress_a_new_patch(self):
        self.git("push", "origin", "update/demo")
        closed = self.closed_pr(self.install_pull_ref())
        self.git("checkout", "update/demo")
        self.commit("newer dependency patch")
        self.git("checkout", "main")
        human_close = [{"__typename": "ClosedEvent", "actor": {"login": "human"}}]
        (self.root / "prepared.json").write_text(json.dumps({"name": "demo", "status": "UPDATED", "verifyFailed": ["attr.one"]}))
        result = self.publish(
            CLOSED_PR_LIST=json.dumps([closed]),
            CLOSE_EVENTS=json.dumps(human_close),
            PR_VIEW_REMOTE_HEAD="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertIn('["pr", "create"', calls)
        self.assertIn('["pr", "merge"', calls)
        # A newer diff is a new proposal: published, so its red build is red.
        self.assertEqual((self.root / "skip").read_text(), "")
        verdict = self.matrix_command("verdict")
        self.assertNotEqual(verdict.returncode, 0)
        self.assertIn("::error title=Update build verification failed::demo", verdict.stdout)

    def test_remote_only_closed_head_allows_a_newer_proposal(self):
        closed_head = self.create_remote_only_pull_head()
        self.assertNotEqual(
            subprocess.run(
                ["git", "cat-file", "-e", f"{closed_head}^{{commit}}"],
                cwd=self.repo,
                capture_output=True,
            ).returncode,
            0,
        )
        human_close = [{"__typename": "ClosedEvent", "actor": {"login": "human"}}]
        result = self.publish(
            CLOSED_PR_LIST=json.dumps([self.closed_pr(closed_head)]),
            CLOSE_EVENTS=json.dumps(human_close),
            PR_VIEW_REMOTE_HEAD="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            subprocess.run(
                ["git", "cat-file", "-e", f"{closed_head}^{{commit}}"],
                cwd=self.repo,
                capture_output=True,
            ).returncode,
            0,
        )
        calls = (self.root / "calls").read_text()
        self.assertIn('["pr", "create"', calls)
        self.assertIn('["pr", "merge"', calls)

    def test_unavailable_or_mismatched_closed_head_is_preserved(self):
        self.git("push", "origin", "update/demo")
        human_close = [{"__typename": "ClosedEvent", "actor": {"login": "human"}}]
        for mode in ("unavailable", "mismatched"):
            with self.subTest(mode=mode):
                (self.root / "calls").unlink(missing_ok=True)
                self.git("--git-dir", str(self.remote), "update-ref", "-d", "refs/pull/1/head")
                if mode == "mismatched":
                    self.install_pull_ref(self.base)
                result = self.publish(
                    CLOSED_PR_LIST=json.dumps([self.closed_pr()]),
                    CLOSE_EVENTS=json.dumps(human_close),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = (self.root / "calls").read_text()
                self.assertNotIn('["pr", "create"', calls)
                self.assertNotIn('["pr", "merge"', calls)
                self.assertNotIn("Pushing update/demo", result.stdout)

    def test_human_owned_pr_is_never_edited_or_armed(self):
        self.git("push", "origin", "update/demo")
        result = self.publish(PR_LIST=json.dumps([dict(self.own_pr(), author={"login": "human"})]))
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertNotIn('["pr", "merge"', calls)
        self.assertNotIn('["pr", "edit"', calls)
        self.assertEqual((self.root / "touched-branches").read_text(), "update/demo\n")

    def test_same_named_fork_pr_does_not_capture_publication(self):
        fork = dict(self.own_pr(), isCrossRepository=True, headRepository={"nameWithOwner": "foreign/fork"})
        result = self.publish(PR_LIST=json.dumps([fork]))
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertIn('["pr", "create"', calls)
        self.assertNotIn('["pr", "edit"', calls)

    def test_head_github_does_not_credit_to_the_app_is_left(self):
        # Every commit is the bot's, but GitHub credits the push to someone
        # else, or has no activity row for it yet. Either way it is not the
        # bot's own last push as far as it can tell: skipped with a notice and
        # no comment (no human commit), never re-read, never red, even when
        # this target's build verification failed.
        self.git("push", "origin", "update/demo")
        tip = self.git("rev-parse", "update/demo")
        (self.root / "prepared.json").write_text(json.dumps({"name": "demo", "status": "UPDATED", "verifyFailed": ["attr.one"]}))
        for env in ({"PUSH_ACTOR": "human"}, {"ACTIVITY_EMPTY": "1"}):
            with self.subTest(env=env):
                (self.root / "calls").unlink(missing_ok=True)
                result = self.publish(PR_LIST=json.dumps([self.own_pr()]), AUTO_MERGE_ENABLED="1", **env)
                self.assert_left(result, f"GitHub does not credit {tip} to the App's push.", comment=False)
                self.assertEqual((self.root / "calls").read_text().count("/activity"), 1)
                self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), tip)
                self.assertFalse((self.root / "auto-merge-disabled").exists())
                verdict = self.matrix_command("verdict")
                self.assertEqual(verdict.returncode, 0, verdict.stdout + verdict.stderr)

    def test_push_activity_api_error_is_red_never_a_human_edit(self):
        self.git("push", "origin", "update/demo")
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), ACTIVITY_ERROR="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("::error::Could not read GitHub's push activity for update/demo.", result.stdout)
        self.assertNotIn("Leaving", result.stdout)
        self.assertEqual((self.root / "skip").read_text(), "")
        self.assertNotIn('["pr", "comment"', (self.root / "calls").read_text())

    def test_human_reenabled_auto_merge_survives_two_sweeps(self):
        self.git("checkout", "update/demo")
        bot_tip = self.git("rev-parse", "HEAD")
        self.git("config", "user.email", "human@example.test")
        self.commit("human fix")
        human_tip = self.git("rev-parse", "HEAD")
        self.git("push", "origin", "update/demo")
        self.git("reset", "--hard", bot_tip)
        self.git("checkout", "main")
        self.git("config", "user.email", "bot@example.test")
        human_enable = [{"__typename": "AutoMergeEnabledEvent", "actor": {"login": "human"}, "enabler": {"login": "human"}}]
        for sweep in range(2):
            with self.subTest(sweep=sweep):
                (self.root / "calls").unlink(missing_ok=True)
                result = self.publish(
                    PR_LIST=json.dumps([self.own_pr()]),
                    PUSH_ACTOR="human",
                    AUTO_MERGE_ENABLED="1",
                    AUTO_MERGE_ENABLED_BY="human",
                    AUTO_MERGE_EVENTS=json.dumps(human_enable),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), human_tip)
                self.assertEqual((self.root / "touched-branches").read_text(), "update/demo\n")
                self.assertNotIn('["pr", "merge"', (self.root / "calls").read_text())

    def test_evaluator_caps_reject_values_below_memory_floor(self):
        command = 'source "$1"; NAT_UPDATE_CORES=4; NAT_UPDATE_JOBS=1; nfb_eval_flags'
        for memory, expected in (("512", 1), ("4096", 0)):
            env = dict(self.env, GITHUB_TOKEN="fixture", NAT_UPDATE_EVAL_WORKERS="1", NAT_UPDATE_EVAL_MAX_MEMORY=memory)
            result = subprocess.run(["bash", "-c", command, "test", str(SCRIPTS / "update-common.sh")], cwd=self.repo, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stderr)
            if expected == 0:
                self.assertIn("--eval-workers 1", result.stdout)

    def test_evaluator_minimum_cannot_exceed_total_memory_budget(self):
        command = '''source "$1"
NAT_UPDATE_CORES=4
NAT_UPDATE_JOBS=$TEST_JOBS
awk() { printf '%s' "$TEST_MEMORY_MIB"; }
nfb_eval_flags
'''
        for memory, jobs, workers, success in ((4096, 4, 1, False), (4096, 1, 4, True), (4096, 1, 1, True), (8192, 4, 4, True), (16384, 4, 1, True), (16384, 1, 4, True), (1024, 1, 1, False)):
            with self.subTest(memory=memory, jobs=jobs, workers=workers):
                env = dict(self.env, GITHUB_TOKEN="fixture", NAT_UPDATE_EVAL_WORKERS=str(workers),
                           NAT_UPDATE_EVAL_MAX_MEMORY="4096", TEST_JOBS=str(jobs), TEST_MEMORY_MIB=str(memory))
                result = subprocess.run(["bash", "-c", command, "test", str(SCRIPTS / "update-common.sh")],
                                        cwd=self.repo, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stderr)
                if success:
                    flags = result.stdout.split()
                    actual_workers = int(flags[flags.index("--eval-workers") + 1])
                    allocation = int(flags[flags.index("--eval-max-memory-size") + 1])
                    self.assertGreaterEqual(allocation, 1024)
                    self.assertLessEqual(allocation * jobs * actual_workers, memory * 60 // 100)
                else:
                    self.assertIn("reduce NAT_UPDATE_JOBS", result.stderr)

    def test_human_amend_preserving_bot_author_is_preserved(self):
        self.git("checkout", "update/demo")
        bot_tip = self.git("rev-parse", "HEAD")
        self.git("config", "user.email", "human@example.test")
        (self.repo / "data").write_text("human amendment")
        self.git("add", "data")
        self.git("commit", "--amend", "--no-edit")
        human_tip = self.git("rev-parse", "HEAD")
        self.git("push", "origin", "update/demo")
        self.git("reset", "--hard", bot_tip)
        self.git("checkout", "main")
        self.git("config", "user.email", "bot@example.test")
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), AUTO_MERGE_ENABLED="1")
        self.assert_left(result, f"non-bot commits are on {human_tip}")
        self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), human_tip)

    def cleanup(self, prs=None, touched="", **overrides):
        (self.root / "update-completed.flag").touch()
        (self.root / "touched-branches").write_text(touched)
        view = dict(self.own_pr(), comments=[], reviews=[], headRefOid=self.git("rev-parse", "update/demo"))
        bot = {"login": "nix-agentic-tools-bot[bot]"}
        env = dict(self.env, COMMIT_PAGES=json.dumps([[{"author": bot, "committer": bot}]]), PR_LIST=json.dumps(prs or [self.own_pr()]), PR_VIEW=json.dumps(view), REMOTE=str(self.remote))
        env.update(overrides)
        return subprocess.run(["bash", str(SCRIPTS / "update-cleanup.sh")], cwd=self.repo, env=env, capture_output=True, text=True)

    def test_cleanup_reaches_candidates_beyond_the_first_page(self):
        self.git("push", "origin", "update/demo")
        prs = [dict(self.own_pr(), headRefName=f"update/keep{i}", number=i + 1) for i in range(31)]
        prs.append(dict(self.own_pr(), number=32))
        result = self.cleanup(prs, touched="".join(f"update/keep{i}\n" for i in range(31)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('["pr", "close", "32"', (self.root / "calls").read_text())
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/update/demo"), "")

    def test_cleanup_preserves_human_or_unmapped_committer(self):
        self.git("push", "origin", "update/demo")
        for committer in ({"login": "human"}, None):
            pages = [[{"author": {"login": "nix-agentic-tools-bot[bot]"}, "committer": committer}]]
            result = self.cleanup(COMMIT_PAGES=json.dumps(pages))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('["pr", "close"', (self.root / "calls").read_text())
            self.assertNotEqual(self.git("ls-remote", "origin", "refs/heads/update/demo"), "")

    def test_cleanup_preserves_human_unknown_or_truncated_activity(self):
        self.git("push", "origin", "update/demo")
        for field in ("comments", "reviews"):
            for activity in ([{"author": {"login": "human"}}], [{"author": None}], [{"author": {"login": "copilot[bot]"}}] * 100):
                view = dict(self.own_pr(), comments=[], reviews=[], headRefOid=self.git("rev-parse", "update/demo"))
                view[field] = activity
                result = self.cleanup(PR_VIEW=json.dumps(view))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('["pr", "close"', (self.root / "calls").read_text())

    def test_cleanup_refuses_a_potentially_truncated_pr_list(self):
        result = self.cleanup([{}] * 1000)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('["pr", "close"', (self.root / "calls").read_text())

    def test_cleanup_preserves_human_inline_reply_and_human_push(self):
        self.git("push", "origin", "update/demo")
        threads = {"nodes": [{"comments": {"nodes": [{"author": {"login": "human"}}], "pageInfo": {"hasNextPage": False}}}], "pageInfo": {"hasNextPage": False}}
        for env in ({"REVIEW_THREADS": json.dumps(threads)}, {"PUSH_ACTOR": "human"}):
            result = self.cleanup(**env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('["pr", "close"', (self.root / "calls").read_text())

    def test_cleanup_reopens_pr_when_head_changes_after_snapshot(self):
        self.git("push", "origin", "update/demo")
        self.git("checkout", "-b", "human", "update/demo")
        self.commit("concurrent human work")
        race_tip = self.git("rev-parse", "HEAD")
        self.git("push", "origin", "human")
        self.git("checkout", "main")
        result = self.cleanup(RACE_TIP=race_tip)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('["pr", "reopen", "1"]', (self.root / "calls").read_text())
        self.assertTrue(self.git("ls-remote", "origin", "refs/heads/update/demo").startswith(race_tip))

    def test_cleanup_reopens_for_human_activity_arriving_during_close(self):
        self.git("push", "origin", "update/demo")
        tip = self.git("rev-parse", "update/demo")
        human = {"author": {"login": "human"}}
        view = dict(self.own_pr(), comments=[], reviews=[], headRefOid=tip)
        threads = {"nodes": [{"comments": {"nodes": [human], "pageInfo": {"hasNextPage": False}}}], "pageInfo": {"hasNextPage": False}}
        for env in (
            {"POST_CLOSE_VIEW": json.dumps(dict(view, comments=[human]))},
            {"POST_CLOSE_VIEW": json.dumps(dict(view, reviews=[human]))},
            {"POST_CLOSE_THREADS": json.dumps(threads)},
        ):
            with self.subTest(env=env):
                (self.root / "closed").unlink(missing_ok=True)
                (self.root / "calls").unlink(missing_ok=True)
                result = self.cleanup(**env)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = (self.root / "calls").read_text()
                self.assertIn('["pr", "close", "1"', calls)
                self.assertIn('["pr", "reopen", "1"]', calls)
                self.assertTrue(self.git("ls-remote", "origin", "refs/heads/update/demo").startswith(tip))

    def test_cleanup_retries_a_transient_reopen_failure(self):
        self.git("push", "origin", "update/demo")
        tip = self.git("rev-parse", "update/demo")
        human = {"author": {"login": "human"}}
        view = dict(self.own_pr(), comments=[human], reviews=[], headRefOid=tip)
        result = self.cleanup(POST_CLOSE_VIEW=json.dumps(view), REOPEN_FAILURES="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "reopen-attempts").read_text(), "2")
        self.assertTrue(self.git("ls-remote", "origin", "refs/heads/update/demo").startswith(tip))

    def cleanup_after_persistent_reopen_failure(self, activity_on_first=False):
        self.git("checkout", "-b", "update/later", "main")
        self.commit("later update")
        self.git("push", "origin", "update/demo", "update/later")
        self.git("checkout", "main")
        tips = {
            "1": self.git("rev-parse", "update/demo"),
            "2": self.git("rev-parse", "update/later"),
        }
        prs = [self.own_pr(), dict(self.own_pr(), headRefName="update/later", number=2)]
        views = {
            number: dict(prs[int(number) - 1], comments=[], reviews=[], headRefOid=tip)
            for number, tip in tips.items()
        }
        overrides = {}
        if activity_on_first:
            post_close_views = {number: dict(view) for number, view in views.items()}
            post_close_views["1"]["comments"] = [{"author": {"login": "human"}}]
            overrides["POST_CLOSE_VIEWS"] = json.dumps(post_close_views)
        result = self.cleanup(prs, PR_VIEWS=json.dumps(views), REOPEN_FAILURES="3", **overrides)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "reopen-attempts").read_text(), "3")
        self.assertTrue(self.git("ls-remote", "origin", "refs/heads/update/demo").startswith(tips["1"]))
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/update/later"), "")
        self.assertIn('["pr", "close", "2"', (self.root / "calls").read_text())

    def test_cleanup_finishes_sweep_after_activity_reopen_failure(self):
        self.cleanup_after_persistent_reopen_failure(activity_on_first=True)

    def test_cleanup_finishes_sweep_after_delete_reopen_failure(self):
        hook = self.remote / "hooks" / "update"
        hook.write_text("""#!/usr/bin/env python3
import sys

ref, _, new = sys.argv[1:]
if new == "0" * 40 and ref == "refs/heads/update/demo":
    raise SystemExit(1)
""")
        hook.chmod(0o755)
        self.cleanup_after_persistent_reopen_failure()

    def test_cleanup_preserves_branch_if_pr_no_longer_closed(self):
        self.git("push", "origin", "update/demo")
        tip = self.git("rev-parse", "update/demo")
        for state in ("OPEN", "MERGED", None):
            with self.subTest(state=state):
                (self.root / "closed").unlink(missing_ok=True)
                (self.root / "calls").unlink(missing_ok=True)
                view = dict(self.own_pr(), comments=[], reviews=[], headRefOid=tip, state=state)
                result = self.cleanup(POST_CLOSE_VIEW=json.dumps(view))
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = (self.root / "calls").read_text()
                self.assertIn('["pr", "close", "1"', calls)
                self.assertNotIn('["pr", "reopen"', calls)
                self.assertTrue(self.git("ls-remote", "origin", "refs/heads/update/demo").startswith(tip))

    def test_cleanup_preserves_pr_when_base_changes_before_and_after_close(self):
        self.git("push", "origin", "update/demo")
        tip = self.git("rev-parse", "update/demo")
        view = dict(self.own_pr(), baseRefName="another-base", comments=[], reviews=[], headRefOid=tip)
        for phase in ("PR_VIEW", "POST_CLOSE_VIEW"):
            with self.subTest(phase=phase):
                (self.root / "closed").unlink(missing_ok=True)
                (self.root / "calls").unlink(missing_ok=True)
                result = self.cleanup(**{phase: json.dumps(view)})
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = (self.root / "calls").read_text()
                self.assertEqual('["pr", "close", "1"' in calls, phase == "POST_CLOSE_VIEW")
                self.assertEqual('["pr", "reopen", "1"]' in calls, phase == "POST_CLOSE_VIEW")
                self.assertTrue(self.git("ls-remote", "origin", "refs/heads/update/demo").startswith(tip))

    def test_cleanup_without_complete_sweep_does_nothing(self):
        result = subprocess.run(["bash", str(SCRIPTS / "update-cleanup.sh")], cwd=self.repo, env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse((self.root / "calls").exists())


class PreparationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "source"
        self.bin = self.root / "bin"
        (self.repo / "packages" / "demo").mkdir(parents=True)
        self.bin.mkdir()
        (self.repo / "flake.lock").write_text("{}\n")
        (self.repo / "devenv.lock").write_text("{}\n")
        (self.repo / "devenv.yaml").write_text("inputs: {}\n")
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()
        (self.upstream / "go.mod").write_text("module example.test/demo\n\ngo 1.26.8\n")
        self.write_recipe(False)
        subprocess.run(["git", "init", "-b", "main"], cwd=self.repo, check=True, capture_output=True)
        self.git("config", "core.hooksPath", "/dev/null")
        self.git("config", "user.name", "Bot")
        self.git("config", "user.email", "bot@example.test")
        self.git("add", ".")
        self.git("commit", "-m", "base")
        self.base = self.git("rev-parse", "HEAD")
        self.write_stubs()
        self.env = dict(
            os.environ,
            GITHUB_TOKEN="fixture",
            NAT_UPDATE_WORKTREES_DIR=str(self.root / "worktrees"),
            NIX_CALLS=str(self.root / "nix-calls"),
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            WORKTREE_LOCK=str(self.root / "worktree.lock"),
        )

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-c", "core.hooksPath=/dev/null", *args],
            cwd=self.repo,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()

    def write_recipe(self, marker, floor=False):
        marker_lines = ""
        if marker:
            marker_lines = '  # upstream: readPackageJsonVersion @ package.json\n  upstream = "1.0.0";\n'
        floor_line = '  goFloor = "1.25.12";\n' if floor else ""
        (self.repo / "packages" / "demo" / "package.nix").write_text(
            '{fetchFromGitHub}:\nfetchFromGitHub {\n'
            f'{marker_lines}{floor_line}  rev = "{"0" * 40}";\n'
            f'  hash = "sha256-{"A" * 43}=";\n'
            '}\n'
        )

    def write_executable(self, name, contents):
        path = self.bin / name
        path.write_text(contents)
        path.chmod(0o755)

    def write_stubs(self):
        real_git = shutil.which("git")
        real_awk = shutil.which("awk")
        self.write_executable(
            "git",
            f"""#!/usr/bin/env python3
import os, sys
if sys.argv[1:2] == ['ls-remote']:
    print(os.environ.get('NEW_REV', '{'1' * 40}') + '\\tHEAD')
    raise SystemExit(0)
os.execv({real_git!r}, [{real_git!r}, *sys.argv[1:]])
""",
        )
        self.write_executable("nproc", "#!/usr/bin/env python3\nprint(16)\n")
        self.write_executable(
            "awk",
            f"""#!/usr/bin/env python3
import os, sys
if '/proc/meminfo' in sys.argv:
    print(os.environ.get('TEST_MEMORY_MIB', '8192'), end='')
    raise SystemExit(0)
os.execv({real_awk!r}, [{real_awk!r}, *sys.argv[1:]])
""",
        )
        self.write_executable(
            "devenv",
            "#!/usr/bin/env python3\nraise SystemExit(0)\n",
        )
        self.write_executable(
            "nix",
            """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['NIX_CALLS'], 'a') as f: f.write(json.dumps(args) + '\\n')
mode = os.environ.get('NIX_MODE', '')
# regenerate_sidecars' roster: the fixture packages expose no
# passthru.regenerateExtracted, so both its build and its eval list nothing.
if args[:1] in (['build'], ['eval']) and 'regenerateExtracted' in ' '.join(args):
    raise SystemExit(0)
if args[:1] == ['eval']:
    joined = ' '.join(args)
    if 'vu.readPackageJsonVersion' in joined and mode == 'upstream-eval-failed':
        print('partial version', end='')
        print('error:', file=sys.stderr)
        print('       … while evaluating the attribute version', file=sys.stderr)
        print('       … while calling the readPackageJsonVersion helper', file=sys.stderr)
        print('       error: expected a set but found a function', file=sys.stderr)
        raise SystemExit(17)
    if 'fixGoFloor' in joined:
        print('true' if mode.startswith('floor') else 'false', end='')
    elif 'drvAttrs' in joined:
        git_spec = {'mode': 'git', 'url': 'https://example.test/demo.git', 'name': 'source', 'args': ['--fetch-submodules'], 'unsupported': []}
        specs = {
            'floor-sparse': dict(git_spec, args=['--sparse-checkout', 'src\\ndocs']),
            'floor-submodules': git_spec,
            'git-failed': git_spec,
            'git-unsupported': dict(git_spec, unsupported=['postFetch']),
        }
        print(json.dumps(specs.get(mode, {'mode': 'archive'})))
    elif 'builtins.currentSystem' in joined: print('x86_64-linux')
    elif 'builtins.attrNames' in joined:
        print(json.dumps(['alpha', 'beta'] if mode == 'input-partial' else ['oxlint'] if mode.startswith('input-') else ['demo']))
    elif 'updateTargets.demo.file' in joined: print('packages/demo/package.nix')
    elif 'formatter.x86_64-linux.outPath' in joined: print('/fixture/formatter')
    elif 'generate-devenv-yaml.nix' in joined: print('inputs: {}')
    raise SystemExit(0)
if args[:2] == ['flake', 'update']:
    Path('flake.lock').write_text('{"updated": true}\\n')
    print("Updated input 'demo': (2026-09-12) -> (2026-09-13)")
    raise SystemExit(0)
if args[:2] == ['flake', 'prefetch']:
    values = {
        'empty': '',
        'failed': '',
        'missing_hash': '{}',
        'malformed': '{',
        'no-store': json.dumps({'hash': 'sha256-' + 'B' * 43 + '='}),
    }
    if mode.startswith('floor') or mode == 'upstream-eval-failed':
        print(json.dumps({'hash': 'sha256-' + 'B' * 43 + '=', 'storePath': os.environ['UPSTREAM_SOURCE']}), end='')
    else:
        print(values.get(mode, ''), end='')
    raise SystemExit(9 if mode == 'failed' else 0)
if args[:1] == ['run'] and 'nixpkgs#nix-prefetch-git' in args:
    if mode == 'git-failed': raise SystemExit(9)
    print(json.dumps({'hash': 'sha256-' + 'C' * 43 + '=', 'path': os.environ['UPSTREAM_SOURCE']}))
    raise SystemExit(0)
if args[:1] == ['run']:
    if mode.startswith('floor'):
        with open(os.environ['CALL_ORDER'], 'a') as f: f.write('nix-update\\n')
        raise SystemExit(0)
    if mode == 'package-red':
        with open('packages/demo/package.nix', 'a') as f: f.write('# dependency hash refreshed\\n')
        print('Update 1.0.0 -> 2.0.0')
        raise SystemExit(0)
    result = args[args.index('--result-file') + 1]
    if mode == 'input-hash':
        mismatch = "error: hash mismatch in fixed-output derivation '/nix/store/fixture-oxlint-pnpm-deps.drv':\\n         specified: sha256-OLD=\\n            got: sha256-NEW="
        Path(result).write_text(json.dumps({'results': [
            {'type': 'EVAL', 'attr': 'oxlint', 'success': True, 'drvPath': '/nix/store/oxlint.drv'},
            {'type': 'BUILD', 'attr': 'oxlint', 'success': False, 'error': 'build exited with 1'},
        ]}))
        print(mismatch, file=sys.stderr)
        raise SystemExit(1)
    if mode == 'input-compiler':
        Path(result).write_text(json.dumps({'results': [
            {'type': 'EVAL', 'attr': 'oxlint', 'success': True, 'drvPath': '/nix/store/oxlint.drv'},
            {'type': 'BUILD', 'attr': 'oxlint', 'success': False, 'error': 'compiler error: incompatible Rust API'},
        ]}))
        print('error: could not compile oxlint: incompatible Rust API', file=sys.stderr)
        raise SystemExit(1)
    if mode == 'input-empty':
        Path(result).write_text(json.dumps({'results': []}))
        raise SystemExit(9)
    if mode == 'input-partial':
        Path(result).write_text(json.dumps({'results': [
            {'type': 'EVAL', 'attr': 'alpha', 'success': True, 'cacheStatus': 'cached'},
        ]}))
        raise SystemExit(9)
    Path(result).write_text(json.dumps({'results': [
        {'type': 'EVAL', 'attr': 'demo', 'success': True, 'cacheStatus': 'local'},
    ]}))
    raise SystemExit(0)
if args[:1] == ['fmt']: raise SystemExit(0)
if args[:1] == ['build']:
    if args[-1:] == ['.#ciPackages.x86_64-linux.demo.fixGoFloor'] and mode.startswith('floor'):
        # Model the refresh capability at the mocked Nix boundary: the build
        # prints an executable standing in for the fixer. The native
        # go-floor-fixer check owns generated-script execution; this fixture
        # verifies worker ordering and rollback without requiring /nix/store.
        fixer = Path(os.environ['CALL_ORDER']).with_name('fix-go-floor')
        fixer.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
with open(os.environ['CALL_ORDER'], 'a') as f: f.write('floor-fixer\\\\n')
if os.environ['NIX_MODE'] == 'floor-fail': raise SystemExit(17)
recipe = Path('packages/demo/package.nix')
recipe.write_text(recipe.read_text().replace('goFloor = "1.25.12";', 'goFloor = "1.26.8";'))
''')
        fixer.chmod(0o755)
        print(fixer)
        raise SystemExit(0)
    raise SystemExit(23 if mode == 'package-red' else 0)
raise SystemExit(f'unhandled nix fixture arguments: {args}')
""",
        )

    def run_package(self, mode, marker=False, floor=False, new_rev=None):
        if marker or floor:
            self.write_recipe(marker, floor)
            self.git("add", "packages/demo/package.nix")
            self.git("commit", "-m", "specialized recipe")
            self.base = self.git("rev-parse", "HEAD")
        env = dict(
            self.env,
            CALL_ORDER=str(self.root / "call-order"),
            NIX_MODE=mode,
            UPSTREAM_SOURCE=str(self.upstream),
        )
        if new_rev is not None:
            env["NEW_REV"] = new_rev
        return subprocess.run(
            ["bash", str(SCRIPTS / "update-pkg.sh"), "demo", "--version", "skip", "https://github.com/example/demo.git"],
            cwd=self.repo,
            env=env,
            capture_output=True,
            text=True,
        )

    def test_go_floor_fixer_runs_before_nix_update_and_amends_rev_bump(self):
        result = self.run_package("floor", floor=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "call-order").read_text().splitlines(), ["floor-fixer", "nix-update"])
        updated = self.git("show", "update/demo:packages/demo/package.nix")
        self.assertIn('goFloor = "1.26.8";', updated)
        self.assertEqual(self.git("rev-list", "--count", f"{self.base}..update/demo"), "1")

    def test_git_source_prefetches_with_the_fetchers_own_flags(self):
        result = self.run_package("floor-submodules", floor=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = list(map(json.loads, (self.root / "nix-calls").read_text().splitlines()))
        self.assertFalse(any(call[:2] == ["flake", "prefetch"] for call in calls))
        prefetch = next(call for call in calls if "nixpkgs#nix-prefetch-git" in call)
        self.assertEqual(
            prefetch[prefetch.index("--") + 1:],
            ["--quiet", "--url", "https://example.test/demo.git", "--rev", "1" * 40, "--name", "source", "--fetch-submodules"],
        )
        self.assertEqual((self.root / "call-order").read_text().splitlines(), ["floor-fixer", "nix-update"])
        updated = self.git("show", "update/demo:packages/demo/package.nix")
        self.assertIn(f'hash = "sha256-{"C" * 43}=";', updated)
        self.assertIn('goFloor = "1.26.8";', updated)

    def test_git_source_prefetch_keeps_a_multi_line_argument_whole(self):
        # fetchgit/builder.sh passes the newline-joined sparseCheckoutText as
        # ONE argument; a line-split read would hand nix-prefetch-git two.
        result = self.run_package("floor-sparse", floor=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = list(map(json.loads, (self.root / "nix-calls").read_text().splitlines()))
        prefetch = next(call for call in calls if "nixpkgs#nix-prefetch-git" in call)
        self.assertEqual(prefetch[prefetch.index("--name") + 2:], ["--sparse-checkout", "src\ndocs"])

    def test_git_source_prefetch_failures_hold_the_target_back(self):
        for mode, reason in (
            ("git-failed", "source prefetch did not produce a valid hash"),
            ("git-unsupported", "source fetcher cannot be prefetched"),
        ):
            with self.subTest(mode=mode):
                result = self.run_package(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = (self.repo / ".update-report.txt").read_text()
                self.assertIn("HELD BACK: demo", report)
                self.assertIn(reason, report)
                self.assertEqual(self.git("rev-parse", "update/demo"), self.base)
                self.assertFalse(any(call[:1] == ["run"] and "nixpkgs#nix-prefetch-git" not in call
                                     for call in map(json.loads, (self.root / "nix-calls").read_text().splitlines())))
                (self.repo / ".update-report.txt").unlink()
                (self.root / "nix-calls").unlink()

    def test_go_floor_fixer_failure_holds_back_and_resets_rev_bump(self):
        result = self.run_package("floor-fail", floor=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("rev-parse", "update/demo"), self.base)
        self.assertIn("HELD BACK: demo", (self.repo / ".update-report.txt").read_text())
        self.assertEqual((self.root / "call-order").read_text().splitlines(), ["floor-fixer"])

    def test_go_floor_fixer_repairs_unchanged_rev(self):
        result = self.run_package("floor-unchanged", floor=True, new_rev="0" * 40)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "call-order").read_text().splitlines(), ["floor-fixer", "nix-update"])
        updated = self.git("show", "update/demo:packages/demo/package.nix")
        self.assertIn('goFloor = "1.26.8";', updated)

    def test_main_tracking_prefetch_failures_hold_the_target_back(self):
        for mode in ("empty", "failed", "missing_hash", "malformed"):
            with self.subTest(mode=mode):
                result = self.run_package(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = (self.repo / ".update-report.txt").read_text()
                self.assertIn("HELD BACK: demo", report)
                self.assertNotIn("UPDATED: demo", report)
                self.assertEqual(self.git("rev-parse", "update/demo"), self.base)
                self.assertFalse(any(call[:1] == ["run"] for call in map(json.loads, (self.root / "nix-calls").read_text().splitlines())))
                (self.repo / ".update-report.txt").unlink()
                (self.root / "nix-calls").unlink()

    def test_upstream_version_eval_failure_reports_error_and_rolls_back(self):
        result = self.run_package("upstream-eval-failed", marker=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.repo / ".update-report.txt").read_text()
        self.assertIn("HELD BACK: demo", report)
        self.assertIn("upstream version not derivable", report)
        self.assertIn("error: expected a set but found a function", report)
        self.assertEqual(len(report.splitlines()), 1)
        self.assertTrue(report.rstrip().endswith("(upstream version not derivable)"))
        self.assertIn("       … while evaluating the attribute version\n", result.stderr)
        self.assertIn("       error: expected a set but found a function\n", result.stderr)
        self.assertNotIn("UPDATED: demo", report)
        self.assertEqual(self.git("rev-parse", "update/demo"), self.base)
        calls = list(map(json.loads, (self.root / "nix-calls").read_text().splitlines()))
        self.assertTrue(any("vu.readPackageJsonVersion" in " ".join(call) for call in calls))
        self.assertFalse(any(call[:1] == ["run"] for call in calls))

    def test_marker_target_with_empty_prefetch_never_reaches_later_source_repair(self):
        result = self.run_package("empty", marker=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.repo / ".update-report.txt").read_text()
        self.assertIn("HELD BACK: demo", report)
        self.assertNotIn("UPDATED: demo", report)
        self.assertFalse(any(call[:1] == ["run"] for call in map(json.loads, (self.root / "nix-calls").read_text().splitlines())))

    def test_marker_target_requires_the_prefetched_source_tree(self):
        result = self.run_package("no-store", marker=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.repo / ".update-report.txt").read_text()
        self.assertIn("source prefetch did not produce the marker source tree", report)
        self.assertNotIn("UPDATED: demo", report)

    def test_complete_but_failing_build_package_remains_publishable(self):
        result = subprocess.run(
            ["bash", str(SCRIPTS / "update-pkg.sh"), "demo", "--version", "skip"],
            cwd=self.repo,
            env=dict(self.env, NIX_MODE="package-red"),
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.repo / ".update-report.txt").read_text()
        self.assertIn("UPDATED: demo", report)
        self.assertIn("build verification failed", result.stderr)
        failed = matrix.verify_failures(self.repo / ".update-logs", "demo", "UPDATED")
        self.assertEqual(len(failed), 1)
        self.assertTrue(failed[0].endswith(".demo"), failed)

    def test_default_four_jobs_on_eight_gib_starts_the_verifier(self):
        command = 'source "$1"; verify_all_packages'
        result = subprocess.run(
            ["bash", "-c", command, "test", str(SCRIPTS / "update-common.sh")],
            cwd=self.repo,
            env=dict(self.env, NIX_MODE="nfb-success", TEST_MEMORY_MIB="8192"),
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = list(map(json.loads, (self.root / "nix-calls").read_text().splitlines()))
        verifier = next(call for call in calls if call[:1] == ["run"])
        self.assertEqual(verifier[verifier.index("--eval-workers") + 1], "1")

    def test_verifier_setup_rejection_holds_input_back_without_committing(self):
        result = subprocess.run(
            ["bash", str(SCRIPTS / "update-input.sh"), "demo"],
            cwd=self.repo,
            env=dict(self.env, NAT_UPDATE_EVAL_MAX_MEMORY="512", NIX_MODE="input", TEST_MEMORY_MIB="8192"),
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.repo / ".update-report.txt").read_text()
        self.assertIn("HELD BACK: demo", report)
        self.assertNotIn("UPDATED: demo", report)
        self.assertEqual(self.git("rev-parse", "update/demo"), self.base)
        calls = list(map(json.loads, (self.root / "nix-calls").read_text().splitlines()))
        self.assertFalse(any(call[:1] == ["run"] for call in calls))

    def test_unresolved_input_fixed_output_hash_is_held_back(self):
        result = subprocess.run(
            ["bash", str(SCRIPTS / "update-input.sh"), "demo"],
            cwd=self.repo,
            env=dict(self.env, NIX_MODE="input-hash", TEST_MEMORY_MIB="8192"),
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.repo / ".update-report.txt").read_text()
        self.assertIn("HELD BACK: demo", report)
        self.assertNotIn("UPDATED: demo", report)
        self.assertEqual(self.git("rev-parse", "update/demo"), self.base)

    def test_incomplete_input_verification_is_held_back_after_retry(self):
        for mode in ("input-empty", "input-partial"):
            with self.subTest(mode=mode):
                result = subprocess.run(
                    ["bash", str(SCRIPTS / "update-input.sh"), "demo"],
                    cwd=self.repo,
                    env=dict(self.env, NIX_MODE=mode, TEST_MEMORY_MIB="8192"),
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                report = (self.repo / ".update-report.txt").read_text()
                self.assertIn("HELD BACK: demo", report)
                self.assertNotIn("UPDATED: demo", report)
                self.assertIn("verification retry was incomplete", result.stderr)
                self.assertEqual(self.git("rev-parse", "update/demo"), self.base)
                self.git("branch", "-D", "update/demo")
                (self.repo / ".update-report.txt").unlink()
                (self.root / "nix-calls").unlink()

    def test_ordinary_input_compiler_failure_remains_publishable(self):
        result = subprocess.run(
            ["bash", str(SCRIPTS / "update-input.sh"), "demo"],
            cwd=self.repo,
            env=dict(self.env, NIX_MODE="input-compiler", TEST_MEMORY_MIB="8192"),
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.repo / ".update-report.txt").read_text()
        self.assertIn("UPDATED: demo", report)
        self.assertIn("build verification failed (oxlint)", result.stderr)
        self.assertEqual(matrix.verify_failures(self.repo / ".update-logs", "demo", "UPDATED"), ["oxlint"])


class HoldBackEscalationTest(unittest.TestCase):
    """A held-back target leaves the sweep green; only a REPEAT may fail it."""

    def receipt(self, name, status, detail=None):
        return {"base": "b", "detail": detail or f"{status}: {name}", "name": name, "status": status, "touched": []}

    def test_repeat_escalates_while_a_first_offense_only_warns(self):
        held = {"oxlint": "HELD BACK: oxlint (nix-update...)", "beads": "HELD BACK: beads"}
        repeated, unreadable, fresh = matrix.escalation(held, {"beads": "UPDATED", "oxlint": "HELD BACK"})
        self.assertEqual((repeated, unreadable, fresh), (["oxlint"], [], ["beads"]))

    def test_absent_predecessor_receipt_is_a_first_offense(self):
        # A first-ever hold-back, or a target new to the registry, has no
        # receipt to compare against. Erring toward a page there costs a person
        # for a routinely transient blip.
        for previous in ({}, {"oxlint": None}, {"oxlint": "NO UPDATES"}):
            self.assertEqual(matrix.escalation({"oxlint": "HELD BACK: oxlint"}, previous), ([], [], ["oxlint"]), previous)

    def test_preserved_predecessor_is_never_the_first_of_two(self):
        self.assertEqual(matrix.escalation({"oxlint": "HELD BACK: oxlint"}, {"oxlint": matrix.SKIPPED}), ([], [], ["oxlint"]))

    def test_unreadable_predecessor_receipt_is_never_a_first_offense(self):
        # Counting a receipt that exists but could not be read as "not held
        # back" reset the counter and turned a repeat into a green sweep.
        self.assertEqual(matrix.escalation({"oxlint": "HELD BACK: oxlint"}, {"oxlint": matrix.UNREADABLE}), ([], ["oxlint"], []))

    def test_reason_takes_the_newest_builder_block_and_stays_bounded(self):
        # The plain tail of a preparation log is useless: it ends on the generic
        # completion line, well after the sentence naming the blocker.
        log = "\n".join([
            "       > a stale earlier block",
            "error: Cannot build '/nix/store/...-source-patched.drv'.",
            "       Last 8 log lines:",
            *[f"       > filler {index}" for index in range(20)],
            "       > oxlint: catalog no longer pins @napi-rs/cli at 3.9.1",
            "HELD BACK: oxlint (nix-update, formatter or commit failed)",
        ])
        reason = matrix.held_back_reason(log)
        self.assertIn("catalog no longer pins", reason)
        self.assertNotIn("a stale earlier block", reason)
        self.assertNotIn("HELD BACK", reason)
        self.assertEqual(len(reason.splitlines()), matrix.REASON_MAX_LINES)

    def test_reason_without_builder_output_falls_back_to_the_failure_tail(self):
        # kimchi-docs' updateScript could not execute. Nothing was built, so
        # there is no builder block, and the cause sits above nix-update's
        # traceback and the pipeline's own trailer lines.
        long_command = "Command '['nix', 'develop', " + "x" * 2000 + "]' returned non-zero exit status 126."
        log = "\n".join([
            *[f"copying path '/nix/store/{index}-dep' from 'https://cache.nixos.org'..." for index in range(20)],
            "/nix/store/a-updateScript: 1: /nix/store/b-update-kimchi-docs: Permission denied",
            "$ nix develop --impure --expr 'with import <nixpkgs> {}; ...'",
            "Traceback (most recent call last):",
            *[f'  File "/nix/store/c-nix-update/update.py", line {index}, in run' for index in range(30)],
            "    ^^^^^^^^^^",
            f"subprocess.CalledProcessError: {long_command}",
            "\x1b[0;31m  ✗ nix-update failed (nix-update=1 tee=0)\x1b[0m",
            "HEAD is now at d5073ef2 chore(packages): update oxlint (#1986)",
            "\x1b[0;31m  ✗ HELD BACK: kimchi-docs (nix-update, formatter or commit failed)\x1b[0m",
        ])
        reason = matrix.held_back_reason(log)
        self.assertIn("Permission denied", reason)
        self.assertIn("returned non-zero exit status 126.", reason)
        self.assertIn("nix-update failed", reason)
        for absent in ('File "/nix/store', "Traceback", "HEAD is now at", "HELD BACK", "\x1b["):
            self.assertNotIn(absent, reason)
        self.assertLessEqual(len(reason.splitlines()), matrix.REASON_MAX_LINES)
        self.assertTrue(all(len(line) <= matrix.REASON_MAX_LINE_CHARS for line in reason.splitlines()))
        self.assertIsNone(matrix.held_back_reason("\n  \n"))

    def test_gh_retries_a_transient_failure_before_giving_up(self):
        def completed(code, stdout="", stderr=""):
            return subprocess.CompletedProcess([], code, stdout, stderr)

        with mock.patch.object(matrix.time, "sleep") as sleep, mock.patch.object(matrix.subprocess, "run", side_effect=[completed(1, stderr="502"), completed(0, "ok")]) as run:
            self.assertEqual(matrix.gh("api", "x"), "ok")
        self.assertEqual((run.call_count, sleep.call_count), (2, 1))
        with mock.patch.object(matrix.time, "sleep") as sleep, mock.patch.object(matrix.subprocess, "run", return_value=completed(1, stderr="HTTP 502")) as run:
            with self.assertRaisesRegex(matrix.GhError, "HTTP 502"):
                matrix.gh("api", "x")
        self.assertEqual((run.call_count, sleep.call_count), (matrix.GH_ATTEMPTS, matrix.GH_ATTEMPTS - 1))

    def test_predecessor_is_the_immediate_scheduled_sweep_whatever_its_conclusion(self):
        # Once this gate fires the failing sweep IS the predecessor the next one
        # must compare against. Filtering on conclusion would reset the count
        # every other sweep and never escalate twice in a row. Scheduled-only
        # matters separately: a dispatched sweep may carry a target SUBSET, and
        # its missing receipt would read as "not held back".
        listing = [
            self.run_entry(9, "2026-10-06T12:00:00Z", conclusion=None),
            self.run_entry(3, "2026-10-06T06:00:00Z", conclusion="failure"),
            self.run_entry(2, "2026-10-06T00:00:00Z", conclusion="success"),
        ]
        captured = []
        with mock.patch.object(matrix, "gh", side_effect=self.fake_sweep_gh(listing, captured)):
            self.assertEqual(matrix.previous_sweep("o/r", "9")[0]["id"], 3)
            self.assertEqual(matrix.previous_sweep("o/r", "3")[0]["id"], 2)
            self.assertEqual(matrix.previous_sweep("o/r", "2"), (None, "there is no earlier scheduled sweep"))
        query = next(args[1] for args in captured if "workflows/update.yml/runs" in args[1])
        self.assertIn("event=schedule", query)
        # The running sweep must be listable, so completed-only is never asked.
        self.assertNotIn("status=completed", query)

    @staticmethod
    def run_entry(run_id, created, conclusion=None, event="schedule"):
        return {"id": run_id, "created_at": created, "conclusion": conclusion, "event": event, "html_url": f"u{run_id}"}

    def fake_sweep_gh(self, listing, captured=None, current=None):
        """A `gh` double for previous_sweep: the current run, then the listing."""
        def fake_gh(*args, **_):
            if captured is not None:
                captured.append(args)
            path = args[1]
            if "/actions/runs/" in path:
                run_id = int(path.rsplit("/", 1)[1])
                entry = current or next(run for run in listing if run["id"] == run_id)
                return json.dumps(entry)
            return json.dumps({"workflow_runs": listing})
        return fake_gh

    def test_stale_listing_is_unreadable_never_a_first_sweep(self):
        # Regression: GitHub served a weeks-old snapshot whose head was run
        # 33844722138 (2026-09-04). Taking its first entry made every hold-back
        # a "first sweep". The current run is missing from it, so it is stale.
        stale = [self.run_entry(33844722138, "2026-09-04T18:00:00Z", conclusion="success")]
        current = self.run_entry(9, "2026-10-06T12:00:00Z")
        with mock.patch.object(matrix.time, "sleep") as sleep, mock.patch.object(matrix, "gh", side_effect=self.fake_sweep_gh(stale, current=current)):
            run, note = matrix.previous_sweep("o/r", "9")
        self.assertEqual(run, matrix.UNREADABLE)
        self.assertIn("does not include this run", note)
        self.assertEqual(sleep.call_count, matrix.GH_ATTEMPTS - 1)
        # End to end: the real previous_sweep, behind the same stale listing.
        code, output = self.escalate([self.receipt("oxlint", "HELD BACK")], (
            "import json\n"
            f"m.gh = lambda *a, **k: json.dumps({current!r}) if '/actions/runs/' in a[1] else json.dumps({{'workflow_runs': {stale!r}}})\n"
            "m.time.sleep = lambda *_: None\n"
            "m.previous_sweep = original_previous_sweep\n"
        ))
        self.assertEqual(code, 1, output)
        self.assertIn("::error title=Update hold-back count unknown::", output)
        self.assertIn("does not include this run", output)
        self.assertNotIn("first sweep", output)

    def test_predecessor_older_than_one_interval_plus_slack_is_unreadable(self):
        # The current run is listed, but nothing newer than three weeks is: the
        # listing is still stale, or sweeps were missed. Either way the count
        # is unknown, not reset.
        listing = [self.run_entry(9, "2026-10-06T12:00:00Z"), self.run_entry(33844722138, "2026-09-04T18:00:00Z")]
        with mock.patch.object(matrix.time, "sleep"), mock.patch.object(matrix, "gh", side_effect=self.fake_sweep_gh(listing)):
            run, note = matrix.previous_sweep("o/r", "9")
        self.assertEqual(run, matrix.UNREADABLE)
        self.assertIn("past the 9.0h bound", note)

    def test_dispatched_sweep_is_bounded_by_age_alone(self):
        # A workflow_dispatch run is never in the scheduled listing, so that
        # staleness check cannot apply; the age bound still does.
        current = self.run_entry(9, "2026-10-06T12:00:00Z", event="workflow_dispatch")
        for created, fresh in (("2026-10-06T06:00:00Z", True), ("2026-09-04T18:00:00Z", False)):
            with self.subTest(created=created), mock.patch.object(matrix.time, "sleep"), mock.patch.object(matrix, "gh", side_effect=self.fake_sweep_gh([self.run_entry(3, created)], current=current)):
                run, note = matrix.previous_sweep("o/r", "9")
                if fresh:
                    self.assertEqual((run["id"], note), (3, None))
                else:
                    self.assertEqual(run, matrix.UNREADABLE)
                    self.assertIn("past the 9.0h bound", note)

    def test_schedule_interval_comes_from_the_workflow_cron(self):
        self.assertEqual(matrix.schedule_interval_hours(), 6)
        with tempfile.TemporaryDirectory() as root:
            workflow = Path(root) / "update.yml"
            for cron, hours in (("0 0,6,12,18 * * *", 6), ("0 3 * * *", 24), ("0 1,2,10 * * *", 15)):
                workflow.write_text(f'on:\n  schedule:\n    - cron: "{cron}"\n')
                self.assertEqual(matrix.schedule_interval_hours(workflow), hours, cron)
            for cron in ("0 0 * * 1", "0 * * * *", "15 */4 * * *"):
                workflow.write_text(f'on:\n  schedule:\n    - cron: "{cron}"\n')
                with self.subTest(cron=cron), self.assertRaises(ValueError):
                    matrix.schedule_interval_hours(workflow)

    @staticmethod
    def fake_predecessor_gh(artifacts=None, payload=None, listing_fails=False, download_fails=False):
        """A `gh` double for previous_status: the artifact listing, then the download."""
        def fake_gh(*args, **_):
            if args[0] == "api":
                if listing_fails:
                    raise matrix.GhError("gh api failed after 3 attempts: HTTP 502")
                return json.dumps({"artifacts": artifacts if artifacts is not None else [{"name": "update-receipt-oxlint", "expired": False}]})
            if download_fails:
                raise matrix.GhError("gh run download failed after 3 attempts: HTTP 502")
            arguments = list(args)
            destination = Path(arguments[arguments.index("--dir") + 1])
            destination.mkdir(parents=True, exist_ok=True)
            (destination / "update-receipt.json").write_text(payload)
            return ""
        return fake_gh

    def test_predecessor_status_distinguishes_absent_from_unreadable(self):
        # Walking back to an older sweep that happens to carry a receipt would
        # let a gap turn two NON-consecutive hold-backs into an escalation, so
        # only the immediate predecessor is read. Within it, "no receipt" is a
        # first offense and "a receipt we could not read" is not.
        run = {"id": 4, "html_url": "u4"}
        held = json.dumps(self.receipt("oxlint", "HELD BACK"))
        with tempfile.TemporaryDirectory() as workspace:
            def status(**behavior):
                with mock.patch.object(matrix, "gh", side_effect=self.fake_predecessor_gh(**behavior)):
                    return matrix.previous_status("o/r", run, "oxlint", Path(workspace))

            self.assertEqual(status(payload=held), ("HELD BACK", "u4", None))
            preserved = json.dumps(dict(self.receipt("oxlint", "HELD BACK"), skip="1 non-bot commit(s)"))
            self.assertEqual(status(payload=preserved), (matrix.SKIPPED, "u4", None))
            for artifacts in ([], [{"name": "update-receipt-oxlint", "expired": True}], [{"name": "update-receipt-oxlint-extra", "expired": False}]):
                result = status(artifacts=artifacts)
                self.assertEqual(result[:2], (None, "u4"), artifacts)
                self.assertIn("no unexpired update-receipt-oxlint", result[2])
            # The incident: the receipt exists, but reading it failed. That is
            # never "not held back", and never silent.
            for behavior in ({"listing_fails": True}, {"download_fails": True}, {"artifacts": [{"name": "update-receipt-oxlint"}]}):
                result = status(**behavior)
                self.assertEqual(result[:2], (matrix.UNREADABLE, "u4"), behavior)
                self.assertTrue(result[2], behavior)
            self.assertIn("HTTP 502", status(download_fails=True)[2])
            # Malformed JSON, valid JSON of the wrong shape, a receipt with no
            # status, and one belonging to a DIFFERENT target are unreadable
            # too -- never an AttributeError that would abort the cleanup job.
            for payload in ("{not json", "[]", "null", json.dumps({"name": "oxlint"}), json.dumps(self.receipt("beads", "HELD BACK"))):
                self.assertEqual(status(payload=payload)[:2], (matrix.UNREADABLE, "u4"), payload)
            self.assertEqual(matrix.previous_status("o/r", None, "oxlint", Path(workspace))[:2], (None, None))

    def test_download_retry_starts_from_a_clean_directory(self):
        # `gh run download` refuses to overwrite a file an earlier failed
        # attempt already extracted, so a retry into the same --dir would fail
        # on "file exists" forever instead of recovering.
        run = {"id": 4, "html_url": "u4"}
        held = json.dumps(self.receipt("oxlint", "HELD BACK"))
        listing = json.dumps({"artifacts": [{"name": "update-receipt-oxlint", "expired": False}]})
        attempts = []

        def fake_run(argv, **_):
            if argv[1] == "api":
                return subprocess.CompletedProcess(argv, 0, listing, "")
            destination = Path(argv[argv.index("--dir") + 1])
            target = destination / "update-receipt.json"
            attempts.append(target.exists())
            if target.exists():
                return subprocess.CompletedProcess(argv, 1, "", f"error extracting: {target}: file exists")
            destination.mkdir(parents=True, exist_ok=True)
            target.write_text(held if len(attempts) > 1 else held[:5])
            return subprocess.CompletedProcess(argv, 0 if len(attempts) > 1 else 1, "", "" if len(attempts) > 1 else "HTTP 502")

        with tempfile.TemporaryDirectory() as workspace, mock.patch.object(matrix.time, "sleep"), mock.patch.object(matrix.subprocess, "run", side_effect=fake_run):
            self.assertEqual(matrix.previous_status("o/r", run, "oxlint", Path(workspace)), ("HELD BACK", "u4", None))
        self.assertEqual(attempts, [False, False])
    def escalate(self, receipts, overrides, flat=False):
        """Run the escalate command against fixture receipts; return (rc, stdout).

        `overrides` is Python source run against the loaded module `m` before
        main(), replacing whatever would otherwise reach the GitHub API. `flat`
        lays a lone receipt out the way download-artifact v5+ extracts a
        pattern with exactly one match: straight into `receipts/`.
        """
        with tempfile.TemporaryDirectory() as root:
            source, temp = Path(root) / "source", Path(root) / "temp"
            (source / "receipts").mkdir(parents=True)
            temp.mkdir()
            for receipt in receipts:
                folder = source / "receipts" / ("" if flat else f"update-receipt-{receipt['name']}")
                folder.mkdir(exist_ok=True)
                (folder / "update-receipt.json").write_text(json.dumps(receipt))
            environment = dict(os.environ, GITHUB_REPOSITORY="o/r", GITHUB_RUN_ID="9", RUNNER_TEMP=str(temp))
            script = (
                "import importlib.util, json, sys\n"
                f"sys.path.insert(0, {str(SCRIPTS)!r})\n"
                f"spec = importlib.util.spec_from_file_location('m', {str(SCRIPTS / 'update-matrix.py')!r})\n"
                "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
                "original_previous_sweep = m.previous_sweep\n"
                "m.previous_sweep = lambda *a, **k: ({'id': 8, 'html_url': 'prev-url'}, None)\n"
                "m.preparation_reason = lambda *a, **k: ('the guard said bump napi.version', None)\n"
                f"{overrides}\n"
                "sys.argv = ['update-matrix.py', 'escalate']\n"
                "m.main()\n"
            )
            result = subprocess.run([os.sys.executable, "-c", script], cwd=source, env=environment, capture_output=True, text=True)
            return result.returncode, result.stdout + result.stderr

    def predecessor(self, status, note=None):
        return f"m.previous_status = lambda *a, **k: ({status!r}, 'prev-url', {note!r})"

    def test_escalate_fails_the_sweep_only_on_a_repeat(self):
        held = self.receipt("oxlint", "HELD BACK", "HELD BACK: oxlint (nix-update, formatter or commit failed)")
        code, output = self.escalate([held], self.predecessor("HELD BACK"))
        self.assertEqual(code, 1, output)
        self.assertIn("::error title=Update target held back twice::", output)
        self.assertIn("prev-url", output)
        # An older update PR may still be open on a held-back target, so the
        # annotation must not claim none exists.
        self.assertNotIn("No PR exists", output)
        self.assertIn("EARLIER proposal", output)
        # The operator judges; the annotation carries what they need to judge on.
        self.assertIn("bump napi.version", output)

        code, output = self.escalate([held], self.predecessor("UPDATED"))
        self.assertEqual(code, 0, output)
        self.assertIn("::warning title=Update target held back::", output)
        self.assertNotIn("::error", output)

    def test_escalate_says_why_a_hold_back_counts_as_first(self):
        held = self.receipt("oxlint", "HELD BACK")
        code, output = self.escalate([held], self.predecessor(None, "that sweep has no unexpired update-receipt-oxlint artifact"))
        self.assertEqual(code, 0, output)
        self.assertIn("::warning title=Update target held back::", output)
        self.assertIn("no unexpired update-receipt-oxlint artifact", output)

    def test_escalate_fails_loud_when_the_predecessor_receipt_is_unreadable(self):
        # Replays sweep 36103378626: the predecessor held the target and its
        # receipt was valid, but the download failed. The real previous_status
        # runs here; only `gh` is faked.
        held = self.receipt("kimchi-docs", "HELD BACK", "HELD BACK: kimchi-docs (nix-update, formatter or commit failed)")
        overrides = "\n".join([
            "def fake_gh(*args, **_):",
            "    if args[0] == 'api':",
            "        return json.dumps({'artifacts': [{'name': 'update-receipt-kimchi-docs', 'expired': False}]})",
            "    raise m.GhError('gh run download failed after 3 attempts: HTTP 502\\n(stderr line 2)')",
            "m.gh = fake_gh",
        ])
        code, output = self.escalate([held], overrides)
        self.assertEqual(code, 1, output)
        self.assertIn("::error title=Update hold-back count unknown::", output)
        self.assertNotIn("::warning", output)
        self.assertIn("could not be read", output)
        self.assertIn("HTTP 502", output)
        self.assertIn("unknown predecessor: kimchi-docs", output)
        # gh's multi-line stderr stays inside the one annotation.
        self.assertIn("HTTP 502%0A(stderr line 2)", output)
        self.assertIn("bump napi.version", output)

    def test_every_escalation_names_a_reason(self):
        held = self.receipt("oxlint", "HELD BACK")
        missing = "m.preparation_reason = lambda *a, **k: (None, 'could not read update-report-oxlint: HTTP 404')"
        code, output = self.escalate([held], self.predecessor("HELD BACK") + "\n" + missing)
        self.assertEqual(code, 1, output)
        self.assertIn("Preparation log excerpt unavailable: could not read update-report-oxlint: HTTP 404.", output)
        self.assertIn("Full log: gh run download 9 --repo o/r --name update-report-oxlint", output)

    def test_escalate_reads_a_lone_receipt_extracted_without_a_directory(self):
        held = self.receipt("oxlint", "HELD BACK", "HELD BACK: oxlint (nix-update, formatter or commit failed)")
        code, output = self.escalate([held], self.predecessor("HELD BACK"), flat=True)
        self.assertEqual(code, 1, output)
        self.assertIn("::error title=Update target held back twice::", output)

    def test_escalate_never_counts_a_hold_back_on_a_preserved_branch(self):
        held = dict(self.receipt("oxlint", "HELD BACK"), skip="preparation held back and 1 non-bot commit(s) are on the remote branch.")
        code, output = self.escalate([held], self.predecessor("HELD BACK"))
        self.assertEqual(code, 0, output)
        self.assertIn("::notice title=Update target held back on a preserved branch::update/oxlint", output)
        self.assertNotIn("::error", output)
        self.assertNotIn("::warning", output)

    def test_escalate_is_silent_and_cheap_when_nothing_is_held_back(self):
        code, output = self.escalate([self.receipt("beads", "UPDATED")], self.predecessor("HELD BACK"))
        self.assertEqual(code, 0, output)
        self.assertNotIn("::error", output)
        self.assertNotIn("::warning", output)

    def test_escalation_runs_after_stale_pr_cleanup_and_may_read_prior_runs(self):
        workflow = WORKFLOW.read_text()
        cleanup = workflow.split("\n  cleanup:\n", 1)[1].split("\n  annotations:", 1)[0]
        # Reading a PREVIOUS sweep's receipt artifact needs actions: read, and a
        # job-level block replaces the workflow default rather than extending it.
        self.assertIn("actions: read", cleanup)
        self.assertIn("contents: read", cleanup)
        # Ordering is load-bearing: failing BEFORE the cleanup script would skip
        # stale-PR cleanup repo-wide.
        self.assertLess(cleanup.index("update-cleanup.sh"), cleanup.index('update-matrix.py" escalate'))
        # A failed cleanup step must not hide a repeated hold-back.
        escalate = cleanup[cleanup.index("- name: Escalate repeated hold-backs"):cleanup.index('update-matrix.py" escalate')]
        self.assertIn("if: ${{ !cancelled() }}", escalate)


if __name__ == "__main__":
    unittest.main()

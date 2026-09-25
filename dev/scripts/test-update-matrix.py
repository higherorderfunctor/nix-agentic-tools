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
    first_view = Path(os.environ['RUNNER_TEMP'], 'first-pr-view')
    if os.environ.get('PR_VIEW_FAIL_ALWAYS') or (os.environ.get('PR_VIEW_FAIL_ONCE') and not first_view.exists()):
        first_view.touch()
        sys.exit(1)
    previously_viewed = first_view.exists()
    first_view.touch()
    Path(os.environ['RUNNER_TEMP'], 'viewed').touch()
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
    if os.environ.get('PR_VIEW_CHANGED_AFTER_FIRST') and previously_viewed:
        view['headRefOid'] = os.environ['PR_VIEW_CHANGED_AFTER_FIRST']
    disabled = Path(os.environ['RUNNER_TEMP'], 'auto-merge-disabled').exists()
    enabled_by = os.environ.get('AUTO_MERGE_ENABLED_BY', 'app/nix-agentic-tools-bot')
    if os.environ.get('PR_AUTO_MERGE_RAW'):
        view['autoMergeRequest'] = json.loads(os.environ['PR_AUTO_MERGE_RAW'])
    else:
        view['autoMergeRequest'] = {'enabledAt': 'fixture', 'enabledBy': {'login': enabled_by}} if os.environ.get('AUTO_MERGE_ENABLED') and not disabled else None
    print(json.dumps(view))
if sys.argv[1:3] == ['pr', 'close']: closed_path(sys.argv[3]).touch()
if sys.argv[1] == 'api':
    if any(arg.endswith('/activity') for arg in sys.argv):
        ref = next(arg.removeprefix('ref=') for arg in sys.argv if arg.startswith('ref='))
        first_read = Path(os.environ['RUNNER_TEMP'], 'activity-first-read')
        if os.environ.get('ACTIVITY_EMPTY_ALWAYS') or (os.environ.get('ACTIVITY_EMPTY_ONCE') and not first_read.exists()):
            first_read.touch()
            print('[]')
            sys.exit(0)
        head = subprocess.check_output(['git', 'rev-parse', 'refs/remotes/origin/' + ref.removeprefix('refs/heads/')], text=True).strip()
        actor = os.environ.get('PUSH_ACTOR', 'nix-agentic-tools-bot[bot]')
        if Path(os.environ['RUNNER_TEMP'], 'viewed').exists():
            actor = os.environ.get('ARM_PUSH_ACTOR', actor)
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
    else: print(os.environ['COMMIT_PAGES'])
if sys.argv[1:3] == ['pr', 'merge']:
    if '--disable-auto' in sys.argv:
        if os.environ.get('FAIL_DISABLE'): sys.exit(1)
        Path(os.environ['RUNNER_TEMP'], 'auto-merge-disabled').touch()
    elif os.environ.get('FAIL_ARM'): sys.exit(1)
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
        return subprocess.run(["bash", str(SCRIPTS / "update-publish.sh")], cwd=self.repo, env=dict(self.env, **env), text=True, capture_output=True)

    def test_completed_branch_is_published_and_pr_created(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), self.git("rev-parse", "update/demo"))
        self.assertIn('["pr", "create"', (self.root / "calls").read_text())
        self.assertEqual((self.root / "touched-branches").read_text(), "update/demo\n")

    def test_new_pr_waits_for_matching_app_push_activity_before_arming(self):
        result = self.publish(ACTIVITY_EMPTY_ONCE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertEqual(calls.count('"ref=refs/heads/update/demo"'), 2)
        self.assertIn('["pr", "merge"', calls)

    def test_new_pr_does_not_arm_when_app_push_activity_stays_unavailable(self):
        result = self.publish(ACTIVITY_EMPTY_ALWAYS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("App push activity unavailable after 5 reads", result.stdout)
        calls = (self.root / "calls").read_text()
        self.assertEqual(calls.count('"ref=refs/heads/update/demo"'), 5)
        self.assertNotIn('["pr", "merge"', calls)

    def test_new_pr_waits_for_first_pr_view(self):
        result = self.publish(PR_VIEW_FAIL_ONCE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertEqual(calls.count('["pr", "view"'), 2)
        self.assertIn('["pr", "merge"', calls)

    def test_new_pr_does_not_arm_when_pr_view_stays_unavailable(self):
        result = self.publish(PR_VIEW_FAIL_ALWAYS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PR view unavailable after 5 reads", result.stdout)
        self.assertNotIn('["pr", "merge"', (self.root / "calls").read_text())

    def test_new_pr_rejects_changed_head_after_wait(self):
        result = self.publish(ACTIVITY_EMPTY_ONCE="1", PR_VIEW_CHANGED_AFTER_FIRST=self.base)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PR head changed", result.stdout)
        self.assertNotIn('["pr", "merge"', (self.root / "calls").read_text())

    def test_new_pr_rejects_human_push_after_wait(self):
        result = self.publish(ACTIVITY_EMPTY_ONCE="1", ARM_PUSH_ACTOR="human")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("App push activity does not verify", result.stdout)
        self.assertNotIn('["pr", "merge"', (self.root / "calls").read_text())

    def test_human_auto_merge_disable_during_activity_wait_is_retained(self):
        disabled = [{"__typename": "AutoMergeDisabledEvent", "actor": {"login": "human"}, "disabler": {"login": "human"}, "reason": None, "reasonCode": None}]
        result = self.publish(ACTIVITY_EMPTY_ONCE="1", AUTO_MERGE_EVENTS=json.dumps(disabled))
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
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), human_tip)
        self.assertIn("not a verified App push", result.stdout)
        self.assertEqual((self.root / "touched-branches").read_text(), "update/demo\n")
        self.assertNotIn('["pr", "merge"', (self.root / "calls").read_text())
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

    def test_publication_rejects_a_remote_change_after_checkout(self):
        self.git("checkout", "-b", "human", "update/demo")
        self.commit("concurrent work")
        human_tip = self.git("rev-parse", "HEAD")
        self.git("push", "origin", "human")
        self.git("checkout", "main")
        self.git("--git-dir", str(self.remote), "update-ref", "refs/heads/update/demo", human_tip)
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.git("ls-remote", "origin", "refs/heads/update/demo").startswith(human_tip))
        self.assertNotIn('["pr", "create"', (self.root / "calls").read_text())

    def test_held_back_target_preserves_pr_without_pushing(self):
        (self.root / "prepared.json").write_text(json.dumps({"status": "HELD BACK"}))
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "touched-branches").read_text(), "update/demo\n")
        self.assertNotIn('["pr",', (self.root / "calls").read_text())

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
        (self.root / "calls").unlink()
        self.assertNotEqual(self.publish(**env, FAIL_ARM="1").returncode, 0)
        merge_calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines() if json.loads(line)[:2] == ["pr", "merge"]]
        self.assertEqual(merge_calls, [expected, ["pr", "merge", "1", "--disable-auto"]])

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

    def test_late_head_race_fails_without_changing_auto_merge(self):
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
                self.git("--git-dir", str(self.remote), "update-ref", "refs/heads/update/demo", bot_tip)
                (self.root / "calls").unlink(missing_ok=True)
                if fresh_update:
                    self.git("checkout", "update/demo")
                    self.commit("newer upstream version")
                    self.git("checkout", "main")
                result = self.publish(PR_LIST=json.dumps([self.own_pr()]), ARM_RACE_TIP=tip, AUTO_MERGE_ENABLED="1")
                self.assertNotEqual(result.returncode, 0)
                calls = (self.root / "calls").read_text()
                self.assertNotIn('["pr", "merge"', calls)
                if fresh_update:
                    self.assertIn('["pr", "edit", "1"', calls)
                self.assertTrue(self.git("ls-remote", "origin", "refs/heads/update/demo").startswith(tip))

    def test_pr_with_changed_base_is_not_armed(self):
        self.git("push", "origin", "update/demo")
        tip = self.git("rev-parse", "update/demo")
        view = dict(self.own_pr(), baseRefName="another-base", headRefOid=tip)
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), PR_VIEW=json.dumps(view), AUTO_MERGE_ENABLED="1")
        self.assertNotEqual(result.returncode, 0)
        calls = (self.root / "calls").read_text()
        self.assertNotIn('["pr", "merge"', calls)
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
        result = self.publish(
            CLOSED_PR_LIST=json.dumps([closed]),
            CLOSE_EVENTS=json.dumps(human_close),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertNotIn('["pr", "create"', calls)
        self.assertNotIn('["pr", "merge"', calls)
        self.assertNotIn("Pushing update/demo", result.stdout)
        self.assertEqual((self.root / "touched-branches").read_text(), "update/demo\n")

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
        result = self.publish(
            CLOSED_PR_LIST=json.dumps([closed]),
            CLOSE_EVENTS=json.dumps(human_close),
            PR_VIEW_REMOTE_HEAD="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertIn('["pr", "create"', calls)
        self.assertIn('["pr", "merge"', calls)

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

    def test_arming_rechecks_push_actor_even_when_head_is_unchanged(self):
        self.git("push", "origin", "update/demo")
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), ARM_PUSH_ACTOR="human", AUTO_MERGE_ENABLED="1")
        self.assertNotEqual(result.returncode, 0)
        calls = (self.root / "calls").read_text()
        self.assertNotIn('["pr", "merge"', calls)

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

    def test_human_republishes_exact_prepared_sha_without_changing_auto_merge(self):
        self.git("push", "origin", "update/demo")
        tip = self.git("rev-parse", "update/demo")
        result = self.publish(PR_LIST=json.dumps([self.own_pr()]), PUSH_ACTOR="human", AUTO_MERGE_ENABLED="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not a verified App push", result.stdout)
        self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), tip)
        self.assertNotIn('["pr", "merge"', (self.root / "calls").read_text())
        self.assertFalse((self.root / "auto-merge-disabled").exists())

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
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Refusing to force-push", result.stdout)
        self.assertEqual(self.git("rev-parse", "refs/remotes/origin/update/demo"), human_tip)
        self.assertNotIn('["pr", "merge"', (self.root / "calls").read_text())

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
        (self.repo / "packages" / "semble").mkdir(parents=True)
        self.bin.mkdir()
        (self.repo / "flake.lock").write_text("{}\n")
        (self.repo / "devenv.lock").write_text("{}\n")
        (self.repo / "devenv.yaml").write_text("inputs: {}\n")
        (self.repo / "packages" / "semble" / "extracted.json").write_text("{}\n")
        (self.repo / "packages" / "semble" / "upstream-templates.json").write_text("{}\n")
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

    def write_recipe(self, marker):
        marker_lines = ""
        if marker:
            marker_lines = '  # upstream: readPackageJsonVersion @ package.json\n  upstream = "1.0.0";\n'
        (self.repo / "packages" / "demo" / "package.nix").write_text(
            '{fetchFromGitHub}:\nfetchFromGitHub {\n'
            f'{marker_lines}  rev = "{"0" * 40}";\n'
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
if args[:1] == ['eval']:
    joined = ' '.join(args)
    if 'builtins.currentSystem' in joined: print('x86_64-linux')
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
    print(values.get(mode, ''), end='')
    raise SystemExit(9 if mode == 'failed' else 0)
if args[:1] == ['run']:
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
if args[:1] == ['build']: raise SystemExit(23 if mode == 'package-red' else 0)
raise SystemExit(f'unhandled nix fixture arguments: {args}')
""",
        )

    def run_package(self, mode, marker=False):
        if marker:
            self.write_recipe(True)
            self.git("add", "packages/demo/package.nix")
            self.git("commit", "-m", "marker recipe")
            self.base = self.git("rev-parse", "HEAD")
        return subprocess.run(
            ["bash", str(SCRIPTS / "update-pkg.sh"), "demo", "--version", "skip", "https://github.com/example/demo.git"],
            cwd=self.repo,
            env=dict(self.env, NIX_MODE=mode),
            capture_output=True,
            text=True,
        )

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
        self.assertIn("build verification failed, PR opens red", result.stdout)

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
        self.assertIn("build verification failed, PR opens red", result.stdout)


class HoldBackEscalationTest(unittest.TestCase):
    """A held-back target leaves the sweep green; only a REPEAT may fail it."""

    def receipt(self, name, status, detail=None):
        return {"base": "b", "detail": detail or f"{status}: {name}", "name": name, "status": status, "touched": []}

    def test_repeat_escalates_while_a_first_offense_only_warns(self):
        held = {"oxlint": "HELD BACK: oxlint (nix-update...)", "beads": "HELD BACK: beads"}
        repeated, fresh = matrix.escalation(held, {"beads": "UPDATED", "oxlint": "HELD BACK"})
        self.assertEqual(repeated, ["oxlint"])
        self.assertEqual(fresh, ["beads"])

    def test_unreadable_previous_sweep_never_escalates(self):
        # A first-ever hold-back and one whose predecessor aged out must not be
        # indistinguishable from a repeat. Erring toward silence here only
        # restores today's behavior; erring the other way pages someone for a
        # transient upstream blip.
        for previous in ({}, {"oxlint": None}, {"oxlint": "NO UPDATES"}):
            repeated, fresh = matrix.escalation({"oxlint": "HELD BACK: oxlint"}, previous)
            self.assertEqual((repeated, fresh), ([], ["oxlint"]), previous)

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

    def test_reason_is_absent_rather_than_wrong_without_builder_output(self):
        self.assertIsNone(matrix.held_back_reason("HELD BACK: oxlint\nnothing quoted here\n"))

    def test_predecessor_is_the_immediate_scheduled_sweep_whatever_its_conclusion(self):
        # Once this gate fires the failing sweep IS the predecessor the next one
        # must compare against. Filtering on conclusion would reset the count
        # every other sweep and never escalate twice in a row. Scheduled-only
        # matters separately: a dispatched sweep may carry a target SUBSET, and
        # its missing receipt would read as "not held back".
        runs = {"workflow_runs": [
            {"id": 3, "conclusion": "failure", "html_url": "u3"},
            {"id": 2, "conclusion": "success", "html_url": "u2"},
        ]}
        captured = []

        def fake_gh(*args, required=True):
            captured.append(args)
            return json.dumps(runs)

        with mock.patch.object(matrix, "gh", side_effect=fake_gh):
            self.assertEqual(matrix.previous_sweep("o/r", "9")["id"], 3)
            self.assertEqual(matrix.previous_sweep("o/r", "3")["id"], 2)
        self.assertIn("event=schedule", captured[0][1])

    def test_an_unreadable_immediate_predecessor_yields_no_status(self):
        # Walking back to an older sweep that happens to carry a receipt would
        # let a gap turn two NON-consecutive hold-backs into an escalation,
        # which is what the two-sweep threshold exists to prevent.
        run = {"id": 4, "html_url": "u4"}
        with tempfile.TemporaryDirectory() as workspace:
            def serve(payload):
                def fake_gh(*args, required=True):
                    arguments = list(args)
                    destination = Path(arguments[arguments.index("--dir") + 1])
                    destination.mkdir(parents=True, exist_ok=True)
                    (destination / "update-receipt.json").write_text(payload)
                    return ""
                return fake_gh

            with mock.patch.object(matrix, "gh", side_effect=serve(json.dumps(self.receipt("oxlint", "HELD BACK")))):
                self.assertEqual(matrix.previous_status("o/r", run, "oxlint", Path(workspace)), ("HELD BACK", "u4"))
            # Download failed, malformed JSON, valid JSON of the wrong shape, and
            # a receipt belonging to a DIFFERENT target are all "unreadable" --
            # never "not held back", and never an AttributeError that would
            # abort the cleanup job.
            with mock.patch.object(matrix, "gh", return_value=None):
                self.assertEqual(matrix.previous_status("o/r", run, "oxlint", Path(workspace)), (None, "u4"))
            for payload in ("{not json", "[]", "null", json.dumps(self.receipt("beads", "HELD BACK"))):
                with mock.patch.object(matrix, "gh", side_effect=serve(payload)):
                    self.assertEqual(matrix.previous_status("o/r", run, "oxlint", Path(workspace)), (None, "u4"), payload)
            self.assertEqual(matrix.previous_status("o/r", None, "oxlint", Path(workspace)), (None, None))

    def escalate(self, receipts, previous_status_value):
        """Run the escalate command against fixture receipts; return (rc, stdout)."""
        with tempfile.TemporaryDirectory() as root:
            source, temp = Path(root) / "source", Path(root) / "temp"
            (source / "receipts").mkdir(parents=True)
            temp.mkdir()
            for receipt in receipts:
                folder = source / "receipts" / f"update-receipt-{receipt['name']}"
                folder.mkdir()
                (folder / "update-receipt.json").write_text(json.dumps(receipt))
            environment = dict(os.environ, GITHUB_REPOSITORY="o/r", GITHUB_RUN_ID="9", RUNNER_TEMP=str(temp))
            script = (
                "import importlib.util, json, sys\n"
                f"spec = importlib.util.spec_from_file_location('m', {str(SCRIPTS / 'update-matrix.py')!r})\n"
                "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
                f"m.previous_sweep = lambda *a, **k: {{'id': 8, 'html_url': 'prev-url'}}\n"
                f"m.previous_status = lambda *a, **k: ({previous_status_value!r}, 'prev-url')\n"
                "m.preparation_reason = lambda *a, **k: 'the guard said bump napi.version'\n"
                "sys.argv = ['update-matrix.py', 'escalate']\n"
                "m.main()\n"
            )
            result = subprocess.run([os.sys.executable, "-c", script], cwd=source, env=environment, capture_output=True, text=True)
            return result.returncode, result.stdout + result.stderr

    def test_escalate_fails_the_sweep_only_on_a_repeat(self):
        held = self.receipt("oxlint", "HELD BACK", "HELD BACK: oxlint (nix-update, formatter or commit failed)")
        code, output = self.escalate([held], "HELD BACK")
        self.assertEqual(code, 1, output)
        self.assertIn("::error title=Update target held back twice::", output)
        self.assertIn("prev-url", output)
        # An older update PR may still be open on a held-back target, so the
        # annotation must not claim none exists.
        self.assertNotIn("No PR exists", output)
        self.assertIn("EARLIER proposal", output)
        # The operator judges; the annotation carries what they need to judge on.
        self.assertIn("bump napi.version", output)

        code, output = self.escalate([held], "UPDATED")
        self.assertEqual(code, 0, output)
        self.assertIn("::warning title=Update target held back::", output)
        self.assertNotIn("::error", output)

    def test_escalate_is_silent_and_cheap_when_nothing_is_held_back(self):
        code, output = self.escalate([self.receipt("beads", "UPDATED")], "HELD BACK")
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


if __name__ == "__main__":
    unittest.main()

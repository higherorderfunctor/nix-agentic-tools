#!/usr/bin/env python3
"""Lifecycle integration fixtures; no CodeQL binary or Nix build is needed."""

import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("lifecycle", sys.argv[1])
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)
launcher = Path(sys.argv[2])
del sys.argv[1:3]


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repo"
        self.root.mkdir()
        self.environment = patch.dict(os.environ, {
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid", "GIT_AUTHOR_NAME": "fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid", "GIT_COMMITTER_NAME": "fixture",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.git("init", "-q", "-b", "main")
        (self.root / "a.nix").write_text("{ old = true; }\n")
        self.commit()
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.bin = Path(self.temporary.name) / "tools/bin"
        self.bin.mkdir(parents=True)
        self.calls = Path(self.temporary.name) / "calls"
        # The creator records the snapshot contents, including deleted files.
        creator = self.bin / "create"
        creator.write_text(f'''#!{sys.executable}
import json, pathlib, sys
state = pathlib.Path(sys.argv[1])
source = pathlib.Path(sys.argv[2]) if len(sys.argv) == 3 else None
(state / "db").mkdir()
(state / "db/files").write_text(json.dumps({{str(p.relative_to(source)): p.read_text() for p in source.rglob("*.nix")}}) if source else "pinned")
with open({str(self.calls)!r}, "a") as stream: stream.write("create\\n")
''')
        creator.chmod(0o755)
        engine = self.bin / "codeql"
        engine.write_text(f'''#!{sys.executable}
import json, pathlib, sys
with open({str(self.calls)!r}, "a") as stream: stream.write(" ".join(sys.argv[1:]) + "\\n")
args = sys.argv[1:]
if args[:2] == ["database", "create"]:
    db = pathlib.Path(args[2]); db.mkdir(exist_ok=True)
    if "--overlay-base" in args: (db / "base").write_text("unchanged")
    for arg in args:
        if arg.startswith("--overlay-changes="):
            (db / "changes").write_text(pathlib.Path(arg.split("=", 1)[1]).read_text())
            (db / "base").write_text("overlay")
''')
        engine.chmod(0o755)
        self.manifest = self.bin.parent / "codeql-extractor.yml"
        self.manifest.write_text("name: nix\n")
        self.resolved = {"engine": str(self.bin.parent), "create": str(self.bin.parent),
                         "warm": str(self.bin.parent), "manifest": str(self.manifest), "pack": "standing/queries"}
        self.db_spec = {"codeql": "fixture", "create": "create", "source": "git",
                        "extensions": [".nix"], "language": "nix"}
        self.state = self.root / ".devenv/state/codeql/nix"
        self.registered_roots = []
        self.real_run = subprocess.run
        self.tool_patch = patch.object(lifecycle, "tools", return_value=("fixture", self.resolved))
        self.tool_patch.start()
        self.addCleanup(self.tool_patch.stop)
        self.run_patch = patch.object(lifecycle.subprocess, "run", side_effect=self.commands)
        self.run_patch.start()
        self.addCleanup(self.run_patch.stop)

    def commands(self, args, **kwargs):
        if args[:2] == ["nix", "build"]:
            return subprocess.CompletedProcess(args, 0)
        if args[:2] == ["nix-store", "--realize"]:
            self.assertEqual(args[3], "--add-root")
            self.assertEqual(args[5:], ["--indirect"])
            root = Path(args[4])
            root.symlink_to(args[2])
            self.registered_roots.append(root)
            return subprocess.CompletedProcess(args, 0)
        return self.real_run(args, **kwargs)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True).strip()

    def commit(self):
        self.git("add", "*.nix")
        self.git("commit", "-qm", "fixture")

    def execute(self, action="up", existing=False):
        lifecycle.lifecycle(self.root, "nix", self.db_spec, action, existing)

    def test_archive_stamp_swap_and_failure(self):
        self.execute()
        original = (self.state / "db").resolve()
        self.assertTrue((self.state / "db").is_symlink())
        self.assertEqual(len((self.state / "stamp").read_text().splitlines()), 1)
        calls = self.calls.read_text()
        self.execute()
        self.assertEqual(self.calls.read_text(), calls)
        (self.root / "a.nix").write_text("dirty ignored\n")
        self.execute()
        self.assertEqual((self.state / "db").resolve(), original)
        self.assertIn("old", json.loads((original / "files").read_text())["a.nix"])
        self.commit()
        self.execute()
        current = (self.state / "db").resolve()
        self.assertNotEqual(current, original)
        self.assertFalse(original.exists())
        self.assertEqual(json.loads((current / "files").read_text())["a.nix"], "dirty ignored\n")
        self.assertEqual((self.state / "engine").resolve(), self.bin.parent)
        stamp = (self.state / "stamp").read_text()
        with patch.object(lifecycle, "create", side_effect=RuntimeError("failed extraction")):
            with self.assertRaisesRegex(RuntimeError, "failed extraction"):
                self.execute("refresh")
        self.assertEqual((self.state / "db").resolve(), current)
        self.assertEqual((self.state / "stamp").read_text(), stamp)
        self.assertEqual(len(list(self.state.glob("generation.*"))), 1)
        self.execute("down")
        self.assertFalse((self.state / "db").exists())
        self.execute(existing=True)
        self.assertFalse((self.state / "db").exists())

    def test_engine_roots_survive_until_generation_retirement(self):
        self.db_spec["source"] = "pinned"
        actual_create = lifecycle.create
        def rooted_create(root, spec, resolved, generation, commit=None):
            self.assertIn(generation / "engine", self.registered_roots)
            self.assertEqual((generation / "engine").resolve(), self.bin.parent)
            actual_create(root, spec, resolved, generation, commit)
        with patch.object(lifecycle, "create", side_effect=rooted_create):
            self.execute()
        original = (self.state / "db").resolve()
        original_root = original.parent / "engine"
        self.assertIn(original_root, self.registered_roots)
        self.assertEqual((self.state / "engine").resolve(), original_root.resolve())
        def fail_create(*args):
            self.assertTrue(original_root.is_symlink())
            raise RuntimeError("failed extraction")
        with patch.object(lifecycle, "create", side_effect=fail_create):
            with self.assertRaisesRegex(RuntimeError, "failed extraction"):
                self.execute("refresh")
        self.assertTrue(original_root.is_symlink())
        self.assertEqual((self.state / "db").resolve(), original)
        self.assertFalse(self.registered_roots[-1].is_symlink())
        actual_link = lifecycle.link
        def publish(target, destination):
            if destination == self.state / "db":
                self.assertTrue(original_root.is_symlink())
                self.assertTrue(self.registered_roots[-1].is_symlink())
                self.assertEqual((self.state / "engine").resolve(), original_root.resolve())
            actual_link(target, destination)
        with patch.object(lifecycle, "link", side_effect=publish):
            self.execute("refresh")
        current_root = (self.state / "db").resolve().parent / "engine"
        self.assertFalse(original_root.is_symlink())
        self.assertTrue(current_root.is_symlink())
        self.assertEqual((self.state / "engine").resolve(), current_root.resolve())
        worktree = self.root.parent / "worktree"
        self.git("worktree", "add", "-q", "-b", "fixture", str(worktree))
        lifecycle.lifecycle(worktree, "nix", self.db_spec, "up")
        other_root = (worktree / ".devenv/state/codeql/nix/db").resolve().parent / "engine"
        self.execute("down")
        self.assertFalse(current_root.is_symlink())
        self.assertTrue(other_root.is_symlink())
        self.assertFalse(any(self.state.glob("generation.*")))

    def test_launcher_hook_failures_are_advisory_but_tasks_fail(self):
        # Exercise the realized production wrapper, before Python's own handler.
        for action in ("hook", "up"):
            result = self.real_run([str(launcher), action], cwd=self.root, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, action == "hook")
            self.assertIn("can't open file", result.stderr)
        outside = self.root.parent / "outside"
        outside.mkdir()
        for action in ("hook", "up"):
            result = self.real_run([str(launcher), action], cwd=outside, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, action == "hook")
            self.assertIn("not a git repository", result.stderr)
        (self.root / "dev").mkdir()
        (self.root / "dev/scripts").mkdir()
        (self.root / "dev/scripts/codeql-lifecycle.py").write_text("import sys; sys.exit(23)\n")
        for action in ("hook", "refresh"):
            result = self.real_run([str(launcher), action], cwd=self.root, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0 if action == "hook" else 23)

    def test_base_shared_by_worktrees_and_tool_invalidation(self):
        self.execute()
        common = self.root / ".git/codeql/nix"
        self.assertEqual(self.calls.read_text().count("--no-cache-at-frontier"), 1)
        worktree = self.root.parent / "worktree"
        self.git("worktree", "add", "-q", "-b", "fixture", str(worktree))
        lifecycle.lifecycle(worktree, "nix", self.db_spec, "up")
        self.assertEqual(self.calls.read_text().count("--no-cache-at-frontier"), 1)
        base = next(path for path in common.iterdir() if path.is_dir()) / "db/files"
        copied = worktree / ".devenv/state/codeql/nix/db/files"
        self.assertNotEqual(base.stat().st_ino, copied.stat().st_ino)
        copied.write_text("cache mutation")
        self.assertNotEqual(base.read_text(), "cache mutation")
        self.resolved["pack"] = "standing/updated"
        self.execute()
        self.assertEqual(self.calls.read_text().count("--no-cache-at-frontier"), 2)

    def test_overlay_whole_diff_deletion_untracked_and_no_chaining(self):
        self.manifest.write_text("name: nix\noverlay_support_version: 20250626\n")
        (self.root / "a.nix").unlink()
        (self.root / "untracked.nix").write_text("{}\n")
        (self.root / "ignored.txt").write_text("ignored\n")
        self.execute()
        db = (self.state / "db").resolve()
        self.assertEqual(json.loads((db / "changes").read_text()), {"changes": ["a.nix", "untracked.nix"]})
        inputs = json.loads((self.state / "stamp").read_text())
        self.assertEqual(inputs["working"][0], ["a.nix", None])
        (self.root / "another.nix").write_text("{}\n")
        self.execute()
        self.assertEqual(json.loads((self.state / "db/changes").read_text()),
                         {"changes": ["a.nix", "another.nix", "untracked.nix"]})
        base = next(path for path in (self.root / ".git/codeql/nix").iterdir() if path.is_dir())
        self.assertEqual((base / "db/base").read_text(), "unchanged")
        self.assertEqual(self.calls.read_text().count("--overlay-base"), 1)
        self.assertEqual(self.calls.read_text().count("--cache-at-frontier --no-use-precompiled"), 1)
        self.assertFalse(db.exists())
        published = (self.state / "db").resolve()
        actual_archive = lifecycle.archive
        # Refresh allocates a different generation, so recognize its source.
        def raced_archive(root, commit, destination):
            actual_archive(root, commit, destination)
            if destination.parent.parent == self.state:
                (self.root / "untracked.nix").write_text("changed during snapshot")
        with patch.object(lifecycle, "archive", side_effect=raced_archive):
            with self.assertRaisesRegex(RuntimeError, "source changed"):
                self.execute("refresh")
        self.assertEqual((self.state / "db").resolve(), published)

    def test_down_refuses_foreign_targets_and_waiting_hook_does_not_reactivate(self):
        self.execute()
        actual_lock = lifecycle.locked
        @contextlib.contextmanager
        def after_down(path):
            with actual_lock(path):
                (self.state / "db").unlink()
                yield
        with patch.object(lifecycle, "locked", after_down), patch.object(lifecycle, "tools") as resolve:
            self.execute(existing=True)
            resolve.assert_not_called()
        self.execute("down")
        with patch.object(lifecycle, "locked") as lock:
            # Simulates a queued refresh after down removed the publication.
            self.execute(existing=True)
            lock.assert_not_called()
        foreign = self.root.parent / "foreign/db"
        foreign.mkdir(parents=True)
        (self.state / "db").symlink_to(foreign)
        with self.assertRaisesRegex(RuntimeError, "unmanaged database target"):
            self.execute("down")
        self.assertTrue(foreign.is_dir())

    def test_pinned_tool_stamp_and_forced_refresh(self):
        self.db_spec["source"] = "pinned"
        self.execute()
        original = (self.state / "db").resolve()
        self.execute()
        self.assertEqual((self.state / "db").resolve(), original)
        self.execute("refresh")
        self.assertNotEqual((self.state / "db").resolve(), original)
        self.assertEqual(self.calls.read_text().count("create"), 2)
        self.assertNotIn("head", json.loads((self.state / "stamp").read_text()))

    def test_hook_detaches_only_existing_databases_on_branch_checkout(self):
        (self.root / "dev").mkdir()
        (self.root / "dev/codeql-databases.json").write_text(json.dumps({"nix": self.db_spec}))
        with patch.object(sys, "argv", ["codeql-lifecycle", "hook"]), patch.object(lifecycle.subprocess, "Popen") as spawn:
            with patch.object(lifecycle, "run", return_value=str(self.root)):
                lifecycle.main()
                spawn.assert_not_called()
                # A synthetic publication lets this exercise detachment while
                # Popen is mocked, without mocking the creator's own process.
                self.state.mkdir(parents=True)
                (self.state / "db").symlink_to("generation.fixture/db")
                with patch.dict(os.environ, {"PRE_COMMIT_CHECKOUT_TYPE": "0"}):
                    lifecycle.main()
                spawn.assert_not_called()
                with patch.dict(os.environ, {"PRE_COMMIT_CHECKOUT_TYPE": "1"}):
                    lifecycle.main()
                self.assertEqual(spawn.call_count, 1)
                self.assertTrue(spawn.call_args.kwargs["start_new_session"])
                self.assertEqual(spawn.call_args.kwargs["cwd"], self.root)
                self.assertEqual(spawn.call_args.args[0][-2:], ["refresh-existing", "nix"])


unittest.main()

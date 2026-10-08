"""The rendered notice and document limit must agree on project trust."""

import json
import os
import subprocess
import sys
from pathlib import Path

notice, limit, git = sys.argv[1:]
root = Path(os.environ["TMPDIR"]) / "project"
root.mkdir()
user = Path(os.environ["CODEX_HOME"]) / "config.toml"
user.parent.mkdir()


def run_git(*args):
    subprocess.run([git, "-C", str(root), *args], capture_output=True, check=True)


run_git("init", "-q")
run_git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "fixture")
worktree = root.parent / "worktree"
run_git("worktree", "add", "--detach", str(worktree), "HEAD")
plain = root.parent / "plain"
plain.mkdir()
for directory in (root, worktree, plain):
    (directory / ".codex").mkdir()
    (directory / ".codex/config.toml").write_text("project_doc_max_bytes = 65536\n")


def trust(entries):
    user.write_text("\n".join(f"[projects.{json.dumps(str(path))}]\ntrust_level = {json.dumps(level)}" for path, level in entries))


def probe(directory, warning, expected_limit=32768):
    env = dict(os.environ, DEVENV_ROOT=str(directory))
    result = subprocess.run([notice], env=env, capture_output=True, text=True, check=True)
    assert result.stdout == "", result
    if warning:
        assert "warning: Codex ignores" in result.stderr
        assert "an explicit cwd entry overrides main-checkout trust" in result.stderr
        assert str(directory / ".codex/config.toml") in result.stderr
        assert str(user) in result.stderr
    else:
        assert result.stderr == "", result.stderr
    result = subprocess.run([limit, str(directory), "32768"], env=env, capture_output=True, text=True, check=True)
    assert result.stderr == "" and result.stdout.strip() == str(expected_limit), result


trust([])
probe(root, True)
trust([(root, "trusted")])
probe(root, False, 65536)
probe(worktree, False, 65536)
trust([(root, "trusted"), (worktree, "untrusted")])
probe(worktree, True)
trust([(plain, "trusted")])
probe(plain, False, 65536)
# Empty cwd entry shadows main-checkout trust, as in Codex's own lookup.
trust([(root, "trusted")])
with user.open("a") as stream:
    stream.write(f"\n[projects.{json.dumps(str(worktree))}]\n")
probe(worktree, True)
# Each missing/unreadable input follows an otherwise identical bad case.
trust([])
probe(root, True)
user.unlink()
probe(root, False)
trust([])
probe(root, True)
project = root / ".codex/config.toml"
project.unlink()
probe(root, False)
project.write_text("project_doc_max_bytes = 65536\n")
for unreadable in (user, project):
    probe(root, True)
    unreadable.chmod(0)
    try:
        probe(root, False)
    finally:
        unreadable.chmod(0o600)
probe(root, True)
user.write_text("not toml!")
probe(root, False)

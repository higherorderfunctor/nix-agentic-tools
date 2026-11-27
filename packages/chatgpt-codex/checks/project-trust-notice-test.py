"""The launcher's trust notice and the document limit must agree on project trust."""

import json
import os
import subprocess
import sys
from pathlib import Path

launcher, limit, git = sys.argv[1:]
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


def probe(case, directory, warning, expected_limit=32768):
    result = subprocess.run([launcher], cwd=directory, capture_output=True, text=True, check=True)
    assert result.stdout == "", (case, result)
    if warning:
        assert result.stderr.splitlines() == [
            f"warning: Codex ignores {directory / '.codex/config.toml'} because this project is not trusted in {user}. "
            "Set the project trust_level to trusted in the user config to load the delivered config."
        ], (case, result.stderr)
    else:
        assert result.stderr == "", (case, result.stderr)
    result = subprocess.run([limit, str(directory), "32768"], capture_output=True, text=True, check=False)
    if expected_limit is None:
        # The resolver rejects malformed TOML; advisory callers stay silent.
        assert result.returncode != 0 and result.stdout == "", (case, result)
        assert "tomllib.TOMLDecodeError:" in result.stderr, (case, result)
    else:
        assert result.returncode == 0 and result.stderr == "" and result.stdout.strip() == str(expected_limit), (case, result)


# Measured with Codex 0.161.0: an empty worktree entry keeps clone trust.
empty_entry = f"\n[projects.{json.dumps(str(worktree))}]\n"
for case, entries, extra, directory, warning, effective in (
    ("no trust entry leaves the checkout config unloaded", [], "", root, True, 32768),
    ("exact checkout trust loads its limit", [(root, "trusted")], "", root, False, 65536),
    ("linked worktree inherits checkout trust", [(root, "trusted")], "", worktree, False, 65536),
    ("explicit worktree distrust overrides inherited trust", [(root, "trusted"), (worktree, "untrusted")], "", worktree, True, 32768),
    ("exact trust works without a Git marker", [(plain, "trusted")], "", plain, False, 65536),
    ("empty worktree entry does not revoke inherited trust", [(root, "trusted")], empty_entry, worktree, False, 65536),
    ("explicit worktree trust does not require checkout trust", [(worktree, "trusted")], "", worktree, False, 65536),
):
    trust(entries)
    if extra:
        with user.open("a") as stream:
            stream.write(extra)
    probe(case, directory, warning, effective)

user.unlink()
for directory in (root, worktree, plain):
    probe("missing user config still leaves the project untrusted", directory, True)
trust([])
probe("readable project config and an undecided user warn", root, True)
project = root / ".codex/config.toml"
project.unlink()
probe("missing project config leaves nothing to warn about", root, False)
project.write_text("project_doc_max_bytes = 65536\n")
probe("rewritten project config warns", root, True)
for unreadable in (user, project):
    unreadable.chmod(0)
    try:
        probe(f"unreadable {unreadable} inhibits trust advice", root, False)
    finally:
        unreadable.chmod(0o600)
user.write_text("not toml!")
probe("malformed user TOML fails resolution but does not fail launch", root, False, None)

"""Calibrate launch warnings with the pinned Codex, offline and without auth."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

binary, preflight, hm_launcher, devenv_launcher, fake_launcher, preflight_source, bash, trust_notice, permission_notice, *broken_launchers = sys.argv[1:]
home = Path(os.environ["CODEX_HOME"])
root = Path.cwd() / "fixture"
root.mkdir()
subprocess.run(["git", "-c", "core.fsmonitor=false", "init", "-q", str(root)], check=True)
(root / ".codex").mkdir()
child = root / "child"
child.mkdir()


def user_config(text=""):
    (home / "config.toml").write_text(text)


def trust(path=root):
    user_config(f"[projects.{json.dumps(str(path))}]\ntrust_level = 'trusted'\n")


# Fails a hung command by name instead of at the CI job's 60-minute limit. A
# cold Codex start on a loaded runner has taken over 5 s, so leave headroom.
def run(arguments, cwd=root, data=None, env=None):
    return subprocess.run(arguments, cwd=cwd, input=data, capture_output=True, env=env, timeout=60)


def documents(prompt):
    found = {}
    for item in prompt:
        if item.get("role") != "user":
            continue
        for content in item.get("content", []):
            header, marker, body = content.get("text", "").partition("\n\n<INSTRUCTIONS>\n")
            if marker and header.startswith("# AGENTS.md instructions for "):
                instructions, closing, _ = body.rpartition("\n</INSTRUCTIONS>")
                assert closing
                found[header] = instructions
    return found


def notice(expected, arguments=(), cwd=root):
    result = run([preflight, *arguments], cwd=cwd)
    assert result.returncode == 0, result
    assert result.stdout == b"", result.stdout
    if expected:
        assert b"exceed Codex's project_doc_max_bytes" in result.stderr, result.stderr
        assert b"ai.codex.projectDocMaxBytes" in result.stderr, result.stderr
    else:
        assert result.stderr == b"", result.stderr
    # Independently calibrate every local-discovery fixture with Codex's own
    # prompt builder. Strip exec-only flags; the config/cwd/profile inputs are
    # identical to the invocation under test.
    options = [arg for arg in arguments if arg not in {"exec", "--json", "--model", "unused", "prompt"}]
    if "--" in options:
        options = options[:options.index("--")]
    prompts = []
    for extra in [[], ["-c", "project_doc_max_bytes=2147483647"]]:
        probe = run([binary, *options, *extra, "debug", "prompt-input", "probe"], cwd=cwd)
        assert probe.returncode == 0, probe.stderr
        prompts.append(documents(json.loads(probe.stdout)))
    assert (prompts[0] != prompts[1]) == expected, (arguments, result.stderr)
    return result.stderr


def sized(path, size):
    path.write_bytes(b"x" * (size - 10) + b"\nTAIL-END\n")


# Prove prompt-input itself works in the offline sandbox; a swallowed preflight
# failure must not make the silence cases appear calibrated.
probe = run([binary, "debug", "prompt-input", "probe"])
assert probe.returncode == 0, probe.stderr
assert isinstance(json.loads(probe.stdout), list)
notice(False)
(root / "AGENTS.md").write_text("small instructions\n")
notice(False)
sized(root / "AGENTS.md", 32768)
notice(False)
sized(root / "AGENTS.md", 32769)
notice(True)
notice(False, ["-c", "project_doc_max_bytes=40000"])
notice(False, ["exec", "--model", "unused", "--json", "-c", "project_doc_max_bytes=40000", "prompt"])
user_config("project_doc_max_bytes = 40000\n")
notice(False)
user_config("project_doc_max_bytes = 16\n")
(root / "AGENTS.md").write_text("a document longer than sixteen bytes\n")
notice(True)
user_config()
sized(root / "AGENTS.md", 40000)
(root / ".codex/config.toml").write_text("project_doc_max_bytes = 50000\n")
assert b"must be trusted" in notice(True)
trust()
notice(False)
notice(False, cwd=child)
# A nearer project limit can lower the budget, not only raise it.
(child / ".codex").mkdir()
(child / ".codex/config.toml").write_text("project_doc_max_bytes = 12\n")
notice(True, cwd=child)
(child / ".codex/config.toml").unlink()
(root / ".codex/config.toml").unlink()
user_config()

# Cumulative budget: two individually small files exceed it together. The
# identical tails cannot fool a check of the full instruction block.
sized(root / "AGENTS.md", 20000)
sized(child / "AGENTS.md", 20000)
assert str(child).encode() in notice(True, cwd=child)
sized(root / "AGENTS.md", 32768)
assert str(child).encode() in notice(True, cwd=child)
# Preferred override excludes the oversized ordinary AGENTS.md.
(root / "AGENTS.override.md").write_text("override\n")
notice(False)
(root / "AGENTS.override.md").unlink()
(root / "AGENTS.md").unlink()
(child / "AGENTS.md").unlink()
sized(root / "GUIDANCE.md", 40000)
notice(False)
notice(True, ["-c", 'project_doc_fallback_filenames=["GUIDANCE.md"]'])
(root / "GUIDANCE.md").unlink()

# An unreadable document must be silent rather than fail the launch.
sized(root / "AGENTS.md", 40000)
(root / "AGENTS.md").chmod(0)
notice(False)
(root / "AGENTS.md").chmod(0o600)
# A profile is a real user layer; forward it to both prompt assemblies.
(home / "wide.config.toml").write_text("project_doc_max_bytes = 50000\n")
notice(False, ["--profile", "wide"])
# Probe the caller's requested directory, even from a repository with no docs.
sized(root / "AGENTS.md", 40000)
empty = Path.cwd() / "empty"
empty.mkdir()
notice(True, ["exec", "--json", "--cd", str(root), "prompt"], cwd=empty)
notice(True, [f"-C{root}"], cwd=empty)
notice(False, ["--cd", str(empty)])
# -- ends CLI parsing: prompt text cannot override the working directory.
notice(False, ["--", "--cd", str(root)], cwd=empty)

# Empty overrides win; explicit distrust suppresses all project docs.
(root / "AGENTS.override.md").write_text("")
notice(False)
(root / "AGENTS.override.md").unlink()
user_config(f"[projects.{json.dumps(str(root))}]\ntrust_level = 'untrusted'\n")
notice(False)
user_config()
# No Git marker means only cwd, unless custom root markers are configured.
sized(empty / "AGENTS.md", 40000)
notice(True, cwd=empty)
(empty / "AGENTS.md").unlink()
(root / ".root-marker").touch()
notice(True, ["-c", 'project_root_markers=[".root-marker"]'], cwd=child)
notice(False, ["-c", "project_root_markers=[]"], cwd=child)
# Malformed config and future unknown arguments are silent preflight failures.
user_config("not valid TOML [")
result = run([preflight])
assert result.returncode == 0 and result.stdout == b"" and result.stderr == b"", result
user_config()
for arguments in [["--unknown-future-flag"], ["--remote", "ws://example.invalid"], ["--worktree"]]:
    result = run([preflight, *arguments])
    assert result.returncode == 0 and result.stdout == b"" and result.stderr == b"", result

# Codex ignores managed_config.toml in CODEX_HOME on Unix. A stale home
# file must not raise the effective budget and suppress a real warning.
(home / "managed_config.toml").write_text("project_doc_max_bytes = 50000\n")
notice(True)
(home / "managed_config.toml").unlink()
# Custom-root trust gates config, but doc suppression uses cwd/Git clone.
custom = Path.cwd() / "custom"
(custom / "child").mkdir(parents=True)
(custom / ".root-marker").touch()
sized(custom / "AGENTS.md", 40000)
user_config(f'project_root_markers = [".root-marker"]\n[projects.{json.dumps(str(custom))}]\ntrust_level = "untrusted"\n')
notice(True, cwd=custom / "child")
user_config()

# Linked worktree inherits main-checkout trust and applies its own config.
subprocess.run(["git", "-C", str(root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "fixture"], check=True)
linked = Path.cwd() / "linked"
subprocess.run(["git", "-C", str(root), "worktree", "add", "-qb", "fixture-linked", str(linked)], check=True)
(linked / ".codex").mkdir()
(linked / ".codex/config.toml").write_text("project_doc_max_bytes = 50000\n")
sized(linked / "AGENTS.md", 40000)
trust()
notice(False, cwd=linked)
# Measured with Codex 0.161.0: an empty worktree entry does not revoke trust.
with (Path(os.environ["CODEX_HOME"]) / "config.toml").open("a") as stream:
    stream.write(f"\n[projects.{json.dumps(str(linked))}]\n")
notice(False, cwd=linked)
user_config()
assert b"must be trusted" in notice(True, cwd=linked)

# Both actual module launchers warn; selecting a previous launcher still emits
# one warning, proving the exec/probe target never runs another preflight.
version = run([binary, "--version"]).stdout
for launcher in [hm_launcher, devenv_launcher]:
    result = run([launcher, "--version"])
    assert result.returncode == 0 and result.stdout == version, result
    assert result.stderr.count(b"exceed Codex's project_doc_max_bytes") == 1, result.stderr
# Untrusted project configs at every level each start notice processes; the
# document warning must still print inside the launcher's one-second bound.
# Thirty-two levels outlast that bound when the notices run first.
nested = root
for level in range(32):
    nested = nested / str(level)
    (nested / ".codex").mkdir(parents=True)
    (nested / ".codex/config.toml").write_text("model = 'unused'\n")
for launcher in [hm_launcher, devenv_launcher]:
    result = run([launcher, "--version"], cwd=nested)
    assert result.returncode == 0 and result.stdout == version, result
    assert result.stderr.count(b"exceed Codex's project_doc_max_bytes") == 1, result.stderr
    # The nearest config's notice comes first, so a timeout drops the farthest.
    notices = [line for line in result.stderr.splitlines() if line.startswith(b"warning: Codex ignores ")]
    assert notices and notices[0].startswith(f"warning: Codex ignores {nested}/.codex/config.toml ".encode()), result.stderr
shutil.rmtree(root / "0")

# A real module launcher must not consume stdin, contaminate JSON stdout, or
# change the real command's exit status, even when its preflight warns.
result = run([fake_launcher, "exec", "--json"], data=b"stdin preserved\n")
assert result.returncode == 23, result
assert result.stdout == b'{"output":"unchanged"}\nstdin preserved\n', result.stdout
assert b"exceed Codex's project_doc_max_bytes" in result.stderr, result.stderr

# Resolver failures (including invalid JSON and hangs) are silent. Inject them
# at the preflight's existing executable boundary, rather than adding a runtime
# switch or a test-only branch to the production script.
schema = Path.cwd() / "flags.json"
schema.write_text("{}")
for script in ["exit 1", "printf '{invalid json'", "exec sleep 3"]:
    resolver = Path.cwd() / "broken-resolver"
    resolver.write_text("#!" + bash + "\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n" + script + "\n")
    resolver.chmod(0o700)
    started = time.monotonic()
    result = run([sys.executable, preflight_source, str(resolver), str(schema), trust_notice, permission_notice])
    elapsed = time.monotonic() - started
    assert elapsed < 1.5, script
    if script == "exec sleep 3":
        assert elapsed >= 0.4, "the hanging resolver was never executed"
    assert result.returncode == 0 and result.stdout == b"" and result.stderr == b"", result
# The launcher's shared isolation bounds any preflight: one that fails and
# writes stdout, reads stdin, or hangs with a child leaves the launch's stdin,
# stdout and exit status intact and costs at most the one-second bound. A
# surviving child would hold the captured stderr open past it.
for index, launcher in enumerate(broken_launchers):
    started = time.monotonic()
    result = run([launcher, "exec", "--json"], data=b"stdin preserved\n")
    elapsed = time.monotonic() - started
    assert elapsed < 1.5, (launcher, elapsed)
    if index == len(broken_launchers) - 1:
        assert elapsed >= 0.9, "the hanging preflight was never executed"
    assert result.returncode == 23, result
    assert result.stdout == b'{"output":"unchanged"}\nstdin preserved\n', result.stdout
print("PASS: local discovery matches real offline Codex prompts, both launchers, and failure isolation")

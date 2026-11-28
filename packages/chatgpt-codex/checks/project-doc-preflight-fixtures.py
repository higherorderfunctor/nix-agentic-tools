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
                assert closing and header not in found, (header, found)
                found[header] = instructions
    return found


def notice(case, arguments=(), *, cwd=root, warnings=(), budget=32768, expected_documents=None):
    result = run([preflight, *arguments], cwd=cwd)
    assert result.returncode == 0 and result.stdout == b"", (case, result)
    result_lines = result.stderr.splitlines()
    document_warnings = [line for line in result_lines if b"exceed Codex's project_doc_max_bytes" in line]
    assert len(document_warnings) == len(warnings), (case, result.stderr)
    for warning, path in zip(document_warnings, warnings, strict=True):
        assert warning.startswith(f"warning: {path} is {path.stat().st_size} bytes;".encode()), (case, warning)
        assert f"project_doc_max_bytes ({budget} bytes total)".encode() in warning, (case, warning)
        assert b"ai.codex.projectDocMaxBytes" in warning, (case, warning)
    if not warnings:
        assert not result_lines, (case, result.stderr)
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
    if not warnings:
        assert prompts[0] == prompts[1], (case, arguments, result.stderr)
    # Reject a calibration that compares unrelated prompt content. In the
    # raised-budget probe the attributed files must actually be loaded in full.
    for path in warnings:
        full_document = path.read_text().strip()
        assert any(full_document in body for body in prompts[1].values()), (case, path, "not loaded with the raised budget")
        assert not any(full_document in body for body in prompts[0].values()), (case, path, "not truncated with the normal budget")
    if expected_documents is not None:
        assert {header: text.strip() for header, text in prompts[0].items()} == {
            f"# AGENTS.md instructions for {path.parent}": path.read_text().strip() for path in expected_documents
        }, (case, prompts[0])
    return result.stderr


def sized(path, size, tail=b"TAIL-END"):
    # The last byte must survive prompt whitespace trimming to witness truncation.
    ending = b"\n" + tail
    path.write_bytes(b"x" * (size - len(ending)) + ending)


root_doc = root / "AGENTS.md"
child_doc = child / "AGENTS.md"
# Prove the independent prompt reader actually finds a known file: an empty
# extraction must not make every silence case appear calibrated.
sized(root_doc, 32768)
notice("a document exactly at the default boundary fits", expected_documents=(root_doc,))
sized(root_doc, 32769)
notice("one byte beyond the default boundary truncates", warnings=(root_doc,))
notice("exec options do not hide a session limit", ["exec", "--model", "unused", "--json", "-c", "project_doc_max_bytes=40000", "prompt"])
user_config("project_doc_max_bytes = 40000\n")
notice("user config can raise the default budget")
user_config("project_doc_max_bytes = 16\n")
root_doc.write_text("a document longer than sixteen bytes\n")
notice("user config can lower the default budget", warnings=(root_doc,), budget=16)
user_config()
sized(root_doc, 40000)
root_config = root / ".codex/config.toml"
root_config.write_text("project_doc_max_bytes = 50000\n")
assert b"must be trusted" in notice("an undecided project's limit is ignored, not its docs", warnings=(root_doc,))
trust()
notice("a subdirectory inherits the checkout's limit", cwd=child)
# A nearer project limit can lower the budget, not only raise it.
(child / ".codex").mkdir()
child_config = child / ".codex/config.toml"
child_config.write_text("project_doc_max_bytes = 12\n")
notice("the nearest project's limit beats the wider checkout limit", cwd=child, warnings=(root_doc,), budget=12)
child_config.unlink()
root_config.unlink()
user_config()

# Cumulative budget: two individually small files exceed it together. The
# distinct tails prevent the full root document from standing in for the child.
sized(root_doc, 20000)
sized(child_doc, 20000, tail=b"CHILD-END")
notice("cumulative truncation is attributed to the child, not the root", cwd=child, warnings=(child_doc,))
sized(root_doc, 32768)
notice("a root that consumes the whole budget omits the child", cwd=child, warnings=(child_doc,))
# Preferred override excludes the oversized ordinary AGENTS.md.
root_override = root / "AGENTS.override.md"
root_override.write_text("override\n")
sized(root_doc, 40000)
notice("preferred override hides an oversized ordinary document", expected_documents=(root_override,))
root_override.unlink()
root_doc.unlink()
child_doc.unlink()
fallback = root / "GUIDANCE.md"
sized(fallback, 40000)
notice("alternate names require explicit fallback configuration", expected_documents=())
notice("a configured fallback participates in the budget", ["-c", 'project_doc_fallback_filenames=["GUIDANCE.md"]'], warnings=(fallback,))
fallback.unlink()

sized(root_doc, 40000)
root_doc.chmod(0)
try:
    notice("an unreadable document must not warn or fail the launch")
finally:
    root_doc.chmod(0o600)
# A profile is a real user layer; forward it to both prompt assemblies.
(home / "wide.config.toml").write_text("project_doc_max_bytes = 50000\n")
notice("a selected profile's wider limit suppresses truncation", ["--profile", "wide"])
# Probe the caller's requested directory, even from a repository with no docs.
empty = Path.cwd() / "empty"
empty.mkdir()
notice("--cd among exec options discovers docs outside the launch cwd", ["exec", "--json", "--cd", str(root), "prompt"], cwd=empty, warnings=(root_doc,))
notice("attached -C also selects the directory", [f"-C{root}"], cwd=empty, warnings=(root_doc,))
notice("--cd to an empty directory excludes the launch cwd's docs", ["--cd", str(empty)], expected_documents=())
# -- ends CLI parsing: prompt text cannot override the working directory.
notice("--cd after -- is prompt text", ["--", "--cd", str(root)], cwd=empty, expected_documents=())

root_override.write_text("")
notice("even an empty override hides the ordinary document")
root_override.unlink()
user_config(f"[projects.{json.dumps(str(root))}]\ntrust_level = 'untrusted'\n")
notice("explicit distrust suppresses all project docs", expected_documents=())
user_config()
# No Git marker means only cwd, unless custom root markers are configured.
empty_doc = empty / "AGENTS.md"
sized(empty_doc, 40000)
notice("a cwd without a root marker still supplies its own docs", cwd=empty, warnings=(empty_doc,))
empty_doc.unlink()
(root / ".root-marker").touch()
notice("a custom marker enables a walk to the root docs", ["-c", 'project_root_markers=[".root-marker"]'], cwd=child, warnings=(root_doc,))
notice("empty root markers prevent walking up to Git", ["-c", "project_root_markers=[]"], cwd=child, expected_documents=())

for case, arguments in (
    ("a future flag may consume what looks like a discovery option", ["--unknown-future-flag", "--cd", str(root)]),
    ("remote sessions do not read local docs", ["--remote", "ws://example.invalid"]),
    ("a not-yet-created worktree has no predictable local docs", ["--worktree"]),
):
    result = run([preflight, *arguments])
    assert result.returncode == 0 and result.stdout == b"" and result.stderr == b"", (case, result)

# Codex ignores managed_config.toml in CODEX_HOME on Unix. A stale home
# file must not raise the effective budget and suppress a real warning.
(home / "managed_config.toml").write_text("project_doc_max_bytes = 50000\n")
notice("a stale managed file under CODEX_HOME cannot suppress truncation", warnings=(root_doc,))
(home / "managed_config.toml").unlink()
# Custom-root trust gates config, but doc suppression uses cwd/Git clone.
custom = Path.cwd() / "custom"
(custom / "child").mkdir(parents=True)
(custom / ".root-marker").touch()
sized(custom / "AGENTS.md", 40000)
user_config(f'project_root_markers = [".root-marker"]\n[projects.{json.dumps(str(custom))}]\ntrust_level = "untrusted"\n')
notice("custom-root distrust does not suppress docs in its child", cwd=custom / "child", warnings=(custom / "AGENTS.md",))
user_config()

# Linked worktree inherits main-checkout trust and applies its own config.
subprocess.run(["git", "-C", str(root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "fixture"], check=True)
linked = Path.cwd() / "linked"
subprocess.run(["git", "-C", str(root), "worktree", "add", "-qb", "fixture-linked", str(linked)], check=True)
(linked / ".codex").mkdir()
(linked / ".codex/config.toml").write_text("project_doc_max_bytes = 50000\n")
sized(linked / "AGENTS.md", 40000)
trust()
notice("a linked worktree inherits checkout trust for its own limit", cwd=linked)
# Measured with Codex 0.161.0: an empty worktree entry does not revoke trust.
with (Path(os.environ["CODEX_HOME"]) / "config.toml").open("a") as stream:
    stream.write(f"\n[projects.{json.dumps(str(linked))}]\n")
notice("an empty worktree entry preserves the inherited limit", cwd=linked)
user_config()
assert b"must be trusted" in notice("without checkout trust the worktree limit is ignored", cwd=linked, warnings=(linked / "AGENTS.md",))

# Both actual module launchers warn; selecting a previous launcher still emits
# one warning, proving the exec/probe target never runs another preflight.
version = run([binary, "--version"]).stdout
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
    # Document advice precedes trust advice, and the nearest config is first
    # among trust notices so a timeout drops the farthest.
    notices = [line for line in result.stderr.splitlines() if line.startswith(b"warning: Codex ignores ")]
    assert notices and notices[0].startswith(f"warning: Codex ignores {nested}/.codex/config.toml ".encode()), result.stderr
    assert result.stderr.splitlines()[0].startswith(f"warning: {root_doc} is ".encode()), result.stderr
shutil.rmtree(root / "0")

def assert_exec_result(case, result):
    assert result.returncode == 23, (case, result)
    assert result.stdout == b'{"output":"unchanged"}\nstdin preserved\n', (case, result.stdout)


# A real module launcher must not consume stdin, contaminate JSON stdout, or
# change the real command's exit status, even when its preflight warns.
exec_input = b"stdin preserved\n"
result = run([fake_launcher, "exec", "--json"], data=exec_input)
assert_exec_result("a warning-producing preflight preserves exec I/O and status", result)
assert b"exceed Codex's project_doc_max_bytes" in result.stderr, result.stderr

# Resolver failures (including invalid JSON and hangs) are silent. Inject them
# at the preflight's existing executable boundary, rather than adding a runtime
# switch or a test-only branch to the production script.
schema = Path.cwd() / "flags.json"
schema.write_text("{}")
resolver = Path.cwd() / "broken-resolver"
marker = Path.cwd() / "resolver-ran"
resolver_environment = os.environ | {"RESOLVER_MARKER": str(marker)}
for case, script, minimum_wait in (
    ("a nonzero resolver exit is advisory only", "exit 1", 0),
    ("unparseable resolver output is advisory only", "printf '{invalid json'", 0),
    ("a hanging resolver is killed at the resolver deadline", "exec sleep 3", 0.4),
):
    marker.unlink(missing_ok=True)
    resolver.write_text(
        "#!" + bash + "\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n"
        ': > "$RESOLVER_MARKER"\n' + script + "\n"
    )
    resolver.chmod(0o700)
    started = time.monotonic()
    result = run([sys.executable, preflight_source, str(resolver), str(schema), trust_notice, permission_notice], env=resolver_environment)
    elapsed = time.monotonic() - started
    assert marker.is_file(), (case, "resolver never started")
    assert minimum_wait <= elapsed < 1.5, (case, elapsed)
    assert result.returncode == 0 and result.stdout == b"" and result.stderr == b"", (case, result)

# Match the three fault-injection launchers in chatgpt-codex-project-doc-preflight.nix.
# A surviving child would hold the captured stderr open past the deadline.
for (case, minimum_wait), launcher in zip((
    ("preflight stdout and failure status cannot reach exec", 0),
    ("preflight cannot drain exec stdin", 0),
    ("preflight timeout kills the child without holding stderr open", 0.9),
), broken_launchers, strict=True):
    started = time.monotonic()
    result = run([launcher, "exec", "--json"], data=exec_input)
    elapsed = time.monotonic() - started
    assert minimum_wait <= elapsed < 1.5, (case, elapsed)
    assert_exec_result(case, result)
print("PASS: local discovery matches real offline Codex prompts, both launchers, and failure isolation")

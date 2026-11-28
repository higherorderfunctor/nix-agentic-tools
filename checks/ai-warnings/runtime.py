import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def run(label, argv, *, env=None, stdin="", status=0, stderr="", stdout=""):
    result = subprocess.run(argv, input=stdin, env=env, text=True, capture_output=True)
    assert result.returncode == status, (label, result)
    assert result.stderr == stderr, (label, result.stderr)
    if stdout is not None:
        assert result.stdout == stdout, (label, result.stdout)


def guard(script, root):
    env = os.environ | {"HOME": str(root), "XDG_RUNTIME_DIR": str(root / "runtime")}
    for name in ("CLAUDE_CONFIG_DIR", "MEMORY_GUARD_EXTRA_DIRS", "MEMORY_GUARD_ROOT"):
        env.pop(name, None)
    argv = ["bash", script]

    def warn(label, envelope, reason):
        # A degraded hook allows the write (no denial on stdout) and explains
        # why it could not guard it, on stderr only.
        run(
            label, argv, env=env, stdin=envelope,
            stderr=f"WARNING: ai.claude.memoryCollisionGuard.enable: {reason}; continuing without the guard\n",
        )

    # The scope and cadence check in the Claude owner discards stderr.
    ordinary = '{"tool_input":{"file_path":"/ordinary/file"}}'
    run("an ordinary write is not mislabeled a degradation", argv, env=env, stdin=ordinary)
    warn("invalid JSON identifies the malformed envelope", "invalid", "invalid hook envelope")
    memory = root / ".claude/projects/probe/memory"
    memory.mkdir(parents=True)
    envelope = json.dumps({"session_id": "probe", "tool_input": {"file_path": str(memory / "new.md")}})
    marker_dir = root / "runtime/claude-memory-collision-guard"
    marker_dir.parent.mkdir()
    marker_dir.write_text("obstruction")
    warn("an obstructed marker directory identifies the create failure", envelope, "cannot create marker directory")
    marker_dir.unlink()
    run("healthy write records a marker under the default memory root", argv, env=env, stdin=envelope, stdout=None)
    run("a memoized retry is not mislabeled a degradation", argv, env=env, stdin=envelope)

    # Obstruct the actual marker recorded by the healthy invocation. The
    # cannot-write probe must not depend on the production filename algorithm.
    (marker,) = marker_dir.iterdir()
    marker.unlink()
    marker.symlink_to(root / "missing/marker")
    warn("an obstructed session marker identifies the write failure", envelope, "cannot write session marker")


def credentials(manifest):
    # These cases run the launcher, not just the reader. Each failed reference
    # must name the option and stop before the stub runs, without leaking output.
    cases = {
        "absent": ("launched\n", None),
        "empty": ("", "reference resolved empty"),
        "failed": ("", "reference command failed"),
        "good": ("launched with credential\n", None),
        "missing": ("", "reference file is missing"),
    }
    wrappers = json.loads(Path(manifest).read_text())
    env = os.environ.copy()
    env.pop("PROBE", None)
    option = "ai.kiro.mcpServers.probe.headers.Authorization"
    for case, (output, reason) in cases.items():
        run(
            f"credential {case}", [f"{wrappers[case]}/bin/kiro-cli"], env=env,
            status=0 if reason is None else 1,
            stderr="" if reason is None else f"{option}: {reason}\n", stdout=output,
        )


def global_feature_notices(script, config):
    # The script reads both keys the module passes. Test each key with a
    # distinct set/unset pair, but malformed files only exercise one reader.
    settings = config / "settings/cli.json"

    def notice(feature, key):
        return (
            f"WARNING: Kiro {feature} requested by ai.kiro.cli.{feature}.enable, but "
            f"devenv cannot enable its global setting: {settings} does not set {key}=true. "
            f"Configure ai.kiro.cli.native.settings.{key} in Home Manager; "
            "the project setting is not honored.\n"
        )

    argv = [sys.executable, script, str(config), "codeToSpec", "chat.enableC2s"]
    diagnostic = notice("codeToSpec", "chat.enableC2s")
    settings.parent.mkdir(parents=True)
    run("missing global file warns instead of aborting", argv, stderr=diagnostic)
    for label, contents in {
        "a different enabled key does not satisfy the request": '{"chat.enableWorkflows":true}',
        "false still means disabled even when the key is set": '{"chat.enableC2s":false}',
        "malformed JSON warns instead of aborting": "invalid",
        "non-object JSON warns instead of aborting": "[]",
        "string true is not a JSON boolean": '{"chat.enableC2s":"true"}',
    }.items():
        settings.write_text(contents)
        run(label, argv, stderr=diagnostic)
    settings.write_text('{"chat.enableC2s":true}')
    run("an enabled global setting is quiet", argv)

    workflows = [sys.executable, script, str(config), "workflows", "chat.enableWorkflows"]
    run("code-to-spec does not satisfy the workflows request", workflows, stderr=notice("workflows", "chat.enableWorkflows"))
    settings.write_text('{"chat.enableWorkflows":true}')
    run("workflows reads its own key rather than code-to-spec", workflows)


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    guard(sys.argv[2], root / "guard")
    credentials(sys.argv[3])
    global_feature_notices(sys.argv[1], root / "global-feature-notices")
print("PASS: Kiro credential launch guards, feature notices and optional hook warnings have firing and silent controls")

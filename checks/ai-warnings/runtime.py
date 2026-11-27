import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def run(label, argv, *, env=None, stdin="", status=0, diagnostic=None, output=""):
    result = subprocess.run(argv, input=stdin, env=env, text=True, capture_output=True)
    assert result.returncode == status, (label, result)
    if diagnostic is None:
        assert result.stderr == "", (label, result.stderr)
    else:
        assert diagnostic in result.stderr, (label, result.stderr)
    if output is not None:
        assert result.stdout == output, (label, result.stdout)
    return result


def guard(script, root):
    root.mkdir()
    env = os.environ | {"HOME": str(root), "XDG_RUNTIME_DIR": str(root / "runtime")}
    argv = ["bash", script]
    option = "WARNING: ai.claude.memoryCollisionGuard.enable:"
    run("ordinary path", argv, env=env, stdin='{"tool_input":{"file_path":"/ordinary/file"}}')
    run("malformed envelope", argv, env=env, stdin="invalid", diagnostic=f"{option} invalid hook envelope")
    memory = root / ".claude/projects/probe/memory"
    memory.mkdir(parents=True)
    envelope = json.dumps({"session_id": "probe", "tool_input": {"file_path": str(memory / "new.md")}})
    marker_dir = root / "runtime/claude-memory-collision-guard"
    marker_dir.parent.mkdir()
    marker_dir.write_text("obstruction")
    run("marker directory is blocked", argv, env=env, stdin=envelope, diagnostic=f"{option} cannot create marker directory")
    marker_dir.unlink()
    first = run("first memory write", argv, env=env, stdin=envelope, output=None)
    assert json.loads(first.stdout)["hookSpecificOutput"]["permissionDecision"] == "deny", first.stdout
    run("retry of the same write", argv, env=env, stdin=envelope)

    # Obstruct the actual marker recorded by the healthy invocation. The
    # cannot-write probe must not depend on the production filename algorithm.
    (marker,) = marker_dir.iterdir()
    marker.unlink()
    marker.symlink_to(root / "missing/marker")
    run("session marker is blocked", argv, env=env, stdin=envelope, diagnostic=f"{option} cannot write session marker")


def credentials(manifest):
    cases = {
        "absent": ("launched\n", None),
        "empty": ("", "reference resolved empty"),
        "failed": ("", "reference command failed"),
        "good": ("launched with credential\n", None),
        "missing": ("", "reference file is missing"),
    }
    wrappers = json.loads(Path(manifest).read_text())
    assert wrappers.keys() == cases.keys(), wrappers.keys()
    env = os.environ.copy()
    env.pop("PROBE", None)
    option = "ai.kiro.mcpServers.probe.headers.Authorization"
    for case, (output, reason) in cases.items():
        result = run(
            f"credential {case}",
            [f"{wrappers[case]}/bin/kiro-cli"],
            env=env,
            status=0 if reason is None else 1,
            diagnostic=None if reason is None else f"{option}: {reason}",
            output=output,
        )
        assert "fixture-token" not in result.stderr + result.stdout, f"credential {case} leaked"


def global_feature_notices(script, root):
    for feature, setting in [("codeToSpec", "chat.enableC2s"), ("workflows", "chat.enableWorkflows")]:
        config = root / feature
        argv = [sys.executable, script, str(config), feature, setting]
        settings = config / "settings/cli.json"
        needle = (
            f"WARNING: Kiro {feature} requested by ai.kiro.cli.{feature}.enable, but "
            f"devenv cannot enable its global setting: {settings} does not set {setting}=true"
        )
        settings.parent.mkdir(parents=True)
        for label, value in {
            "disabled": json.dumps({setting: False}),
            "enabled": json.dumps({setting: True}),
            "malformed JSON": "invalid",
            "missing file": None,
            "missing key": "{}",
            "non-object JSON": "[]",
            "string true": json.dumps({setting: "true"}),
        }.items():
            if value is None:
                settings.unlink(missing_ok=True)
            else:
                settings.write_text(value)
            run(f"{feature}: {label}", argv, diagnostic=None if label == "enabled" else needle)


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    guard(sys.argv[2], root / "guard")
    credentials(sys.argv[3])
    global_feature_notices(sys.argv[1], root / "global-feature-notices")
print("PASS: Kiro credential launch guards, feature notices and optional hook warnings have firing and silent controls")

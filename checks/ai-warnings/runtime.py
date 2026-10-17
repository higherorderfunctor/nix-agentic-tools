import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def run(argv, *, env=None, stdin="", warning=None, output=None):
    result = subprocess.run(argv, input=stdin, env=env, text=True, capture_output=True)
    assert result.returncode == 0, result
    if warning is None:
        assert "WARNING:" not in result.stderr, result.stderr
    else:
        assert warning in result.stderr, result.stderr
    if output is not None:
        assert output in result.stdout, result.stdout
    return result


def guard(script, root):
    root.mkdir()
    env = os.environ | {"HOME": str(root), "XDG_RUNTIME_DIR": str(root / "runtime")}
    run(["bash", script], env=env, stdin='{"tool_input":{"file_path":"/ordinary/file"}}')
    run(["bash", script], env=env, stdin="invalid", warning="ai.claude.memoryCollisionGuard.enable: invalid hook envelope")
    memory = root / ".claude/projects/probe/memory"
    memory.mkdir(parents=True)
    envelope = json.dumps({"session_id": "probe", "tool_input": {"file_path": str(memory / "new.md")}})
    marker_dir = root / "runtime/claude-memory-collision-guard"
    marker_dir.parent.mkdir()
    marker_dir.write_text("obstruction")
    run(["bash", script], env=env, stdin=envelope, warning="cannot create marker directory")
    marker_dir.unlink()
    marker_dir.mkdir()
    key = hashlib.sha256(str(memory / "new.md").encode()).hexdigest()[:16]
    marker = marker_dir / f"probe-{key}"
    marker.symlink_to(root / "missing/marker")
    run(["bash", script], env=env, stdin=envelope, warning="cannot write session marker")
    marker.unlink()
    run(["bash", script], env=env, stdin=envelope, output='"permissionDecision":"deny"')
    result = run(["bash", script], env=env, stdin=envelope)
    assert result.stdout == ""


def credentials(manifest):
    for case, package in json.loads(Path(manifest).read_text()).items():
        for binary in ["kiro-cli", "kiro-cli-chat"]:
            argv = [f"{package}/bin/{binary}"]
            if case in ["absent", "good"]:
                result = run(argv, output="launched")
            else:
                result = subprocess.run(argv, text=True, capture_output=True)
                assert result.returncode != 0, result
                assert "launched" not in result.stdout, result.stdout
                assert "ai.kiro.mcpServers.probe.headers.Authorization" in result.stderr, result.stderr
            assert "fixture-token" not in result.stderr + result.stdout


def global_feature_notices(script, root):
    for feature, setting in [("codeToSpec", "chat.enableC2s"), ("workflows", "chat.enableWorkflows")]:
        config = root / feature
        argv = [sys.executable, script, str(config), feature, setting]
        needle = f"ai.kiro.cli.{feature}.enable"
        run(argv, warning=needle)
        settings = config / "settings/cli.json"
        settings.parent.mkdir(parents=True)
        for value in ['{}', json.dumps({setting: False}), 'invalid', '[]', json.dumps({setting: "true"})]:
            settings.write_text(value)
            result = run(argv, warning=needle)
            assert setting in result.stderr
        settings.write_text(json.dumps({setting: True}))
        run(argv)


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    guard(sys.argv[2], root / "guard")
    credentials(sys.argv[3])
    global_feature_notices(sys.argv[1], root / "global-feature-notices")
print("PASS: Kiro credential launch guards, feature notices and optional hook warnings have firing and silent controls")

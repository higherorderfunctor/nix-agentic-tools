import hashlib
import json
import os
from pathlib import Path
import shlex
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


def files(script, root):
    project, state = root / "project", root / "state"
    project.mkdir()
    desired = root / "desired.json"
    spec = {"mode": "symlink", "option": "ai.codex.files.\"probe\"", "source": "/nix/store/probe"}
    desired.write_text(json.dumps({"probe": spec}))
    argv = [sys.executable, script, str(project), str(state), str(desired)]
    target = project / "probe"
    for kind in ["absent", "file", "directory", "stale-link"]:
        if kind == "file":
            target.write_text("user content")
        elif kind == "directory":
            target.mkdir()
        elif kind == "stale-link":
            target.symlink_to("/nix/store/old")
        run(argv, warning='ai.codex.files."probe" is set but devenv did not deliver')
        if target.is_dir():
            target.rmdir()
        else:
            target.unlink(missing_ok=True)
    target.symlink_to("/nix/store/probe")
    run(argv)
    target.unlink()
    target.write_text("user edit")
    desired.write_text("{}")
    for _ in range(2):
        run(argv, warning='ai.codex.files."probe" was removed but devenv retained')
        assert target.read_text() == "user edit"
    target.unlink()
    run(argv)
    run(argv)
    # Still declared by a different owner: this is not a removal.
    target.write_text("other owner")
    (state / "ai-delivery-observed.json").write_text(json.dumps({"probe": spec}))
    current = root / "current.json"
    current.write_text('["probe"]')
    run(argv + [str(current)])
    target.unlink()
    # Bootstrap from upstream's old ledger and ignore unrelated files. The map
    # is EXACT: a consumer file that merely sits under a runtime's config
    # directory is theirs, and claiming it reported a removal of an ai.* option
    # that never wrote the file.
    owned = root / "owned.json"
    (project / ".kiro").mkdir()
    (project / ".kiro/consumer-owned").write_text("mine")
    (state / "files.json").write_text(json.dumps({"managedFiles": [".kiro/consumer-owned"]}))
    owned.write_text(json.dumps({".kiro": "ai.kiro.files"}))
    run([sys.executable, script, "snapshot", str(state), str(owned)])
    run(argv)
    (state / "files.json").write_text(json.dumps({"managedFiles": [".kiro/old", ".kiro/consumer-owned", "unrelated"]}))
    owned.write_text(json.dumps({".kiro/old": "ai.kiro.files"}))
    (project / ".kiro/old").write_text("retired")
    run([sys.executable, script, "snapshot", str(state), str(owned)])
    result = run(argv, warning="ai.kiro.files was removed but devenv retained")
    assert "unrelated" not in result.stderr
    assert "consumer-owned" not in result.stderr
    # Explicit copy/seed mode is intentional and stays quiet.
    (project / ".kiro/old").unlink()
    (project / ".kiro/consumer-owned").unlink()
    desired.write_text(json.dumps({"probe": spec | {"mode": "seed"}}))
    run(argv)
    for invalid in ["bad json", "[]", '{"old":{}}']:
        if invalid.startswith('{'):
            (project / "old").write_text("retired")
        (state / "ai-delivery-observed.json").write_text(invalid)
        run(argv, warning="ai.*.files delivery inspection failed")


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


def reminder(script, root):
    root.mkdir()
    env = os.environ | {"HOME": str(root), "XDG_CACHE_HOME": str(root / "cache"), "KIRO_DATA_DIR": str(root / "data")}
    run([script], env=env, warning="ai.kiro.workflowReminder.includeVendorSteering: no compatible engine bundle")
    bundle_root = root / "data/kas/1.0.0-probe"
    bundle_root.mkdir(parents=True)
    run([script], env=env, warning="engine script is missing")
    bundle = bundle_root / "node_modules/@kiro/agent/dist/server/acp-server.js"
    bundle.parent.mkdir(parents=True)
    bundle.write_text("// no steering here")
    run([script], env=env, warning="vendor steering extraction failed")
    cache = root / "cache/nix-agentic-tools/kiro-workflow-steering/1.0.0-probe.md"
    cache.write_text("vendor reminder positive control")
    run([script], env=env, output="vendor reminder positive control")


def credentials(manifest):
    for case, package in json.loads(Path(manifest).read_text()).items():
        for binary in ["kiro-cli", "kiro-cli-chat"]:
            result = run([f"{package}/bin/{binary}"], output="launched", warning=(
                None if case in ["absent", "good"] else "ai.kiro.mcpServers.probe.headers.Authorization"
            ))
            assert "fixture-token" not in result.stderr + result.stdout


def workflows(script, root):
    argv = [sys.executable, script, "workflows", str(root)]
    run(argv, warning="ai.kiro.unlockedRolloutFeatures includes workflows")
    settings = root / "settings/cli.json"
    settings.parent.mkdir(parents=True)
    for value in ['{}', '{"chat.enableWorkflows":false}', 'invalid']:
        settings.write_text(value)
        run(argv, warning="ai.kiro.unlockedRolloutFeatures includes workflows")
    settings.write_text('{"chat.enableWorkflows":true}')
    run(argv)


def clamp(script, root):
    root.mkdir()
    payload = root / "payload"
    payload.write_text("mitigation positive control")
    env = os.environ | {"XDG_RUNTIME_DIR": str(root), "DELEGATION_CLAMP_PAYLOAD_FILE": str(payload)}
    argv = ["bash", script, "inject"]
    envelope = '{"session_id":"probe"}'
    run(argv, env=env, stdin=envelope, output="mitigation positive control")
    assert run(argv, env=env, stdin=envelope).stdout == ""
    clear = ["bash", script, "clear"]
    run(clear, env=env, stdin=envelope)
    run(argv, env=env, stdin="invalid", warning="ai.claude.delegationClamp.mitigate: hook envelope has no session id")
    directory = root / "claude-delegation-clamp"
    # cspell:ignore nosession  (the literal fallback marker key, not project vocabulary)
    (directory / "nosession").unlink()
    directory.rmdir()
    directory.write_text("obstruction")
    run(argv, env=env, stdin=envelope, warning="cannot create marker directory", output="mitigation positive control")
    directory.unlink()
    directory.mkdir()
    marker = directory / "probe"
    marker.symlink_to(root / "missing/marker")
    run(argv, env=env, stdin=envelope, warning="cannot write session marker", output="mitigation positive control")
    marker.unlink()
    marker.mkdir()
    run(clear, env=env, stdin=envelope, warning="cannot clear session marker")
    marker.rmdir()
    payload.unlink()
    run(argv, env=env, stdin=envelope, warning="payload file missing or unreadable")
    payload.mkdir()
    run(argv, env=env, stdin=envelope, warning="cannot read payload")


def manifest(script):
    words = shlex.split(Path(script).read_text().replace("\\\n", ""))
    path = next(word for word in words if word.endswith("-ai-delivery-files.json"))
    return json.loads(Path(path).read_text())


def wiring(script):
    desired = manifest(script)
    assert "ai.kiro.lspServers" in desired[".custom-kiro/settings/lsp.json"]["option"]
    assert "ai.codex.native.settings" in desired[".codex/config.toml"]["option"]
    assert 'ai.codex.files."probe"' in desired["probe"]["option"]
    # A shared AGENTS.md owner key belongs to the runtime whose context names
    # it, never to whichever runtime sorts first.
    assert "ai.kiro." in desired["KIRO.md"]["option"], desired["KIRO.md"]
    assert "ai.codex." not in desired["KIRO.md"]["option"], desired["KIRO.md"]
    assert "ai.codex." in desired.get("CODEX.md", {}).get("option", ""), desired
    # Provenance is exact: a consumer file under a runtime config directory is
    # not an ai.* delivery and must not be observed as one.
    assert ".custom-kiro/consumer-owned.md" not in desired


def kimchi_wiring(script):
    # Kimchi's devenv context lands in the project-root AGENTS.md whatever its
    # (Home Manager) context.filename says; the manifest must follow the file
    # actually written, not the option.
    desired = manifest(script)
    assert "ai.kimchi." in desired.get("AGENTS.md", {}).get("option", ""), desired


def shared_agents_md_wiring(script):
    # Several runtimes write the one project-root AGENTS.md. The manifest names
    # every writer's options, so the runtime that actually supplied the text is
    # among them even when an empty one sorts first.
    option = manifest(script).get("AGENTS.md", {}).get("option", "")
    assert "ai.kimchi." in option, option
    assert "ai.codex." in option, option


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    files(sys.argv[1], root)
    guard(sys.argv[2], root / "guard")
    reminder(sys.argv[3], root / "reminder")
    credentials(sys.argv[4])
    workflows(sys.argv[1], root / "workflows")
    clamp(sys.argv[5], root / "clamp")
    wiring(sys.argv[6])
    kimchi_wiring(sys.argv[7])
    shared_agents_md_wiring(sys.argv[8])
print("PASS: file observations and optional hook warnings have firing and silent controls")

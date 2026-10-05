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


def manifest(script, suffix="-ai-delivery-files.json"):
    words = shlex.split(Path(script).read_text().replace("\\\n", ""))
    path = next(word for word in words if word.endswith(suffix))
    return json.loads(Path(path).read_text())


def owned(script):
    """Path -> the consumer options that write it, as the snapshot sees it."""
    return manifest(script, "-ai-delivery-owned.json")


def current(script):
    """Every path delivered this generation: symlinks and owned copies."""
    return manifest(script, "-ai-delivery-current-files.json")


def wiring(script):
    desired = manifest(script)
    assert "ai.kiro.lspServers" in desired[".custom-kiro/settings/lsp.json"]["option"]
    assert "ai.codex.native.settings" in desired[".codex/config.toml"]["option"]
    assert 'ai.codex.files."probe"' in desired["probe"]["option"]
    # A shared AGENTS.md key is an owned COPY: never a symlink the report
    # inspects, always a current path the retirement report skips.
    names = owned(script)
    assert "KIRO.md" not in desired and "CODEX.md" not in desired, desired
    assert {"KIRO.md", "CODEX.md"} <= set(current(script)), current(script)
    # A shared AGENTS.md owner key belongs to the runtime whose context names
    # it, never to whichever runtime sorts first.
    assert "ai.kiro." in names["KIRO.md"], names["KIRO.md"]
    assert "ai.codex." not in names["KIRO.md"], names["KIRO.md"]
    assert "ai.codex." in names.get("CODEX.md", ""), names
    # Provenance is exact: a consumer file under a runtime config directory is
    # not an ai.* delivery and must not be observed as one.
    assert ".custom-kiro/consumer-owned.md" not in desired
    assert ".custom-kiro/consumer-owned.md" not in names


def kimchi_wiring(script):
    # Kimchi's devenv context lands in the project-root AGENTS.md whatever its
    # (Home Manager) context.filename says; the manifest must follow the file
    # actually written, not the option.
    names = owned(script)
    assert "ai.kimchi." in names.get("AGENTS.md", ""), names
    assert "AGENTS.md" in current(script)


def shared_agents_md_wiring(script):
    # Several runtimes write the one project-root AGENTS.md. The manifest names
    # every writer's options, so the runtime that actually supplied the text is
    # among them even when an empty one sorts first.
    option = owned(script).get("AGENTS.md", "")
    assert "ai.kimchi." in option, option
    assert "ai.codex." in option, option


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    files(sys.argv[1], root)
    guard(sys.argv[2], root / "guard")
    credentials(sys.argv[3])
    workflows(sys.argv[1], root / "workflows")
    wiring(sys.argv[4])
    kimchi_wiring(sys.argv[5])
    shared_agents_md_wiring(sys.argv[6])
print("PASS: file observations and optional hook warnings have firing and silent controls")

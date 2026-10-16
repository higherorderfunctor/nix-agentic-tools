"""Execute generated activations step by step and assert disk and state."""

import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import tomllib

import yaml

PARSERS = {"json": json.loads, "toml": tomllib.loads, "yaml": yaml.safe_load}
# Native order around the generated bodies: HM prunes before checkLinkTargets
# and linkGeneration; devenv cleans up native links before prune and guard.
ORDER = {"devenv": ("cleanup", "prune", "guard", "link", "apply"), "hm": ("prune", "cleanup", "link", "apply")}
NATIVE = {"native": 1}


def localize(step, directory):
    commands = step["commands"]
    for index, replacement in enumerate(step["replacements"]):
        assert any(replacement["path"] in command for command in commands.values()), replacement["path"]
        local = directory / f"input-{index}.json"
        local.write_text(json.dumps(replacement["value"]))
        commands = {phase: command.replace(replacement["path"], str(local)) for phase, command in commands.items()}
    return commands


def run(bash, script, environment):
    result = subprocess.run([bash, "-c", script], env=environment, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def act(action, root, step, previous):
    """Change the tree the way a person or program would between activations.

    Returns the bytes the next activation must back up: every edit and native
    key here precedes a change to the owned copy.
    """
    changed = []
    for path, item in (step["plan"] if action == "seed" else previous).items():
        destination = root / path
        if action == "edit" and item["method"] == "ro":
            destination.chmod(0o644)
            destination.write_bytes(b"edited\n")
            changed.append(destination.read_bytes())
        elif action == "native" and item["method"] == "rw":
            assert item["format"] == "json", item
            destination.write_text(json.dumps({**json.loads(destination.read_text()), **NATIVE}))
            changed.append(destination.read_bytes())
        elif action == "seed":
            destination.write_text(item["content"]["text"])
            destination.chmod(0o444 if item["method"] == "ro" else 0o600)
    return changed


def expected_ro(item):
    if "text" in item["content"]:
        return item["content"]["text"].encode(), 0o444
    source = Path(item["content"]["source"])
    return source.read_bytes(), 0o444 | (stat.S_IMODE(source.stat().st_mode) & 0o111)


def check(root, state, step, previous, native, backups):
    plan = step["plan"]
    # The engine removes its state once it owns nothing; the comparison below still
    # fails if owned entries are expected and the state is missing.
    state_file = state / "ai.json"
    records = json.loads(state_file.read_text())["files"] if state_file.exists() else {}
    owned = {path: (item["method"], item["format"]) for path, item in plan.items() if item["method"] != "symlink"}
    assert {path: (record["method"], record["format"]) for path, record in records.items()} == owned, records
    assert set(step["links"]) == {path for path, item in plan.items() if item["method"] == "symlink"}
    for path, item in plan.items():
        destination = root / path
        if item["method"] == "symlink":
            assert os.readlink(destination) == step["links"][path], path
            if "source" in item["content"]:
                assert destination.stat().st_mode & 0o111 == Path(item["content"]["source"]).stat().st_mode & 0o111, path
            continue
        assert destination.is_file() and not destination.is_symlink(), path
        if item["method"] == "ro":
            data, mode = expected_ro(item)
            assert destination.read_bytes() == data and stat.S_IMODE(destination.stat().st_mode) == mode, path
        else:
            declared = PARSERS[item["format"]](item["content"]["text"])
            assert PARSERS[item["format"]](destination.read_text()) == {**declared, **native.get(path, {})}, path
    for path in previous.keys() - plan.keys():
        if path in native:
            assert json.loads((root / path).read_text()) == native[path], path
        else:
            assert not os.path.lexists(root / path), path
    assert sorted(backup.read_bytes() for backup in backups) == sorted(step["backups"]), backups
    if "adopted" in step["expect"]:
        assert not any(record["created"] for record in records.values()), records
    for path in step["executable"]:
        assert (root / path).stat().st_mode & 0o100, path


def scenario(bash, shim, backend, steps, directory):
    root = directory / "root"
    root.mkdir()
    environment = {key: value for key, value in os.environ.items() if key not in ("DRY_RUN", "XDG_STATE_HOME")}
    if backend == "hm":
        environment["HOME"] = str(root)
        state = root / ".local/state/nix-agentic-tools/files"
    else:
        environment.update(DEVENV_ROOT=str(root), DEVENV_STATE=str(directory / "state"))
        state = directory / "state/nix-agentic-tools/files"
    previous, linked, native = {}, {}, {}
    for index, step in enumerate(steps):
        step["plan"] = {item["path"]: item for item in step["plan"]}
        step["backups"] = []
        for action in step["actions"]:
            step["backups"] += act(action, root, step, previous)
            if action == "native":
                native.update({path: NATIVE for path, item in previous.items() if item["method"] == "rw"})
        commands = localize(step, directory / f"step-{index}")
        # prune always runs; apply only for a non-empty plan; the devenv guard only with native links.
        expected = {"prune"} | ({"apply"} if step["plan"] else set()) | ({"guard"} if backend == "devenv" and step["links"] else set())
        assert set(commands) == expected, commands.keys()
        before = set(state.glob("*.bak"))
        for phase in ORDER[backend]:
            if phase == "cleanup":
                for path in linked.keys() - step["links"].keys():
                    (root / path).unlink()
            elif phase == "link":
                for path, target in step["links"].items():
                    destination = root / path
                    if destination.is_symlink():
                        destination.unlink()
                    # Both native steps refuse to replace a real file.
                    assert not os.path.lexists(destination), f"native link blocked: {path}"
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.symlink_to(target)
            elif phase in commands:
                run(bash, (shim if backend == "hm" else "") + "\n" + commands[phase], environment)
        check(root, state, step, previous, native, set(state.glob("*.bak")) - before)
        previous, linked = step["plan"], step["links"]


def main():
    fixture = json.loads(Path(sys.argv[1]).read_text())
    bash, shim = sys.argv[2], Path(sys.argv[3]).read_text()
    count = 0
    for backend, scenarios in sorted(fixture.items()):
        for name, steps in sorted(scenarios.items()):
            with tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                for index in range(len(steps)):
                    (directory / f"step-{index}").mkdir()
                try:
                    scenario(bash, shim, backend, steps, directory)
                except AssertionError as error:
                    raise AssertionError(f"{backend}/{name}: {error}") from error
            count += 1
    print(f"PASS: {count} transition scenarios")


if __name__ == "__main__":
    main()

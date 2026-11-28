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


def add_native_keys(root, previous, native):
    """Return the bytes to back up: each native key precedes an owned change."""
    changed = []
    for path, item in previous.items():
        if item["method"] == "rw":
            destination = root / path
            destination.write_text(json.dumps({**json.loads(destination.read_text()), **NATIVE}))
            changed.append(destination.read_bytes())
            native[path] = NATIVE
    return changed


def check(root, state, step, previous, native, backups):
    wanted = step["want"]
    # The engine removes its state once it owns nothing.
    owned = {path: (item["method"], item["format"]) for path, item in wanted.items() if item["method"] != "symlink"}
    state_file = state / "ai.json"
    assert state_file.exists() == bool(owned), state_file
    records = json.loads(state_file.read_text())["files"] if owned else {}
    assert {path: (record["method"], record["format"]) for path, record in records.items()} == owned, records
    assert set(step["links"]) == {path for path, item in wanted.items() if item["method"] == "symlink"}
    for path, item in wanted.items():
        destination = root / path
        if item["method"] == "symlink":
            if "source" in item:
                assert os.readlink(destination) == item["source"], path
            else:
                assert destination.is_symlink(), path
                assert destination.read_text() == item["text"], path
            continue
        assert destination.is_file() and not destination.is_symlink(), path
        if item["method"] == "ro":
            data = Path(item["source"]).read_bytes() if "source" in item else item["text"].encode()
            assert destination.read_bytes() == data, path
            assert stat.S_IMODE(destination.stat().st_mode) == int(item.get("mode", "0444"), 8), path
        else:
            assert PARSERS[item["format"]](destination.read_text()) == {"k": "v", **native.get(path, {})}, path
    for path in previous.keys() - wanted.keys():
        if path in native:
            assert json.loads((root / path).read_text()) == native[path], path
        else:
            assert not os.path.lexists(root / path), path
    assert sorted(backup.read_bytes() for backup in backups) == sorted(step["backups"]), backups


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
        step["backups"] = []
        for action in step["actions"]:
            assert action == "native", action
            step["backups"] += add_native_keys(root, previous, native)
        commands = localize(step, directory / f"step-{index}")
        # prune always runs; apply only for a non-empty plan; the devenv guard only with native links.
        expected = {"prune"}
        if step["want"]:
            expected.add("apply")
        if backend == "devenv" and any(item["method"] == "symlink" for item in step["want"].values()):
            expected.add("guard")
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
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.symlink_to(target)
            elif phase in commands:
                run(bash, (shim if backend == "hm" else "") + "\n" + commands[phase], environment)
        try:
            check(root, state, step, previous, native, set(state.glob("*.bak")) - before)
        except AssertionError as error:
            raise AssertionError(f"step {index + 1}: {error}") from error
        previous, linked = step["want"], step["links"]


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

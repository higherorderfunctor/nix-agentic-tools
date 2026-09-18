"""Exercise the shared JSON helper and real HM callers across generations."""

import copy
import json
import os
import stat
import subprocess
import sys
from pathlib import Path


def merge(left, right):
    result = copy.deepcopy(left)
    for key, value in right.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def snapshot(path):
    info = path.stat()
    return path.read_bytes(), stat.S_IMODE(info.st_mode), info.st_mtime_ns


def exercise(case, bash, mode, use_xdg):
    root = Path.cwd() / f"{case['name']}-{mode:o}-{use_xdg}"
    home = root / "home"
    state = root / "state" if use_xdg else home / ".local/state"
    config = home / case["configFile"]
    environment = dict(os.environ, HOME=str(home))
    environment.pop("XDG_STATE_HOME", None)
    if use_xdg:
        environment["XDG_STATE_HOME"] = str(state)
    # A case whose writer STATES the mode its file must carry (kiro's merge
    # mcp.json, the one document a sibling target also writes) asserts
    # imposition instead of preservation: the stated mode on a new file, on a
    # rewrite, and on an activation that moves no bytes. Every other case
    # states none and keeps preserving whatever the file already had.
    imposed = int(case["mode"], 8) if "mode" in case else None

    def settled(fallback):
        """The mode the file must carry after a successful activation."""
        return fallback if imposed is None else imposed

    def frozen(before):
        """`before`, allowing for the mode a stated-mode writer re-imposes."""
        return before if imposed is None else (before[0], imposed, before[2])

    def activate(generation, succeeds=True):
        # A later activation entry must run, with parent-shell flags unchanged.
        script = (
            'before_flags=$-\nbefore_options=$(set +o)\n'
            + case["scripts"][generation]
            + '\ntest "$before_flags" = "$-"\n'
            + 'test "$before_options" = "$(set +o)"\n'
            + 'echo later-entry-ran\n'
        )
        result = subprocess.run(
            [bash, "-e", "-c", script],
            env=environment,
            capture_output=True,
            text=True,
        )
        assert (result.returncode == 0) == succeeds, result.stderr
        if succeeds:
            assert "later-entry-ran" in result.stdout

    # First empty generation creates neither config nor ownership state. It
    # must also leave an externally managed, even malformed, file byte-identical.
    activate(2)
    assert not home.exists()
    assert not state.exists()
    config.parent.mkdir(parents=True)
    config.write_text("externally managed, not JSON\n")
    config.chmod(mode)
    before = snapshot(config)
    activate(2)
    assert snapshot(config) == before
    assert not state.exists()
    config.unlink()

    # New files are private, regardless of umask. Existing files retain their
    # permissions through both changed-content and unchanged-content writes,
    # unless the writer states a mode -- `settled` and `frozen` above.
    activate(0)
    assert stat.S_IMODE(config.stat().st_mode) == settled(0o600)
    assert json.loads(config.read_text()) == case["first"]
    config.chmod(mode)
    before = snapshot(config)
    activate(0)
    assert snapshot(config) == frozen(before)
    manifests = list((state / "nix-agentic-tools/json-settings").glob("*.json"))
    assert len(manifests) == 1
    manifest = manifests[0]
    assert stat.S_IMODE(manifest.stat().st_mode) == 0o600
    assert stat.S_IMODE(manifest.parent.stat().st_mode) == 0o700
    assert not (state / "nix-agentic-tools/toml-settings").exists()

    # The application adds unowned siblings after Nix has claimed its leaves.
    # Model a native atomic replacement so even a read-only file mode works.
    native_file = config.with_suffix(".native")
    native_file.write_text(json.dumps(merge(case["first"], case["native"])))
    native_file.chmod(mode)
    native_file.replace(config)
    activate(1)
    assert json.loads(config.read_text()) == merge(case["second"], case["native"])
    assert stat.S_IMODE(config.stat().st_mode) == settled(mode)

    os.utime(config, ns=(1000000000, 1000000000))
    os.utime(manifest, ns=(1000000000, 1000000000))
    before_config, before_manifest = snapshot(config), snapshot(manifest)
    activate(1)
    assert snapshot(config) == before_config
    assert snapshot(manifest) == before_manifest

    # Malformed documents (including valid JSON of the wrong root type) and
    # corrupt ownership must fail before changing either artifact.
    for malformed in ("{", "[]", "null"):
        config.unlink()
        config.write_text(malformed)
        config.chmod(mode)
        before = snapshot(config)
        activate(1, succeeds=False)
        assert snapshot(config) == before
        assert snapshot(manifest) == before_manifest
    config.unlink()
    config.write_bytes(before_config[0])
    config.chmod(mode)
    manifest.write_text('{"version": 1, "managed_paths": [[]]}')
    before = snapshot(config), snapshot(manifest)
    activate(1, succeeds=False)
    assert (snapshot(config), snapshot(manifest)) == before
    manifest.write_bytes(before_manifest[0])

    activate(2)
    assert json.loads(config.read_text()) == case["native"]
    assert stat.S_IMODE(config.stat().st_mode) == settled(mode)
    assert not manifest.exists()
    before = snapshot(config)
    activate(2)
    assert snapshot(config) == before
    assert not list(config.parent.glob(".*.nat-tmp.*"))
    print(f"PASS: {case['name']} mode={mode:o} xdg={use_xdg}")


cases = json.loads(Path(sys.argv[1]).read_text())
assert cases, "JSON runtime corpus is empty"
assert len({case["name"] for case in cases}) == len(cases), "duplicate runtime case"
for case in cases:
    assert len(case["scripts"]) == 3, f"{case['name']}: expected three generations"
    assert all(isinstance(script, str) and script.strip() for script in case["scripts"]), \
        f"{case['name']}: missing activation body"
os.umask(0)
for case in cases:
    for mode in (0o400, 0o600, 0o640):
        for use_xdg in (False, True):
            exercise(case, sys.argv[2], mode, use_xdg)

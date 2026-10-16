"""Exercise state migration and refusal on real engine files."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("files_engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)


def plan(text):
    return [{"content": {"text": text}, "executable": None, "format": "raw", "method": "ro",
             "mode": None, "path": "owned", "recursive": False}]


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary) / "root"
    root.mkdir()
    state = Path(temporary) / "state" / "runtime.json"
    owned = root / "owned"
    engine.reconcile([], root, state, "apply")
    assert not state.exists()
    engine.reconcile(plan("old"), root, state, "apply")
    original = json.loads(state.read_text())
    assert original["version"] == 1
    print("PASS: missing state starts at v1; nothing owned leaves no state file")

    state.write_text(json.dumps({**original, "version": 0}))
    bad_source = plan("old") + [{**plan("new")[0], "path": "other", "content": {"source": "/missing"}}]
    try:
        engine.reconcile(bad_source, root, state, "apply")
    except ValueError as error:
        assert "source must be a file" in str(error)
    else:
        raise AssertionError("bad source accepted")
    assert json.loads(state.read_text()) == original
    assert owned.read_text() == "old"
    migrated_inode = state.stat().st_ino
    assert engine.load_state(state) == original
    assert state.stat().st_ino == migrated_inode
    print("PASS: v0 changes only version, saves before reconciliation, repeat load is a no-op")

    malformed = {
        "bad digest": {**original, "files": {"owned": {**original["files"]["owned"], "digest": "bad"}}},
        "bad files": {"files": [], "version": 1},
        "bad method": {**original, "files": {"owned": {**original["files"]["owned"], "method": "missing"}}},
        "bad path": {**original, "files": {"../outside": original["files"]["owned"]}},
        "missing version": {"files": original["files"]},
        "negative version": {**original, "version": -1},
        "unknown version": {**original, "version": 2},
        "v0 bad digest": {"files": {"owned": {**original["files"]["owned"], "digest": "bad"}}, "version": 0},
        "version boolean": {**original, "version": True},
    }
    for name, value in malformed.items():
        state.write_text(json.dumps(value))
        before = state.read_bytes()
        try:
            engine.reconcile(plan("new"), root, state, "apply")
        except ValueError:
            pass
        else:
            raise AssertionError(f"{name} accepted")
        assert state.read_bytes() == before and owned.read_text() == "old"
    print(f"PASS: {len(malformed)} malformed states refused before destination mutation")


for previous_exists, current_exists in ((True, False), (True, True), (False, False)):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        legacy = Path(temporary) / "state"
        previous = legacy / "files2"
        current = legacy / "files"
        if previous_exists:
            engine.reconcile(plan("previous"), root, previous / "ai.json", "apply")
            (previous / "preserved.bak").write_bytes(b"backup")
            previous_state = (previous / "ai.json").read_bytes()
        if current_exists:
            engine.reconcile(plan("current"), root, current / "ai.json", "apply")
        expected = "current" if current_exists else "previous"
        desired = plan(expected) if previous_exists or current_exists else []
        original_lock = engine.fcntl.flock
        original_mkdir = Path.mkdir

        def before_mkdir(path, *args, **kwargs):
            if path == current:
                # Before namespace creation, migration either moved everything
                # or left the absent pair untouched.
                assert previous.exists() == (previous_exists and current_exists)
                assert current.exists() == (previous_exists or current_exists)
            return original_mkdir(path, *args, **kwargs)

        def before_lock(stream, operation):
            assert previous.exists() == (previous_exists and current_exists)
            if previous_exists and not current_exists:
                assert (current / "ai.json").read_bytes() == previous_state
                assert (current / "preserved.bak").read_bytes() == b"backup"
            return original_lock(stream, operation)

        with patch.object(Path, "mkdir", before_mkdir), patch.object(engine.fcntl, "flock", before_lock):
            engine.reconcile(desired, root, current / "ai.json", "apply", legacy_state=legacy)
        assert (current / "ai.json").exists() == bool(desired)
        if desired:
            assert sorted(json.loads((current / "ai.json").read_text())["files"]) == ["owned"]
            assert (root / "owned").read_text() == expected
        if previous_exists:
            retained = previous if current_exists else current
            assert (retained / "ai.json").read_bytes() == previous_state
            assert (retained / "preserved.bak").read_bytes() == b"backup"
        print(f"PASS: legacy state move previous={previous_exists}, current={current_exists}, disk and state preserved before lock")

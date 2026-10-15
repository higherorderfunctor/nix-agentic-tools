"""Exercise state migration and refusal on real engine files."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("files2_engine", sys.argv[1])
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
    assert json.loads(state.read_text()) == {"files": {}, "version": 1}
    print("PASS: missing state starts at v1")

    engine.reconcile(plan("old"), root, state, "apply")
    original = json.loads(state.read_text())
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

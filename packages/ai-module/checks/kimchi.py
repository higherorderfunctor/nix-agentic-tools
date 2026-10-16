"""Execute agent restoration, retirement, and legacy drain in real directories."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import sys
import tempfile

spec = importlib.util.spec_from_file_location("files_engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
fixtures = json.loads(Path(sys.argv[2]).read_text())

with tempfile.TemporaryDirectory() as temporary:
    for backend, directories in fixtures.items():
        for index, steps in enumerate(directories.values()):
            for disabled_first in (False, True):
                base = Path(temporary) / f"{backend}-{index}-{disabled_first}"
                root, old = base / "root", base / "old"
                agents = root / steps[0]["agentsDir"]
                agents.mkdir(parents=True)
                state = base / "state/ai.json"
                legacy = steps[0]["legacyLedgers"]
                ledger = old / legacy[0]["ledger"]
                ledger.parent.mkdir(parents=True)
                (agents / "retired.md").write_text("old\n")
                (agents / "created.md").write_text("created\n")
                ledger.write_text("retired.md\t" + hashlib.sha256(b"old\n").hexdigest() + "\n")
                for step in ([steps[-1]] if disabled_first else steps):
                    assert step["legacyLedgers"] == legacy
                    plan = copy.deepcopy(step["plan"])
                    for item in plan:
                        source = Path(item["content"]["source"])
                        # CI reads formatted outputs; local eval can supply
                        # staged text without building the generated tree.
                        if not source.exists():
                            item["content"] = {"text": step["texts"][item["path"]]}
                    engine.reconcile(plan, root, state, "prune", legacy, old)
                    assert not ledger.exists() and not (agents / "retired.md").exists()
                    engine.reconcile(plan, root, state, "apply", legacy, old)
                    # The engine deletes its state file when a run ends owning nothing.
                    assert state.exists() == bool(plan)
                    records = json.loads(state.read_text())["files"] if plan else {}
                    assert set(records) == {item["path"] for item in plan}
                    assert {path.name for path in agents.iterdir()} == {"created.md"} | {
                        Path(item["path"]).name for item in plan}
                    assert (agents / "created.md").read_text() == "created\n"
                    for item in plan:
                        path = root / item["path"]
                        expected = (Path(item["content"]["source"]).read_bytes()
                                    if "source" in item["content"] else item["content"]["text"].encode())
                        assert path.read_bytes() == expected and not path.is_symlink()
                        assert not path.parent.is_symlink()
                        assert stat.S_IMODE(path.stat().st_mode) == 0o444
                        try:
                            path.write_text("in-place edit")
                        except PermissionError:
                            pass
                        else:
                            raise AssertionError("read-only agent accepted an in-place edit")
                        assert records[item["path"]]["method"] == "ro"
                        assert records[item["path"]]["digest"] == hashlib.sha256(expected).hexdigest()
                        # Kimchi's rename-over edit must be backed up and the
                        # declaration restored; a repeated run is idempotent.
                        replacement = base / "replacement.md"
                        edited = f"edited {item['path']}\n".encode()
                        replacement.write_bytes(edited)
                        replacement.replace(path)
                        engine.reconcile(plan, root, state, "apply", legacy, old)
                        assert path.read_bytes() == expected
                        assert any(backup.read_bytes() == edited
                                   for backup in state.parent.rglob("*.bak"))
                        before = state.read_bytes()
                        engine.reconcile(plan, root, state, "apply", legacy, old)
                        assert state.read_bytes() == before
                print(f"PASS: {backend}, prefix={index}, disabled-first={disabled_first}: bytes, modes, state, restore, backup, retirement, legacy drain")

"""Execute agent delivery, retirement, and legacy drain in real directories."""
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
                    # Apply the emitted plan without replacing its source files.
                    plan = step["plan"]
                    engine.reconcile(plan, root, state, "prune", legacy, old)
                    assert not ledger.exists() and not (agents / "retired.md").exists()
                    engine.reconcile(plan, root, state, "apply", legacy, old)
                    records = json.loads(state.read_text())["files"] if plan else {}
                    assert set(records) == {item["path"] for item in plan}
                    assert {path.name for path in agents.iterdir()} == {"created.md"} | {
                        Path(item["path"]).name for item in plan}
                    assert (agents / "created.md").read_text() == "created\n"
                    for item in plan:
                        path = root / item["path"]
                        expected = Path(item["content"]["source"]).read_bytes()
                        assert path.read_bytes() == expected and not path.is_symlink()
                        assert stat.S_IMODE(path.stat().st_mode) == 0o444
                        assert records[item["path"]]["method"] == "ro"
                        assert records[item["path"]]["digest"] == hashlib.sha256(expected).hexdigest()
                print(f"PASS: {backend}, prefix={index}, disabled-first={disabled_first}: bytes, modes, state, retirement, legacy drain")

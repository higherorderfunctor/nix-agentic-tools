"""Execute Codex copy generations, restoration, retirement, and legacy drain."""
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
                root, old, state = base / "root", base / "old", base / "state/ai.json"
                for entry in steps[-1]["legacy"]:
                    directory = root / entry["path"]
                    directory.mkdir(parents=True)
                    name = "settings.json" if directory.name == "app-server-daemon" else "retired.rules"
                    (directory / name).write_bytes(b"old\n")
                    (directory / "unmanaged").write_bytes(b"keep\n")
                    ledger = old / entry["ledger"]
                    ledger.parent.mkdir(parents=True, exist_ok=True)
                    ledger.write_text(name + "\t" + hashlib.sha256(b"old\n").hexdigest() + "\n")
                rules = root / steps[0]["prefix"] / "rules"
                (rules / "default.rules").write_bytes(b"native policy\n")
                for step in ([steps[-1]] if disabled_first else steps):
                    # The owner fixture pins the members; reconcile must read the
                    # actual emitted sources and their rendered store outputs.
                    plan = step["plan"]
                    for phase in ("prune", "apply"):
                        engine.reconcile(plan, root, state, phase, step["legacy"], old)
                    assert all(not (old / entry["ledger"]).exists() for entry in step["legacy"])
                    assert (rules / "default.rules").read_bytes() == b"native policy\n"
                    assert all((root / entry["path"] / "unmanaged").read_bytes() == b"keep\n" for entry in step["legacy"])
                    records = json.loads(state.read_text())["files"] if plan else {}
                    assert set(records) == {item["path"] for item in plan}
                    assert {path.name for path in rules.iterdir()} == {"default.rules", "unmanaged"} | {
                        Path(item["path"]).name for item in plan if item["path"].endswith(".rules")}
                    for item in plan:
                        path, content = root / item["path"], item["content"]
                        if item["path"].endswith(".rules"):
                            expected = b"POLICY\n"
                        else:
                            # Daemon settings must copy the renderer output, not
                            # link to it or overwrite it with legacy bytes.
                            expected = Path(content["rendered"]).read_bytes()
                        assert path.read_bytes() == expected and not path.is_symlink()
                        assert stat.S_IMODE(path.stat().st_mode) == 0o444
                        record = records[item["path"]]
                        assert record["digest"] == hashlib.sha256(expected).hexdigest()
                        edited = f"edited {item['path']}\n".encode()
                        replacement = base / "replacement"
                        replacement.write_bytes(edited)
                        replacement.replace(path)
                        engine.reconcile(plan, root, state, "apply", step["legacy"], old)
                        assert path.read_bytes() == expected
                        assert any(backup.read_bytes() == edited for backup in state.parent.rglob("*.bak"))
                if backend == "hm":
                    assert not (root / steps[0]["prefix"] / "app-server-daemon/settings.json").exists()
                print(f"PASS: {backend}, prefix={index}, disabled-first={disabled_first}: bytes, modes, state, restore, backup, retirement, legacy drain")

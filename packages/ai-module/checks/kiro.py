"""Exercise Kiro steering plans, native links, and disabled-first-upgrade drain."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("files2_engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
fixtures = json.loads(Path(sys.argv[2]).read_text())

with tempfile.TemporaryDirectory() as temporary:
    for backend, steps in fixtures.items():
        for disabled_first in (False, True):
            base = Path(temporary) / f"{backend}-{disabled_first}"
            root, old = base / "root", base / "state"
            steering = root / ".kiro/steering"
            steering.mkdir(parents=True)
            state = old / "files2/ai.json"
            legacy = steps[0]["legacyLedgers"]
            ledger = old / legacy[0]["ledger"]
            ledger.parent.mkdir(parents=True)
            (steering / "managed.md").write_text("old\n")
            (steering / "unmanaged.md").write_text("keep\n")
            ledger.write_text("managed.md\t" + hashlib.sha256(b"old\n").hexdigest() + "\n")
            previous = []
            for step in ([steps[-1]] if disabled_first else steps):
                plan = copy.deepcopy(step["plan"])
                for item in plan:
                    # CI reads the formatted tree. A direct local run can use
                    # its staged bytes without building a derivation.
                    source = Path(item["content"]["source"])
                    if not source.exists():
                        item["content"] = {"text": step["texts"][item["path"]]}
                engine.reconcile(plan, root, state, "prune", legacy, old)
                assert not (steering / "managed.md").exists()
                assert not ledger.exists()
                for path in previous:
                    (root / path).unlink()
                for path in step["native"]:
                    (root / path).symlink_to("/nix/store/kiro-test-source")
                previous = step["native"]
                engine.reconcile(plan, root, state, "apply", legacy, old)
                records = json.loads(state.read_text())["files"]
                assert set(records) == {item["path"] for item in plan}
                for item in plan:
                    path = root / item["path"]
                    expected = (Path(item["content"]["source"]).read_bytes()
                                if "source" in item["content"] else item["content"]["text"].encode())
                    assert path.read_bytes() == expected and path.stat().st_mode & 0o777 == 0o444
                    assert records[item["path"]]["method"] == "ro"
                    assert records[item["path"]]["digest"] == hashlib.sha256(expected).hexdigest()
                assert {path.name for path in steering.iterdir()} == {"unmanaged.md"} | {
                    Path(path).name for path in step["native"] + [item["path"] for item in plan]}
                assert (steering / "unmanaged.md").read_text() == "keep\n"
                assert not list(state.parent.glob("*.bak"))
            print(f"PASS: {backend}, disabled-first={disabled_first}: bytes, modes, state, legacy drain, unrelated file")

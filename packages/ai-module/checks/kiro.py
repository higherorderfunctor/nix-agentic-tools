"""Exercise Kiro steering plans, native links, and upgrade drain."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("files_engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
fixtures = json.loads(Path(sys.argv[2]).read_text())

with tempfile.TemporaryDirectory() as temporary:
    for backend, steps in fixtures.items():
        base = Path(temporary) / backend
        root, old = base / "root", base / "state"
        steering = root / ".kiro/steering"
        steering.mkdir(parents=True)
        state = old / "files/ai.json"
        legacy = steps[0]["legacyLedgers"]
        ledger = old / next(item["ledger"] for item in legacy if item["path"] == ".kiro/steering")
        ledger.parent.mkdir(parents=True)
        (steering / "managed.md").write_text("old\n")
        (steering / "unmanaged.md").write_text("keep\n")
        ledger.write_text("managed.md\t" + hashlib.sha256(b"old\n").hexdigest() + "\n")
        previous = []
        # Removal can lose one rule, all rules while enabled, or all owner output.
        transitions = zip(steps, [
            ("two rules land", ("alpha", "beta")),
            ("beta retires without removing alpha", ("alpha",)),
            ("empty enabled owner retires alpha", ()),
            ("disabled owner does not recreate rules", ()),
        ], strict=True)
        for step, (scenario, rules) in transitions:
            paths = {f".kiro/steering/{rule}.md" for rule in rules}
            copied = paths if backend == "devenv" else set()
            linked = paths if backend == "hm" else set()
            assert set(step["native"]) == linked, (backend, scenario)
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
            # The engine deletes its state file when a run ends owning nothing.
            if not copied:
                assert not state.exists()
            records = json.loads(state.read_text())["files"] if copied else {}
            assert set(records) == copied, (backend, scenario)
            for item in plan:
                path = root / item["path"]
                expected = (Path(item["content"]["source"]).read_bytes()
                            if "source" in item["content"] else item["content"]["text"].encode())
                assert path.read_bytes() == expected and path.stat().st_mode & 0o777 == 0o444
            assert {path.name for path in steering.iterdir()} == {"unmanaged.md"} | {
                f"{rule}.md" for rule in rules}
            assert (steering / "unmanaged.md").read_text() == "keep\n"
        print(f"PASS: {backend}: bytes, modes, state, legacy drain, unrelated file")

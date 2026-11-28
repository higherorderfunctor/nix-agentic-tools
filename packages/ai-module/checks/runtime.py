"""Execute the files engine on normalized plans and real directories."""

import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

spec = importlib.util.spec_from_file_location("files_engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
fixtures = json.loads(Path(sys.argv[2]).read_text())


for backend, plans in sorted(fixtures.items()):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        state = Path(temporary) / "state" / "runtime.json"
        copy = root / "nested" / "file.txt"
        for name, expected in [("copy", "declared"), ("updated", "updated")]:
            engine.reconcile(plans[name], root, state, "apply")
            assert copy.read_text() == expected
        copy.chmod(0o644)
        copy.write_text("local")
        engine.reconcile(plans["copy"], root, state, "apply")
        assert copy.read_text() == "declared"
        assert [item.read_text() for item in state.parent.glob("*.bak")] == ["local"]
        engine.reconcile(plans["empty"], root, state, "prune")
        assert not copy.exists()
        assert not state.exists()
        engine.reconcile(plans["source"], root, state, "apply")
        leaf = root / "tree" / "b" / "c.md"
        assert leaf.read_bytes() == b"Nested fixture.\n"
        engine.reconcile(plans["empty"], root, state, "apply")
        assert not leaf.exists()
        try:
            engine.reconcile([{**plans["copy"][0], "path": "../escape"}], root, state, "apply")
        except ValueError as error:
            assert str(error) == "invalid plan entry: ../escape"
        else:
            raise AssertionError("traversal accepted")
        with tempfile.TemporaryDirectory() as persistence:
            written_root = Path(persistence) / "root"
            written_root.mkdir()
            written_state = Path(persistence) / "state" / "runtime.json"
            first = {**plans["copy"][0], "path": "a"}
            invalid = {**plans["source"][0], "path": "z", "content": {"source": "/missing/source"}}
            try:
                engine.reconcile([first, invalid], written_root, written_state, "apply")
            except ValueError as error:
                assert str(error) == "source must be a file: /missing/source"
            else:
                raise AssertionError("missing source accepted")
            assert (written_root / "a").read_text() == "declared"
            assert list(json.loads(written_state.read_text())["files"]) == ["a"]
            run_log = Path(persistence) / "run.log"
            os.environ["FILES_RUN_LOG"] = str(run_log)
            try:
                engine.reconcile(plans["run"], written_root, written_state, "apply")
            finally:
                del os.environ["FILES_RUN_LOG"]
            assert run_log.read_text() == "run\n"
        with tempfile.TemporaryDirectory() as ownership:
            owned_root = Path(ownership) / "root"
            owned_root.mkdir()
            owned_state = Path(ownership) / "state" / "runtime.json"
            relative = "/".join(["d" * 36] * 6 + ["file"])
            nested_plan = [{**plans["copy"][0], "path": relative}]
            nested_copy = owned_root / relative
            engine.reconcile(nested_plan, owned_root, owned_state, "apply")
            nested_copy.chmod(0o644)
            nested_copy.write_text("local")
            engine.reconcile(plans["empty"], owned_root, owned_state, "prune")
            backups = list(owned_state.parent.glob("*.bak"))
            assert not nested_copy.exists() and len(backups) == 1
            assert backups[0].read_text() == "local" and len(backups[0].name.encode()) <= 255
            assert not owned_state.exists()
        for kind in ("file", "symlink"):
            with tempfile.TemporaryDirectory() as refusal:
                refused_root = Path(refusal) / "root"
                refused_root.mkdir()
                refused_state = Path(refusal) / "state" / "runtime.json"
                blocked = refused_root / "file"
                if kind == "file":
                    blocked.write_text("unmanaged")
                else:
                    blocked.symlink_to(refusal)
                try:
                    engine.reconcile(plans["descendant"], refused_root, refused_state, "prune")
                except ValueError as error:
                    assert str(error) == f"symlinked or non-directory parent refused: {blocked}"
                else:
                    raise AssertionError(f"{kind} parent accepted")
                assert blocked.is_symlink() if kind == "symlink" else blocked.read_text() == "unmanaged"
        # Execute bits, explicit override, and owner-only modes lacking group/world
        # read must all survive normalization and be recognized on retirement.
        permission_cases = (
            ("executable", "executable", 0o555),
            ("imposedMode", "private", 0o400),
            ("ownerRead-0500", "readable", 0o500),
        )
        for name, expected, mode in permission_cases:
            with tempfile.TemporaryDirectory() as permissions:
                mode_root = Path(permissions) / "root"
                mode_root.mkdir()
                mode_state = Path(permissions) / "state" / "runtime.json"
                delivered = mode_root / "file"
                engine.reconcile(plans[name], mode_root, mode_state, "apply")
                recorded = json.loads(mode_state.read_text())
                assert delivered.read_text() == expected, name
                assert stat.S_IMODE(delivered.stat().st_mode) == mode, name
                assert recorded["files"]["file"]["mode"] == mode, name
                engine.reconcile(plans["empty"], mode_root, mode_state, "prune")
                assert not delivered.exists() and not mode_state.exists(), name
        with tempfile.TemporaryDirectory() as permissions:
            source_root = Path(permissions) / "root"
            source_root.mkdir()
            source_state = Path(permissions) / "state" / "runtime.json"
            source = Path(permissions) / "source"
            source.write_bytes(b"source bytes")
            source.chmod(0o755)
            source_plan = [{**plans["source"][0], "path": "file", "content": {"source": str(source)}}]
            engine.reconcile(source_plan, source_root, source_state, "apply")
            delivered = source_root / "file"
            recorded = json.loads(source_state.read_text())
            assert delivered.read_bytes() == b"source bytes" and stat.S_IMODE(delivered.stat().st_mode) == 0o555
            assert recorded["files"]["file"]["mode"] == 0o555
        with tempfile.TemporaryDirectory() as adoption:
            adopted_root = Path(adoption) / "root"
            adopted_root.mkdir()
            adopted_state = Path(adoption) / "state" / "runtime.json"
            adopted = adopted_root / "nested" / "file.txt"
            adopted.parent.mkdir()
            adopted.write_text("declared")
            adopted.chmod(0o444)
            engine.reconcile(plans["copy"], adopted_root, adopted_state, "apply")
            recorded = json.loads(adopted_state.read_text())
            assert adopted.read_text() == "declared" and recorded["files"]["nested/file.txt"]["created"] is False
            assert list(adopted_state.parent.glob("*.bak")) == []
            engine.reconcile(plans["disabled"], adopted_root, adopted_state, "prune")
            engine.reconcile(plans["disabled"], adopted_root, adopted_state, "apply")
            assert not adopted.exists() and adopted.parent.is_dir()
            assert not adopted_state.exists()
        with tempfile.TemporaryDirectory() as refusal:
            refused_root = Path(refusal) / "root"
            refused_root.mkdir()
            refused_state = Path(refusal) / "state" / "runtime.json"
            fifo = refused_root / "nested" / "file.txt"
            fifo.parent.mkdir()
            os.mkfifo(fifo)
            try:
                engine.reconcile(plans["copy"], refused_root, refused_state, "apply")
            except ValueError as error:
                assert str(error) == f"special file refused: {fifo}"
            else:
                raise AssertionError("special file accepted")
            assert stat.S_ISFIFO(fifo.lstat().st_mode)
            assert not refused_state.exists()
        print(f"PASS: {backend} ro runtime, adoption, drain, modes, refusals")

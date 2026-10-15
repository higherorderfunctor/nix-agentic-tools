"""Execute the files2 engine on normalized plans and real directories."""

import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("files2_engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
fixtures = json.loads(Path(sys.argv[2]).read_text())


for backend, plans in sorted(fixtures.items()):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        state = Path(temporary) / "state" / "runtime.json"
        sibling = root / "nested" / "unmanaged"
        sibling.parent.mkdir()
        sibling.write_text("keep")
        copy = root / "nested" / "file.txt"
        for name, expected in [("copy", "declared"), ("updated", "updated")]:
            engine.reconcile(plans[name], root, state, "apply")
            assert copy.read_text() == expected
        assert stat.S_IMODE(copy.stat().st_mode) == 0o444
        copy.chmod(0o644)
        copy.write_text("local")
        engine.reconcile(plans["copy"], root, state, "apply")
        assert copy.read_text() == "declared"
        assert [item.read_text() for item in state.parent.glob("*.bak")] == ["local"]
        engine.reconcile(plans["empty"], root, state, "prune")
        assert not copy.exists() and sibling.read_text() == "keep"
        assert json.loads(state.read_text()) == {"version": 1, "files": {}}
        engine.reconcile(plans["source"], root, state, "apply")
        leaf = root / "tree" / "b" / "c.md"
        assert leaf.read_bytes() == Path(plans["source"][0]["content"]["source"]).read_bytes()
        engine.reconcile(plans["empty"], root, state, "apply")
        assert not leaf.exists() and sibling.exists()
        plan_file = Path(temporary) / "plan.json"
        plan_file.write_text(json.dumps(plans["copy"]))
        subprocess.run([sys.executable, "-I", sys.argv[1], "--plan", str(plan_file), "--root", str(root), "--state", str(state), "--phase", "apply"], check=True)
        assert copy.read_text() == "declared"
        try:
            engine.reconcile([{**plans["copy"][0], "path": "../escape"}], root, state, "apply")
        except ValueError as error:
            assert "invalid plan entry" in str(error)
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
                assert "source must be a file" in str(error)
            else:
                raise AssertionError("missing source accepted")
            assert (written_root / "a").read_text() == "declared"
            assert list(json.loads(written_state.read_text())["files"]) == ["a"]
            run_log = Path(persistence) / "run.log"
            os.environ["FILES2_RUN_LOG"] = str(run_log)
            try:
                engine.reconcile(plans["run"], written_root, written_state, "apply")
            finally:
                del os.environ["FILES2_RUN_LOG"]
            assert run_log.read_text() == "run\n"
            assert (written_root / "nested/file.txt").read_text() == "declared"
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
            assert json.loads(owned_state.read_text())["files"] == {}
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
                    assert "symlinked or non-directory parent refused" in str(error)
                else:
                    raise AssertionError(f"{kind} parent accepted")
                assert blocked.is_symlink() if kind == "symlink" else blocked.read_text() == "unmanaged"
        with tempfile.TemporaryDirectory() as refusal:
            refused_root = Path(refusal) / "root"
            refused_root.mkdir()
            refused_state = Path(refusal) / "state" / "runtime.json"
            outside = Path(refusal) / "outside"
            outside.mkdir()
            marker = outside / "keep"
            marker.write_text("unmanaged")
            (refused_root / "file").symlink_to(outside)
            symlink_plan = [{**plans["descendant"][0], "method": "symlink"}]
            try:
                engine.reconcile(symlink_plan, refused_root, refused_state, "prune")
            except ValueError as error:
                assert "symlinked or non-directory parent refused" in str(error)
            else:
                raise AssertionError("symlink plan traversed a symlinked parent")
            assert marker.read_text() == "unmanaged" and sorted(outside.iterdir()) == [marker]
        for mode in ("0400", "0500"):
            with tempfile.TemporaryDirectory() as ownership:
                owned_root = Path(ownership) / "root"
                owned_root.mkdir()
                owned_state = Path(ownership) / "state" / "runtime.json"
                owned = owned_root / "file"
                engine.reconcile(plans[f"ownerRead-{mode}"], owned_root, owned_state, "apply")
                assert owned.read_text() == "readable" and stat.S_IMODE(owned.stat().st_mode) == int(mode, 8)
                engine.reconcile(plans["empty"], owned_root, owned_state, "prune")
                assert not owned.exists() and json.loads(owned_state.read_text())["files"] == {}
        for name, expected, mode in (("executable", "executable", 0o555), ("imposedMode", "private", 0o400)):
            with tempfile.TemporaryDirectory() as permissions:
                mode_root = Path(permissions) / "root"
                mode_root.mkdir()
                mode_state = Path(permissions) / "state" / "runtime.json"
                delivered = mode_root / "file"
                engine.reconcile(plans[name], mode_root, mode_state, "apply")
                recorded = json.loads(mode_state.read_text())
                assert delivered.read_text() == expected
                assert stat.S_IMODE(delivered.stat().st_mode) == mode
                assert recorded["files"]["file"]["mode"] == mode
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
            recorded = json.loads(adopted_state.read_text())
            assert not adopted.exists() and adopted.parent.is_dir()
            assert recorded["files"] == {}
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
                assert "special file refused" in str(error)
            else:
                raise AssertionError("special file accepted")
            assert stat.S_ISFIFO(fifo.lstat().st_mode)
            assert json.loads(refused_state.read_text())["files"] == {}
        print(f"PASS: {backend} ro runtime, adoption, drain, modes, refusals")

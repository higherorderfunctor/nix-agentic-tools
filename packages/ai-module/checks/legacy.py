"""Execute the engine's import of legacy ownership ledgers on real directories."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("files2_engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)

DIR = {"codec": "dir", "ledger": "materialize/a.manifest", "path": "dir"}
SECOND = {"codec": "dir", "ledger": "materialize/b.manifest", "path": "dir"}
DOC = {"codec": "json", "ledger": "materialize/doc.json", "path": "doc.json"}
# Unsorted on purpose: the engine imports in ledger order.
LEDGERS = [SECOND, DOC, DIR]
DOCUMENT = b'// header\n{"a": {"b": 1}, "native": 2}\n'
# The node each backend's native link step starts from; prune must precede it.
LINK_STEP = {"devenv": "ai2:link-check", "hm": "checkLinkTargets"}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def item(path, text="", method="ro"):
    return {"content": {"text": text}, "executable": None, "format": "json" if method == "rw" else "raw",
            "method": method, "mode": None, "path": path, "recursive": False}


DECLARED = [item("dir/edited"), item("dir/empty"), item("dir/match"), item("doc.json", "{}", "rw")]


def write(path, data, mode=0o444):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)


def write_ledger(old, ledger, units):
    write(old / ledger["ledger"], "".join(f"{name}\t{witness}\n" for name, witness in units.items()).encode(), 0o644)


def seed(root, old):
    """Copies and ledgers left by the retired ownership writer."""
    write(root / "dir/match", b"match\n")
    write(root / "dir/edited", b"edited\n", 0o644)
    write(root / "dir/empty", b"empty\n")
    write(root / "dir/.hidden", b"hidden\n")
    write(root / "dir/unmanaged", b"keep\n")
    (root / "dir/link").symlink_to("/nix/store/old-link")
    write(root / "doc.json", DOCUMENT, 0o600)
    write_ledger(old, DIR, {"match": sha(b"match\n"), "edited": sha(b"original\n"), "empty": "",
                            ".hidden": sha(b"hidden\n"), "link": "", "absent": sha(b"absent\n"), "sub/x": ""})
    write_ledger(old, SECOND, {"match": sha(b"other\n")})
    write(old / DOC["ledger"], json.dumps({"managed_paths": [["a", "b"], ["missing"]], "version": 1}).encode(), 0o644)


def tree(temporary, name):
    root = Path(temporary) / name / "root"
    old = Path(temporary) / name / "state"
    root.mkdir(parents=True)
    seed(root, old)
    return root, old, old / "files2/ai.json"


def owned(state):
    # The engine removes its state once it owns nothing.
    return json.loads(state.read_text())["files"] if state.exists() else {}


def backups(state):
    return sorted(backup.read_bytes() for backup in state.parent.glob("*.bak"))


def imports(temporary):
    root, old, state = tree(temporary, "import")
    engine.reconcile(DECLARED, root, state, "prune", LEDGERS, old)
    copy = {"created": True, "format": "raw", "keys": {}, "method": "ro", "mode": 0o444}
    assert owned(state) == {
        "dir/edited": {**copy, "digest": sha(b"original\n"), "mode": 0o644},
        "dir/empty": {**copy, "digest": sha(b"empty\n")},
        "dir/match": {**copy, "digest": sha(b"match\n")},
        "doc.json": {"created": False, "digest": sha(DOCUMENT), "format": "json",
                     "keys": {"/a/b": engine.key_digest(1)}, "method": "rw", "mode": 0o600},
    }, owned(state)
    assert not list((old / "materialize").iterdir()) and backups(state) == []
    print("PASS: TSV witness match/mismatch/empty, JSON keys, skipped units, first ledger wins, ledgers deleted")

    imported = state.read_bytes()
    write_ledger(old, DIR, {"match": sha(b"restored\n")})
    engine.reconcile(DECLARED, root, state, "prune", LEDGERS, old)
    assert state.read_bytes() == imported and not (old / DIR["ledger"]).exists()
    print("PASS: a restored ledger re-imports nothing and is deleted again")

    texts = {"dir/edited": "new\n", "dir/empty": "new\n", "dir/match": "match\n", "doc.json": '{"a": {"b": 3}}'}
    engine.reconcile([{**entry, "content": {"text": texts[entry["path"]]}} for entry in DECLARED],
                     root, state, "apply", LEDGERS, old)
    assert backups(state) == [b"edited\n"], backups(state)
    assert (root / "doc.json").read_bytes() == b'// header\n{"a": {"b": 3}, "native": 2}\n'
    print("PASS: the first overwrite backs up only the copy edited after its witness")


def drain(temporary):
    root, old, state = tree(temporary, "drain")
    engine.reconcile([], root, state, "prune", LEDGERS, old)
    assert owned(state) == {} and backups(state) == [b"edited\n"]
    assert sorted(path.name for path in (root / "dir").iterdir()) == [".hidden", "link", "unmanaged"]
    assert (root / "doc.json").read_bytes() == b'// header\n{"native": 2}\n'
    engine.reconcile([], root, state, "apply", LEDGERS, old)
    assert owned(state) == {}
    print("PASS: an empty plan drains imported copies and keys; absent ledgers are skipped")


def already_owned(temporary):
    root, old, state = tree(temporary, "owned")
    (old / DIR["ledger"]).unlink()
    engine.reconcile([item("dir/match", "match\n")], root, state, "apply")
    before = state.read_bytes()
    write_ledger(old, DIR, {"match": sha(b"other\n")})
    engine.reconcile([item("dir/match", "match\n")], root, state, "prune", [DIR], old)
    assert state.read_bytes() == before and not (old / DIR["ledger"]).exists()
    print("PASS: a path the engine already owns keeps its state")


def refusals(temporary):
    def ledger_symlink(root, old):
        target = old / "materialize/target"
        (old / DIR["ledger"]).rename(target)
        (old / DIR["ledger"]).symlink_to(target)

    def fifo(root, old):
        (root / "dir/match").unlink()
        os.mkfifo(root / "dir/match")

    def linked_parent(root, old):
        (root / "dir").rename(root / "real")
        (root / "dir").symlink_to(root / "real")

    def symlinked_document(root, old):
        (root / "doc.json").rename(root / "real.json")
        (root / "doc.json").symlink_to(root / "real.json")

    cases = {
        "duplicate address": (DOC, "malformed legacy ledger",
                              lambda root, old: write(old / DOC["ledger"], b'{"managed_paths": [["a"], ["a"]], "version": 1}')),
        "json ledger": (DOC, "malformed legacy ledger", lambda root, old: write(old / DOC["ledger"], b"{")),
        "json version": (DOC, "malformed legacy ledger",
                         lambda root, old: write(old / DOC["ledger"], b'{"managed_paths": [], "version": 2}')),
        "ledger symlink": (DIR, "legacy ledger must be a regular file", ledger_symlink),
        "malformed document": (DOC, "malformed json document", lambda root, old: write(root / "doc.json", b"{", 0o600)),
        "special destination": (DIR, "special file refused", fifo),
        "symlinked document": (DOC, "non-regular destination refused", symlinked_document),
        "symlinked parent": (DIR, "symlinked or non-directory parent refused", linked_parent),
        "tsv encoding": (DIR, "malformed legacy ledger", lambda root, old: write(old / DIR["ledger"], b"\xff\t\n")),
    }
    for name, (ledger, message, damage) in sorted(cases.items()):
        root, old, state = tree(temporary, name)
        damage(root, old)
        try:
            engine.reconcile([], root, state, "prune", [ledger], old)
        except ValueError as error:
            assert message in str(error), (name, error)
        else:
            raise AssertionError(f"{name} accepted")
        assert owned(state) == {} and os.path.lexists(old / ledger["ledger"]), name
    print(f"PASS: {len(cases)} refusals leave state empty and the ledger in place")


def generated(fixture, bash, shim):
    for backend, prune in sorted(fixture.items()):
        assert LINK_STEP[backend] in prune["before"], prune["before"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            root.mkdir()
            environment = {key: value for key, value in os.environ.items() if key not in ("DRY_RUN", "XDG_STATE_HOME")}
            if backend == "hm":
                environment["HOME"] = str(root)
                old = root / ".local/state/nix-agentic-tools"
            else:
                environment.update(DEVENV_ROOT=str(root), DEVENV_STATE=temporary)
                old = Path(temporary) / "nix-agentic-tools"
            for name in ("gone.md", "kept.md"):
                write(root / "steering" / name, b"old\n")
            ledger = {"ledger": "materialize/steering.manifest"}
            write_ledger(old, ledger, {"gone.md": sha(b"old\n"), "kept.md": sha(b"old\n")})
            result = subprocess.run([bash, "-c", shim + "\n" + prune["command"]], env=environment,
                                    capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            assert list((root / "steering").iterdir()) == [], backend
            assert owned(old / "files2/ai.json") == {} and backups(old / "files2/ai.json") == []
            assert not (old / ledger["ledger"]).exists(), backend
    print(f"PASS: {len(fixture)} generated prunes import and retire old copies before linking")


with tempfile.TemporaryDirectory() as temporary:
    imports(temporary)
    drain(temporary)
    already_owned(temporary)
    refusals(temporary)
generated(json.loads(Path(sys.argv[2]).read_text()), sys.argv[3], Path(sys.argv[4]).read_text())

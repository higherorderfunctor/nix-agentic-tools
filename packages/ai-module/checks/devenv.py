"""Execute devenv file guard and copy phases on real temporary trees."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def run(bash, script, root, state, replacements, success=True):
    environment = os.environ.copy()
    environment.update(DEVENV_ROOT=str(root), DEVENV_STATE=str(state))
    for original, local in replacements.items():
        script = script.replace(original, str(local))
    result = subprocess.run([bash, "-c", script], env=environment, capture_output=True, text=True)
    assert (result.returncode == 0) == success, result.stderr
    return result.stderr


def main():
    fixture = json.loads(sys.stdin.read() if sys.argv[1] == "-" else Path(sys.argv[1]).read_text())
    bash = sys.argv[2]
    active = fixture["active"]
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        state = Path(temporary) / "state"
        root.mkdir()
        plan = root / "plan.json"
        empty_plan = root / "empty-plan.json"
        targets = root / "targets.json"
        plan.write_text(json.dumps(active["plan"]))
        empty_plan.write_text("[]")
        targets.write_text(json.dumps(active["links"]))
        replacements = {
            active["planPath"]: plan,
            active["targetPath"]: targets,
            fixture["empty"]["planPath"]: empty_plan,
        }
        ledger = state / "nix-agentic-tools/files/ai.json"
        run(bash, fixture["empty"]["prune"], root, state, {**replacements, fixture["python"]: "/missing"})
        assert fixture["python"] in fixture["empty"]["prune"] and not ledger.exists(), "prune without state started the engine"
        link = root / "links/a.txt"
        link.parent.mkdir()
        link.symlink_to("/nix/store/old-link")
        run(bash, active["prune"], root, state, replacements)
        run(bash, active["guard"], root, state, replacements)
        assert not link.is_symlink(), "stale store link was not removed"
        for relative, target in active["links"].items():
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.symlink_to(target)
        run(bash, active["guard"], root, state, replacements)
        (root / "provider").write_text("from-provider")
        run(bash, active["apply"], root, state, replacements)
        assert (root / "copy.txt").read_text() == "copy"
        assert (root / "secret").read_text() == "from-provider"
        assert link.is_symlink() and os.readlink(link) == active["links"]["links/a.txt"]
        assert list(json.loads(ledger.read_text())["files"]) == ["copy.txt", "secret"]
        native_state = state / "files.json"
        native_state.write_text(json.dumps({"managedFiles": list(active["links"])}))
        cleanup = fixture["cleanup"].replace("__ROOT__", str(root)).replace("__STATE__", str(state))
        run(bash, cleanup, root, state, replacements)
        assert not link.is_symlink() and not (root / "tree/b/c.md").is_symlink()
        assert json.loads(native_state.read_text()) == {"managedFiles": []}
        run(bash, fixture["empty"]["prune"], root, state, replacements)
        assert not (root / "copy.txt").exists(), "empty plan did not drain copy"
        assert not (root / "secret").exists(), "empty plan did not drain renderer"
        assert not ledger.exists()

        foreign = Path(temporary) / "foreign"
        link.parent.mkdir(exist_ok=True)
        (root / "copy.txt").write_text("unrelated")
        run(bash, active["guard"], root, state, replacements)
        (root / "copy.txt").unlink()
        link.symlink_to(foreign)
        assert "non-store link refused: links/a.txt" in run(bash, active["guard"], root, state, replacements, False)
        assert link.is_symlink()
        link.unlink()
        link.write_text("foreign")
        assert "native link destination refused: links/a.txt" in run(bash, active["guard"], root, state, replacements, False)
        assert link.read_text() == "foreign"
        link.unlink()
        os.mkfifo(link)
        assert "native link destination refused: links/a.txt" in run(bash, active["guard"], root, state, replacements, False)
        link.unlink()
        link.parent.rmdir()
        (root / "links").symlink_to(foreign)
        assert "symlinked or non-directory parent refused" in run(bash, active["guard"], root, state, replacements, False)
    print("PASS: stateless prune skip, native links, guard refusals, copy after linking, empty drain")


if __name__ == "__main__":
    main()

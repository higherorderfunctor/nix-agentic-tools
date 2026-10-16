"""Execute the generated devenv observer tasks on real temporary trees."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

LEDGER = "ai-delivery-observed.json"
# The option each observed path is reported under, by delivery path.
OPTIONS = {
    "moved.json": 'ai.codex.files2."moved.json"',
    "new.md": 'ai.codex.files2."new.md"',
    "tree/nested/deep/leaf.md": 'ai.files2."tree"',
}


def run(bash, phase, root, state, expect=()):
    environment = os.environ | {"DEVENV_ROOT": str(root), "DEVENV_STATE": str(state)}
    result = subprocess.run([bash, "-c", phase], env=environment, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    warnings = [line for line in result.stderr.splitlines() if line.startswith("WARNING:")]
    assert len(warnings) == len(expect), (expect, result.stderr)
    for needle in expect:
        assert needle in result.stderr, (needle, result.stderr)
    return result.stderr


def clear(target):
    if target.is_dir() and not target.is_symlink():
        target.rmdir()
    elif target.exists() or target.is_symlink():
        target.unlink()


def link(root, links):
    for name, target in links.items():
        destination = root / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        clear(destination)
        destination.symlink_to(target)


def main():
    fixture = json.loads(Path(sys.argv[1]).read_text())
    bash = sys.argv[2]
    before, after = fixture["before"], fixture["after"]
    assert set(OPTIONS) <= set(before["links"]), before["links"]
    with tempfile.TemporaryDirectory() as temporary:
        root, state = Path(temporary) / "root", Path(temporary) / "state"
        root.mkdir()
        state.mkdir()
        ledger = state / LEDGER

        # Snapshot keeps only owned names from devenv's previous link list.
        (state / "files.json").write_text(json.dumps({"managedFiles": ["new.md", "consumer.md", "unrelated"]}))
        run(bash, before["snapshot"], root, state)
        assert json.loads(ledger.read_text()) == {"new.md": {"option": OPTIONS["new.md"]}}

        # Delivered as declared: silent. Unclaimed native links are never inspected.
        link(root, before["links"])
        run(bash, before["inspect"], root, state)
        assert set(OPTIONS) <= set(json.loads(ledger.read_text())) and "consumer.md" not in json.loads(ledger.read_text())

        # Every path kind devenv can leave instead of the declared link.
        for name, option in OPTIONS.items():
            target = root / name
            for kind in ["absent", "file", "directory", "stale-link"]:
                clear(target)
                if kind == "file":
                    target.write_text("user content")
                elif kind == "directory":
                    target.mkdir()
                elif kind == "stale-link":
                    target.symlink_to("/nix/store/old")
                run(bash, before["inspect"], root, state, [f"{option} is set but devenv did not deliver {target}"])
            link(root, {name: before["links"][name]})

        # Retired: user content in place of each link is reported, kept, and
        # reported again. The engine's owned `moved.json` copy is not a removal.
        retired = [name for name in OPTIONS if name != "moved.json"]
        # What devenv cleanup does to the links `after` no longer declares.
        for name in set(before["links"]) - set(after["links"]):
            clear(root / name)
        assert "moved.json" not in after["links"], after["links"]
        for name in retired + ["moved.json"]:
            (root / name).write_text("user edit")
        link(root, after["links"])
        for _ in range(2):
            run(bash, after["inspect"], root, state, [f"{OPTIONS[name]} was removed but devenv retained {root / name}" for name in retired])
        assert all((root / name).read_text() == "user edit" for name in retired)
        for name in retired:
            (root / name).unlink()
        run(bash, after["inspect"], root, state)
        assert not set(retired) & set(json.loads(ledger.read_text()))

        # A malformed ledger is reported, never fatal.
        ledger.write_text("bad json")
        run(bash, after["inspect"], root, state, ["AI file delivery inspection failed"])

    # No AI configuration: both tasks exist, stay silent and write nothing.
    with tempfile.TemporaryDirectory() as temporary:
        root, state = Path(temporary) / "root", Path(temporary) / "state"
        root.mkdir()
        state.mkdir()
        run(bash, fixture["empty"]["snapshot"], root, state)
        run(bash, fixture["empty"]["inspect"], root, state)
        assert not (state / LEDGER).exists()
    print("PASS: observer snapshot, delivery and retirement warnings")


if __name__ == "__main__":
    main()

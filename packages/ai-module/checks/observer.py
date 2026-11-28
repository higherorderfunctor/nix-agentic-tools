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
    "moved.json": 'ai.codex.files."moved.json"',
    "new.md": 'ai.codex.files."new.md"',
    "tree/bin/tool": 'ai.files."tree"',
    "tree/nested/deep/leaf.md": 'ai.files."tree"',
}


def run(bash, phase, root, state, expect=()):
    environment = os.environ | {"DEVENV_ROOT": str(root), "DEVENV_STATE": str(state)}
    result = subprocess.run([bash, "-c", phase], env=environment, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    warnings = [line for line in result.stderr.splitlines() if line.startswith("WARNING:")]
    assert len(warnings) == len(expect), (expect, result.stderr)
    for needle in expect:
        assert any(line.startswith(f"WARNING: {needle}") for line in warnings), (needle, result.stderr)
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
    assert set(before["links"]) == {*OPTIONS, "consumer.md"}, before["links"]
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
        assert json.loads(ledger.read_text()) == {
            name: {"option": option, "source": before["links"][name]} for name, option in OPTIONS.items()
        }

        def missing_delivery(name):
            return f"{OPTIONS[name]} is set but devenv did not deliver {root / name}:"

        # Remove all links to verify every warning uses its own option and path.
        for name in OPTIONS:
            clear(root / name)
        run(bash, before["inspect"], root, state, [missing_delivery(name) for name in OPTIONS])
        link(root, before["links"])

        # The inspector uses the same link predicate for every path; exercise
        # a non-link and a wrong target beside the silent valid links.
        name = "new.md"
        target = root / name
        for kind in ("file", "stale-link"):
            clear(target)
            if kind == "file":
                target.write_text("user content")
            else:
                target.symlink_to("/nix/store/old")
            run(bash, before["inspect"], root, state, [missing_delivery(name)])
        link(root, {name: before["links"][name]})

        # Retired: the store link cleanup left behind is reported, kept, and
        # reported again. A path now in the engine plan is not a removal,
        # even if cleanup has not yet removed its old store link.
        retired = [name for name in OPTIONS if name != "moved.json"]
        assert set(after["links"]) == {"consumer.md"}, after["links"]
        # What devenv cleanup does to the links `after` no longer declares.
        for name in set(before["links"]) - set(after["links"]):
            clear(root / name)
        (root / "moved.json").symlink_to(before["links"]["moved.json"])
        for name in retired:
            (root / name).symlink_to(before["links"][name])
        link(root, after["links"])
        retirement_warnings = [
            f"{OPTIONS[name]} was removed but devenv left its store link at {root / name}:" for name in retired
        ]
        for _ in range(2):
            run(bash, after["inspect"], root, state, retirement_warnings)
            assert all(os.readlink(root / name) == before["links"][name] for name in retired)
            assert os.readlink(root / "moved.json") == before["links"]["moved.json"]
            assert set(json.loads(ledger.read_text())) == set(retired)
        # A snapshot-only entry knows no source: any store link is reported.
        ledger.write_text(json.dumps({name: {"option": OPTIONS[name]} for name in retired}))
        for name in retired:
            clear(root / name)
            (root / name).symlink_to("/nix/store/other")
        run(bash, after["inspect"], root, state, retirement_warnings)
        # Whatever the user put there, or nothing, is forgotten silently and kept.
        for kind in ["absent", "file", "directory", "other-store-link", "foreign-link"]:
            ledger.write_text(json.dumps({name: {"option": OPTIONS[name], "source": before["links"][name]} for name in retired}))
            for name in retired:
                clear(root / name)
                if kind == "file":
                    (root / name).write_text("user edit")
                elif kind == "directory":
                    (root / name).mkdir()
                elif kind == "other-store-link":
                    (root / name).symlink_to("/nix/store/other")
                elif kind == "foreign-link":
                    (root / name).symlink_to("../elsewhere")
            run(bash, after["inspect"], root, state)
            assert json.loads(ledger.read_text()) == {}, kind
            for name in retired:
                target = root / name
                if kind == "absent":
                    assert not target.exists() and not target.is_symlink(), name
                elif kind == "file":
                    assert target.read_text() == "user edit", name
                elif kind == "directory":
                    assert target.is_dir() and not target.is_symlink(), name
                else:
                    assert os.readlink(target) == ("/nix/store/other" if kind == "other-store-link" else "../elsewhere"), name
        for name in retired:
            clear(root / name)

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

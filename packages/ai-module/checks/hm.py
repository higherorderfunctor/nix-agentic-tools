"""Execute Home Manager activation entries across method switches."""

import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


def activate(bash, shim, script, home, dry_run=False):
    environment = os.environ.copy()
    environment["HOME"] = str(home)
    environment.pop("XDG_STATE_HOME", None)
    if dry_run:
        environment["DRY_RUN"] = "1"
    else:
        environment.pop("DRY_RUN", None)
    subprocess.run([bash, "-c", shim + "\n" + script], env=environment, check=True, capture_output=True, text=True)


def main():
    fixtures = json.loads(Path(sys.argv[1]).read_text())
    bash, shim = sys.argv[2], Path(sys.argv[3]).read_text()
    with tempfile.TemporaryDirectory() as temporary:
        home = Path(temporary)
        state = home / ".local/state/nix-agentic-tools/files2/fixture.json"
        destination = home / "settings.json"
        previous_link = None
        for generation, (method, fixture) in enumerate(zip(("symlink", "ro", "rw", "symlink", "symlink"), fixtures[:-1], strict=True)):
            activate(bash, shim, fixture["prune"], home)
            links = fixture["links"]
            if previous_link is not None:
                assert os.readlink(destination) == str(previous_link)
                if method == "ro":
                    try:
                        activate(bash, shim, fixture["apply"], home)
                    except subprocess.CalledProcessError as error:
                        assert "non-regular destination refused: settings.json" in error.stderr, error.stderr
                    else:
                        raise AssertionError("copy followed a native link")
                    assert os.readlink(destination) == str(previous_link)
                    assert json.loads(state.read_text())["files"] == {}
                destination.unlink()
                previous_link = None
            if links:
                generation_file = home / f"generation-{generation}" / "home-files" / "settings.json"
                generation_file.parent.mkdir(parents=True)
                generation_file.write_bytes(Path(links["settings.json"]).read_bytes())
                generation_file.chmod(0o555)
                destination.symlink_to(generation_file)
                previous_link = generation_file
            activate(bash, shim, fixture["apply"], home)
            records = json.loads(state.read_text())["files"]
            if method == "symlink":
                assert destination.is_symlink() and os.readlink(destination) == str(generation_file)
                assert records == {}, records
                assert stat.S_IMODE(destination.stat().st_mode) == 0o555
            else:
                assert records["settings.json"]["method"] == method, records
                assert destination.is_file() and not destination.is_symlink()
                assert json.loads(destination.read_text()) == {"owned": 1}
                assert stat.S_IMODE(destination.stat().st_mode) == (0o555 if method == "ro" else 0o700)
        activate(bash, shim, fixtures[-1]["prune"], home, dry_run=True)
        assert destination.is_symlink(), "dry-run removed native link"
        activate(bash, shim, fixtures[-1]["prune"], home)
        destination.unlink()
        activate(bash, shim, fixtures[-1]["apply"], home)
        assert not destination.exists() and not destination.is_symlink()
        assert json.loads(state.read_text())["files"] == {}
        print("PASS: generated prune/apply symlink → ro → rw → symlink → new generation → empty and dry-run")


if __name__ == "__main__":
    main()

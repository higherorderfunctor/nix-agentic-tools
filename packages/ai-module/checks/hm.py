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
        state = home / ".local/state/nix-agentic-tools/files2/ai.json"
        destination = home / "settings.json"
        previous_link = None
        missing = [script.replace(fixtures["python"], "/missing") for script in fixtures["drain"]]
        assert missing != fixtures["drain"], "prune does not name the engine python"
        for script in missing:
            activate(bash, shim, script, home)
        assert not state.exists(), "prune without state started the engine"
        outside = home / "outside"
        outside.mkdir()
        (home / "linked").symlink_to(outside)
        try:
            activate(bash, shim, fixtures["nested"], home)
        except subprocess.CalledProcessError as error:
            assert "symlinked or non-directory parent refused" in error.stderr, error.stderr
        else:
            raise AssertionError("nonempty prune without state skipped the parent check")
        assert not list(outside.iterdir()) and not state.exists()
        (home / "linked").unlink()
        outside.rmdir()
        for generation, (method, fixture) in enumerate(zip(("symlink", "ro", "rw", "symlink", "symlink", "ro"), fixtures["generations"], strict=True)):
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
                    assert not state.exists()
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
            if method == "symlink":
                assert destination.is_symlink() and os.readlink(destination) == str(generation_file)
                assert not state.exists()
                assert stat.S_IMODE(destination.stat().st_mode) == 0o555
            else:
                records = json.loads(state.read_text())["files"]
                assert records["settings.json"]["method"] == method, records
                assert destination.is_file() and not destination.is_symlink()
                assert json.loads(destination.read_text()) == {"owned": 1}
                assert stat.S_IMODE(destination.stat().st_mode) == (0o555 if method == "ro" else 0o700)
        assert destination.is_file() and not destination.is_symlink()
        before = state.read_bytes()
        for script in fixtures["drain"]:
            activate(bash, shim, script, home, dry_run=True)
        assert destination.is_file() and state.read_bytes() == before, "dry run mutated copy or state"
        for script in fixtures["drain"]:
            activate(bash, shim, script, home)
        assert not destination.exists() and not state.exists()

        for phase in ("prune", "apply"):
            activate(bash, shim, fixtures["generations"][-1][phase], home)
        assert destination.is_file()
        for script in fixtures["disabled"]:
            activate(bash, shim, script, home)
        assert not destination.exists() and not state.exists(), "disabled owner did not drain"

        for phase in ("prune", "apply"):
            activate(bash, shim, fixtures["generations"][-1][phase], home)
        assert destination.is_file()
        for script in fixtures["forcedDrain"]:
            activate(bash, shim, script, home)
        assert not destination.exists() and not state.exists(), "forced empty activation did not drain"

        provider = home / "provider"
        provider.write_text("from-provider")
        for script in fixtures["run"]:
            activate(bash, shim, script, home)
        assert (home / "secret").read_text() == "from-provider"
        assert json.loads(state.read_text())["files"]["secret"]["method"] == "ro"
        print("PASS: HM stateless prune skip, symlinked parent refusal, transitions, empty, disabled and forced drain, dry run, provider render")


if __name__ == "__main__":
    main()

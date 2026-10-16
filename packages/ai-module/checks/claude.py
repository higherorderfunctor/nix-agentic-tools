"""Execute Claude's real HM engine phases and credential repair on disk."""

import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

DATA = json.loads(Path(sys.argv[1]).read_text())
SHIM = Path(sys.argv[2]).read_text()
DOCUMENT = ".claude.json"
HEADER = "// Runtime state\n"
NATIVE = {"oauthAccount": {"token": "native-test-token"}, "unpinNativeLaunchEffort": True}


def snapshot(path):
    return path.read_bytes(), stat.S_IMODE(path.stat().st_mode), path.stat().st_mtime_ns


class Home:
    def __init__(self, directory, use_xdg):
        self.root = directory / "home"
        self.root.mkdir()
        self.document = self.root / DOCUMENT
        self.environment = {key: value for key, value in os.environ.items() if key not in ("DRY_RUN", "XDG_STATE_HOME")}
        self.environment["HOME"] = str(self.root)
        state = directory / "state" if use_xdg else self.root / ".local/state"
        if use_xdg:
            self.environment["XDG_STATE_HOME"] = str(state)
        self.old = state / "nix-agentic-tools"
        self.state = self.old / "files/ai.json"
        self.ledger = self.old / DATA["legacy"]["ledger"]
        self.directory = directory

    def write(self, value, mode=0o600):
        self.document.write_text(HEADER + json.dumps(value))
        self.document.chmod(mode)

    def read(self):
        return json.loads(self.document.read_text().removeprefix(HEADER))

    def records(self):
        return json.loads(self.state.read_text())["files"]

    def activate(self, index=0, disabled=False, succeeds=True, mode_only=False, dry=False):
        step = DATA["fixture"][index]["disabled" if disabled else "enabled"]
        plan = copy.deepcopy(step["plan"])
        for offset, item in enumerate(plan):
            if "rendered" in item["content"]:
                rendered = self.directory / f"rendered-{offset}"
                rendered.write_text(json.dumps(item["content"]["value"]))
                item["content"]["rendered"] = str(rendered)
        local = self.directory / "plan.json"
        local.write_text(json.dumps(plan))
        body = step["mode"] if mode_only else "\n".join(step["scripts"] + [step["mode"]])
        body = body.replace(step["planFile"], str(local))
        # Substitution only: CI uses these same generated bodies with store
        # inputs. Local runs use the shell's Python and identical plan values.
        body = re.sub(r"/nix/store/[^\s]+/bin/python3", sys.executable, body)
        script = 'before_flags=$-\nbefore_options=$(set +o)\n' + SHIM + body + '\ntest "$before_flags" = "$-"\ntest "$before_options" = "$(set +o)"\necho later-entry-ran\n'
        environment = {**self.environment, **({"DRY_RUN": "1"} if dry else {})}
        result = subprocess.run([DATA["bash"], "-e", "-c", script], env=environment, capture_output=True, text=True)
        assert (result.returncode == 0) == succeeds, result.stderr
        if succeeds:
            assert "later-entry-ran" in result.stdout

    def check(self, declared, created=True):
        assert self.read() == {**NATIVE, **declared}, self.read()
        assert self.document.read_text().startswith(HEADER)
        assert stat.S_IMODE(self.state.stat().st_mode) == 0o600
        record = self.records()[DOCUMENT]
        assert record["method"] == "rw" and record["format"] == "json" and record["created"] == created
        assert record["keys"] == {f"/{key}": hashlib.sha256(json.dumps(["bool", value], separators=(",", ":")).encode()).hexdigest() for key, value in declared.items()}
        assert record["digest"] == hashlib.sha256(self.document.read_bytes()).hexdigest()


def generations(directory, mode, use_xdg):
    home = Home(directory, use_xdg)
    home.activate(2)
    assert not home.document.exists() and not home.state.exists()
    home.document.write_text("externally managed, not JSON\n")
    home.document.chmod(mode)
    before = snapshot(home.document)
    home.activate(2)
    assert snapshot(home.document)[0] == before[0] and not home.state.exists()
    assert stat.S_IMODE(home.document.stat().st_mode) == mode & 0o700
    home.document.unlink()
    home.activate(dry=True)
    assert not home.document.exists() and not home.state.exists()
    home.activate()
    assert home.read() == DATA["fixture"][0]["settings"] and stat.S_IMODE(home.document.stat().st_mode) == 0o600
    home.write({**NATIVE, "first": False, "second": False}, mode)
    home.activate()
    home.check(DATA["fixture"][0]["settings"])
    assert stat.S_IMODE(home.document.stat().st_mode) == mode & 0o700
    home.activate(1)
    home.check(DATA["fixture"][1]["settings"])
    os.utime(home.document, ns=(1000000000, 1000000000))
    os.utime(home.state, ns=(1000000000, 1000000000))
    before = snapshot(home.document), snapshot(home.state)[:2]
    home.activate(1)
    assert (snapshot(home.document), snapshot(home.state)[:2]) == before
    for malformed in ("{", "[]", "null"):
        home.document.unlink()
        home.document.write_text(malformed)
        home.document.chmod(mode & 0o700)
        damaged = snapshot(home.document), snapshot(home.state)[:2]
        home.activate(1, succeeds=False)
        assert (snapshot(home.document), snapshot(home.state)[:2]) == damaged
    home.document.unlink()
    home.document.write_bytes(before[0][0])
    home.document.chmod(mode & 0o700)
    home.state.write_text('{"version": 1, "files": {".claude.json": {}}}')
    damaged = snapshot(home.document), snapshot(home.state)[:2]
    home.activate(1, succeeds=False)
    assert (snapshot(home.document), snapshot(home.state)[:2]) == damaged
    home.state.write_bytes(before[1][0])
    home.activate(2)
    assert home.read() == NATIVE and not home.state.exists()
    before = snapshot(home.document)
    home.activate(2)
    assert snapshot(home.document) == before
    assert stat.S_IMODE(home.state.parent.stat().st_mode) == 0o700
    assert not list(home.root.glob(".files-*"))


def adoption(directory, existing_directory, use_xdg):
    home = Home(directory, use_xdg)
    if existing_directory:
        home.state.parent.mkdir(parents=True)
        home.state.parent.chmod(0o755)
    home.write(NATIVE, 0o644)
    before = snapshot(home.document)
    home.activate()
    home.check(DATA["fixture"][0]["settings"], created=False)
    assert stat.S_IMODE(home.document.stat().st_mode) == 0o600
    backups = list(home.state.parent.glob("*.bak"))
    assert len(backups) == 1
    assert snapshot(backups[0])[:2] == before[:2]
    assert stat.S_IMODE(home.state.parent.stat().st_mode) == 0o700
    # Repair a widened existing directory even when no new backup is needed.
    home.state.parent.chmod(0o755)
    home.activate()
    assert stat.S_IMODE(home.state.parent.stat().st_mode) == 0o700
    assert list(home.state.parent.glob("*.bak")) == backups
    assert snapshot(backups[0])[:2] == before[:2]


def legacy(directory, disabled):
    home = Home(directory, False)
    home.write({**NATIVE, "first": False, "retired": True}, 0o644 if disabled else 0o600)
    home.ledger.parent.mkdir(parents=True)
    ledger = {"managed_paths": [["first"], ["retired"]], "version": 1}
    home.ledger.write_text(json.dumps(ledger))
    home.activate(disabled=disabled)
    assert not home.ledger.exists()
    if disabled:
        assert home.read() == NATIVE and not home.state.exists()
        assert stat.S_IMODE(home.document.stat().st_mode) == 0o644
    else:
        home.check(DATA["fixture"][0]["settings"], created=False)
        # A restored legacy ledger cannot reclaim an engine-native key.
        ledger["managed_paths"] = [["unpinNativeLaunchEffort"]]
        home.ledger.write_text(json.dumps(ledger))
        before = snapshot(home.state)[:2]
        home.activate()
        assert not home.ledger.exists() and snapshot(home.state)[:2] == before
        home.activate(disabled=True)
        assert home.read() == NATIVE and not home.state.exists()
    print(f"PASS: legacy import once and disabled drain ({disabled})")


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    os.umask(0)
    for mode in (0o400, 0o600, 0o640, 0o644):
        for use_xdg in (False, True):
            directory = root / f"generations-{mode:o}-{use_xdg}"
            directory.mkdir()
            generations(directory, mode, use_xdg)
    print("PASS: 8 HM generation cases: restore, retire, native keys, mode, dry run, invalid disk/state, repeat")
    os.umask(0o022)
    for existing_directory in (False, True):
        for use_xdg in (False, True):
            directory = root / f"adoption-{existing_directory}-{use_xdg}"
            directory.mkdir()
            adoption(directory, existing_directory, use_xdg)
    print("PASS: 4 credential adoption cases: private new/existing directory, preserved backup bytes/mode, repeat repair")
    os.umask(0)
    for disabled in (False, True):
        directory = root / f"legacy-{disabled}"
        directory.mkdir()
        legacy(directory, disabled)
    home = Home(root, False)
    home.activate(2, mode_only=True)
    linked = home.root / "linked.json"
    linked.write_text("{}")
    linked.chmod(0o644)
    home.document.symlink_to(linked)
    home.activate(2)
    assert stat.S_IMODE(linked.stat().st_mode) == 0o644 and not home.state.exists()
    print("PASS: mode repair skips missing files and symlinks")

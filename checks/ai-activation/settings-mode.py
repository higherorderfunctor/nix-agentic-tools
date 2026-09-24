"""The activation merge must not widen a credential file.

Each case asserts on what is on disk afterwards, and names itself on failure so
whoever trips it learns which property broke rather than just "600".
"""

# cspell:ignore natcreds  (test-scaffold token, not project vocabulary)

import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

TOOLS = json.loads(Path(sys.argv[1]).read_text())
DOCUMENT = ".natcreds/config.json"
DECLARED = {"declared": "from-nix"}


def fail(label, message):
    raise SystemExit(f"FAIL [{label}]: {message}")


def mode_of(path):
    return stat.S_IMODE(path.stat().st_mode)


def assert_mode(path, expected, label):
    got = mode_of(path)
    if got != expected:
        fail(label, f"expected mode {expected:o}, got {got:o}\n  file: {path}")


class Home:
    """One temporary HOME, laid out the way Home Manager activation sees it."""

    def __init__(self, parent, name):
        self.root = Path(parent) / name
        self.root.mkdir()
        self.state = self.root / ".local/state/nix-agentic-tools"
        self.document = self.root / DOCUMENT
        self.environment = dict(
            os.environ,
            HOME=str(self.root),
            NAT_OWN_ROOT=str(self.root),
            NAT_OWN_STATE=str(self.state),
        )

    def seed(self, value, mode):
        self.document.parent.mkdir(parents=True, exist_ok=True)
        self.document.write_text(json.dumps(value))
        self.document.chmod(mode)

    def plan(self, units):
        path = self.root.parent / f"{self.root.name}-plan.json"
        path.write_text(
            json.dumps(
                {
                    "bash": TOOLS["bash"],
                    "targets": [
                        {
                            "codec": "json",
                            "ledger": "json-settings/natcreds.json",
                            "path": DOCUMENT,
                            "units": units,
                        }
                    ],
                }
            )
        )
        return path

    def own(self, units):
        result = subprocess.run(
            [TOOLS["python"], TOOLS["own"], "--plan", str(self.plan(units))],
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode != 0:
            fail(self.root.name, f"own.py exited {result.returncode}: {result.stderr}")

    def read(self):
        return json.loads(self.document.read_text())


def created(parent):
    """1. A file the activation CREATES must not be world-readable."""
    home = Home(parent, "created")
    home.own({"text": json.dumps(DECLARED)})
    assert_mode(home.document, 0o600, "newly created file")


def existing(parent):
    """2. The regression itself: an EXISTING 0600 credential file must keep its
    mode, and must still be merged rather than clobbered."""
    home = Home(parent, "existing")
    home.seed({"apiKey": "secret"}, 0o600)
    home.own({"text": json.dumps(DECLARED)})
    assert_mode(home.document, 0o600, "existing credential file must not be widened")
    if home.read() != {"apiKey": "secret", **DECLARED}:
        fail("existing", f"merge lost the runtime value or the declared value: {home.read()}")


def discrimination(parent):
    """3. If the mode knob were inert, cases 1 and 2 would pass no matter what
    the writer did, so this proves it is live and that the assertion can tell
    600 from 644."""
    home = Home(parent, "explicit")
    home.own({"mode": "0644", "text": json.dumps(DECLARED)})
    assert_mode(home.document, 0o644, "explicit mode must be honoured")


def main():
    with tempfile.TemporaryDirectory() as parent:
        for case in (created, existing, discrimination):
            case(parent)
    print("PASS: ai-activation settings mode")


if __name__ == "__main__":
    main()

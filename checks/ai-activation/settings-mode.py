"""The activation merge must not widen a credential file.

Each case asserts on what is on disk afterwards, and names itself on failure so
whoever trips it learns which property broke rather than just "600".
"""

# cspell:ignore natcreds  (test-scaffold token, not project vocabulary)

import contextlib
import importlib.util
import io
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


def load_own():
    """own.py as a module, so a case can interpose on its compare step."""
    spec = importlib.util.spec_from_file_location("own", TOOLS["own"])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def race(parent, repeated):
    """4. One racing write must survive a successful retry. Continuous writes
    must exhaust the bound loudly without replacing runtime data.

    The runtime's write lands at the compare step itself: own.py has already
    merged the old runtime values into a complete temporary, but has not yet
    renamed it over the destination. That is the lost-update window.
    """
    label = f"{'repeated' if repeated else 'once'} race"
    home = Home(parent, label.replace(" ", "-"))
    home.seed({"deviceId": "device-0", "gitTokens": {"host": "token-0"}}, 0o600)
    own = load_own()
    identity = own.file_identity
    writes = 0

    def racing_identity(path):
        nonlocal writes
        if path == home.document and (writes == 0 or repeated):
            writes += 1
            # Same size and timestamps, different content and inode: this
            # models a runtime's sibling-temporary rename, and discriminates
            # against an mtime-based identity.
            handle, sibling = tempfile.mkstemp(
                dir=home.document.parent, prefix=f"{home.document.name}.writer."
            )
            with os.fdopen(handle, "w") as stream:
                json.dump({"deviceId": f"device-{writes}", "gitTokens": {"host": f"token-{writes}"}}, stream)
            before = home.document.stat()
            os.utime(sibling, ns=(before.st_atime_ns, before.st_mtime_ns))
            os.replace(sibling, home.document)
        return identity(path)

    own.file_identity = racing_identity
    arguments = ["own.py", "--plan", str(home.plan({"text": json.dumps(DECLARED)}))]
    stderr = io.StringIO()
    status = 0
    with contextlib.ExitStack() as scope:
        scope.enter_context(contextlib.redirect_stderr(stderr))
        saved = dict(os.environ), sys.argv
        scope.callback(lambda: (os.environ.clear(), os.environ.update(saved[0])))
        scope.callback(setattr, sys, "argv", saved[1])
        os.environ.update(home.environment)
        sys.argv = arguments
        try:
            own.main()
        except SystemExit as exit_:
            status = exit_.code or 0

    document = home.read()
    if document.get("deviceId") != f"device-{writes}" or document.get("gitTokens") != {"host": f"token-{writes}"}:
        fail(label, f"activation lost the concurrent deviceId/gitTokens write: {document}")
    # In the repeated race the runtime's rename lands last, so this does not
    # re-test the temporary's mode (cases 1 and 2 do). It guards the refusal
    # path: activation must not widen the destination before it gives up.
    assert_mode(home.document, 0o600, label)
    leftovers = [path.name for path in home.document.parent.iterdir() if ".nat-tmp." in path.name]
    if leftovers:
        fail(label, f"temporaries left behind: {leftovers}")
    ledger = home.state / "json-settings/natcreds.json"
    if repeated:
        expected = (
            f"own: {home.document} changed during all 3 attempts; refusing to "
            "overwrite concurrent runtime changes; retry activation\n"
        )
        if status != 1 or writes != 3 or stderr.getvalue() != expected:
            fail(label, f"expected a loud refusal after 3 attempts, got status {status}, {writes} writes, stderr {stderr.getvalue()!r}")
        if "declared" in document:
            fail(label, "activation overwrote the runtime's final write")
        if ledger.exists():
            fail(label, "the ledger claims a leaf that never landed")
    else:
        if status != 0 or writes != 1:
            fail(label, f"expected one retry to succeed, got status {status}, {writes} writes, stderr {stderr.getvalue()!r}")
        if document.get("declared") != "from-nix":
            fail(label, f"the retry dropped the declared leaf: {document}")


def activate(home, gate, label):
    """Run one gate state's merge and mode entries of the real modules."""
    result = subprocess.run(
        [TOOLS["bash"], TOOLS["gates"][gate]["script"]],
        env=home.environment,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        fail(label, f"activation exited {result.returncode}: {result.stderr}")


def merged(runtime, declared):
    """`runtime` with every declared leaf laid over it."""
    result = dict(runtime)
    for key, value in declared.items():
        result[key] = merged(result.get(key, {}), value) if isinstance(value, dict) else value
    return result


def widened(parent, gate):
    """5. A credential file an earlier generation widened to 0644 must end up
    0600 in both gate states. `own.py` keeps the mode it finds, and runtimes
    keep it on their own rewrites, so nothing else would ever close it again.

    Open: the merge rewrites the file, keeps the runtime's keys and adds the
    declared leaves. Closed: the merge runs with nothing declared and the file
    must come out byte-identical.
    """
    label = f"gate {gate}"
    home = Home(parent, f"gate-{gate}")
    runtime = {"token": "secret"}
    documents = TOOLS["gates"][gate]["documents"]
    for name in documents:
        path = home.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(runtime))
        path.chmod(0o644)
    activate(home, gate, label)
    for name, declared in documents.items():
        path = home.root / name
        if mode_of(path) != 0o600:
            fail(label, f"~/{name} left at mode {mode_of(path):o}, expected 600")
        if declared:
            if json.loads(path.read_text()) != merged(runtime, declared):
                fail(label, f"~/{name} is not the runtime's keys plus the declared leaves: {path.read_text()!r}")
        # Narrowing must not rewrite what the runtime wrote.
        elif path.read_text() != json.dumps(runtime):
            fail(label, f"~/{name} was rewritten: {path.read_text()!r}")


def guarded(parent):
    """6. The narrowing is guarded: a missing file must not fail activation,
    and a symlink (a Home Manager store link, say) is not ours to chmod."""
    home = Home(parent, "guarded")
    linked = home.root / "linked.json"
    linked.write_text("{}")
    linked.chmod(0o644)
    (home.root / ".claude.json").symlink_to("linked.json")
    activate(home, "closed", "guards")
    if mode_of(linked) != 0o644:
        fail("symlink", f"activation changed a symlink target's mode to {mode_of(linked):o}")


def main():
    with tempfile.TemporaryDirectory() as parent:
        for case in (created, existing, discrimination):
            case(parent)
        for repeated in (False, True):
            race(parent, repeated)
        for gate in ("open", "closed"):
            widened(parent, gate)
        guarded(parent)
    print("PASS: ai-activation settings mode")


if __name__ == "__main__":
    main()

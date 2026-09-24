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
import signal
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

TOOLS = json.loads(Path(sys.argv[1]).read_text())
DOCUMENT = ".natcreds/config.json"
DECLARED = {"declared": "from-nix"}
# The bound on one in-process run of own.py against a racing writer.
RETRY_BOUND_SECONDS = 10


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
    """own.py as a module, so a case can interpose on the calls it makes."""
    spec = importlib.util.spec_from_file_location("own", TOOLS["own"])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Unbounded(BaseException):
    """The alarm's exception. A BaseException, so neither own.py's error
    handler nor the SystemExit handler below can swallow it."""


def runtime_write(document, value):
    """A runtime's own write: a sibling temporary renamed over the document.

    It keeps the timestamps it replaces, so an mtime-based identity cannot see
    it, and it takes none of own.py's locks, as neither Claude Code nor Kimchi
    does.
    """
    handle, sibling = tempfile.mkstemp(dir=document.parent, prefix=f"{document.name}.writer.")
    with os.fdopen(handle, "w") as stream:
        json.dump(value, stream)
    before = document.stat()
    os.utime(sibling, ns=(before.st_atime_ns, before.st_mtime_ns))
    os.replace(sibling, document)


def publishing(document, descriptor):
    """Whether `descriptor` is open on one of own.py's reserved temporaries for
    `document`: the `.nat-tmp.` name its sweep, and this check's leftover
    assertion, already rely on."""
    opened = os.fstat(descriptor)
    return any(
        os.path.samestat(opened, candidate.stat())
        for candidate in document.parent.glob(f".{document.name}.nat-tmp.*")
    )


def own_in_process(own, home, units, label, interpose):
    """Run own.py's main in this process with `interpose` applied.

    `interpose` is a list of `(owner, name, make)`: `owner.name` is replaced by
    `make(original)` for the run and restored after it. The run is bounded by
    an alarm, because against a writer that never stops, a retry loop without
    a bound would hang the build instead of failing it by name. Returns
    `(status, stderr)`.
    """
    stderr = io.StringIO()
    status = 0
    with contextlib.ExitStack() as scope:
        for owner, name, make in interpose:
            original = getattr(owner, name)
            setattr(owner, name, make(original))
            scope.callback(setattr, owner, name, original)
        scope.enter_context(contextlib.redirect_stderr(stderr))
        saved = dict(os.environ), sys.argv
        scope.callback(lambda: (os.environ.clear(), os.environ.update(saved[0])))
        scope.callback(setattr, sys, "argv", saved[1])
        os.environ.update(home.environment)
        sys.argv = ["own.py", "--plan", str(home.plan(units))]

        def expire(_signal, _frame):
            raise Unbounded

        scope.callback(signal.signal, signal.SIGALRM, signal.signal(signal.SIGALRM, expire))
        signal.alarm(RETRY_BOUND_SECONDS)
        scope.callback(signal.alarm, 0)
        try:
            own.main()
        except SystemExit as exit_:
            status = exit_.code or 0
        except Unbounded:
            fail(label, f"own.py was still publishing after {RETRY_BOUND_SECONDS} s against a writer that never stops: its retry is unbounded")
    return status, stderr.getvalue()


def race(parent, repeated):
    """4. One racing write must survive a successful retry. Continuous writes
    must exhaust the bound loudly without replacing runtime data.

    The runtime's write lands in the lost-update window: own.py has merged the
    old runtime values into a complete temporary and synced it, but has not yet
    renamed it over the destination. It is injected at that fsync, a call the
    writer makes with or without a compare step. So a writer with no compare
    shows the lost update itself, and so does one that compares anywhere
    earlier than just before the rename.
    """
    label = f"{'repeated' if repeated else 'once'} race"
    home = Home(parent, label.replace(" ", "-"))
    home.seed({"deviceId": "device-0", "gitTokens": {"host": "token-0"}}, 0o600)
    own = load_own()
    writes = 0

    def racing_fsync(fsync):
        def hooked(descriptor):
            nonlocal writes
            fsync(descriptor)
            if (writes == 0 or repeated) and publishing(home.document, descriptor):
                writes += 1
                # Same size, different content and inode.
                runtime_write(
                    home.document,
                    {"deviceId": f"device-{writes}", "gitTokens": {"host": f"token-{writes}"}},
                )

        return hooked

    status, stderr = own_in_process(
        own, home, {"text": json.dumps(DECLARED)}, label, [(os, "fsync", racing_fsync)]
    )

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
        if status != 1 or writes != 3 or stderr != expected:
            fail(label, f"expected a loud refusal after 3 attempts, got status {status}, {writes} writes, stderr {stderr!r}")
        if "declared" in document:
            fail(label, "activation overwrote the runtime's final write")
        if ledger.exists():
            fail(label, "the ledger claims a leaf that never landed")
    else:
        if status != 0 or writes != 1:
            fail(label, f"expected one retry to succeed, got status {status}, {writes} writes, stderr {stderr!r}")
        if document.get("declared") != "from-nix":
            fail(label, f"the retry dropped the declared leaf: {document}")


def retiring_race(parent):
    """7. Retiring a document must not delete a runtime's write.

    The document holds only the leaf the ledger owns, and the declaration is
    now empty, so own.py retracts that leaf and deletes the file, which is all
    ours. The runtime adds a token after the load and before the delete: the
    file is no longer all ours, and deleting it would take the token with it.
    The write is injected at the sweep of the document's directory, the call
    own.py makes on its way to the delete whether or not it compares first.
    """
    label = "retiring race"
    home = Home(parent, "retiring-race")
    home.seed(DECLARED, 0o600)
    ledger = home.state / "json-settings/natcreds.json"
    ledger.parent.mkdir(parents=True)
    ledger.write_text(json.dumps({"managed_paths": [list(DECLARED)], "version": 1}))
    own = load_own()
    token = {"gitTokens": {"host": "token-1"}}
    writes = 0

    def racing_sweep(sweep):
        def hooked(directory):
            nonlocal writes
            if writes == 0 and directory == home.document.parent:
                writes += 1
                runtime_write(home.document, {**DECLARED, **token})
            sweep(directory)

        return hooked

    status, stderr = own_in_process(own, home, {}, label, [(own, "sweep", racing_sweep)])

    if writes != 1:
        fail(label, f"the runtime's write was never injected ({writes} writes)")
    if not home.document.exists():
        fail(label, "activation deleted the document a runtime had just rewritten, and its token with it")
    if status != 0 or home.read() != token:
        fail(label, f"expected the owned leaf retracted and the token kept, got status {status}, {home.read()}, stderr {stderr!r}")
    assert_mode(home.document, 0o600, label)
    if ledger.exists():
        fail(label, "the ledger still claims the retracted leaf")


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
        retiring_race(parent)
    print("PASS: ai-activation settings mode")


if __name__ == "__main__":
    main()

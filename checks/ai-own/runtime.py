"""Drive lib/ai/own.py directly: hand-written plans, observable filesystem.

Every case asserts on what is on disk afterwards — bytes, mode, inode identity,
which ledgers exist — rather than on anything the program reports about itself.
The `legacy` case is the load-bearing one: it makes TODAY's writers produce the
two ledgers and proves own.py reads and prunes from them, which is the control
for the claim that this rewrite needs no migration code.
"""

import fcntl
import hashlib
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

TOOLS = {}
WHOLE = json.dumps({"mcpServers": {"alpha": {"url": "https://alpha.invalid"}}}, indent=2) + "\n"
SERVERS = {"alpha": {"url": "https://alpha.invalid"}}


# ── Harness ─────────────────────────────────────────────────────────


class Fixture:
    """One temporary backend root plus the state root beside it."""

    def __init__(self, directory):
        self.root = Path(directory) / "root"
        self.devenv_state = Path(directory) / "state"
        self.state = self.devenv_state / "nix-agentic-tools"
        self.plans = Path(directory) / "plans"
        self.root.mkdir()
        self.plans.mkdir()
        self.serial = 0
        self.environment = dict(
            os.environ,
            DEVENV_ROOT=str(self.root),
            DEVENV_STATE=str(self.devenv_state),
            NAT_OWN_ROOT=str(self.root),
            NAT_OWN_STATE=str(self.state),
        )

    def plan_file(self, plan):
        self.serial += 1
        path = self.plans / f"plan-{self.serial}.json"
        path.write_text(json.dumps(plan))
        return path

    def command(self, plan, *arguments, python=None):
        return [
            python or TOOLS["python"],
            TOOLS["own"],
            "--plan",
            str(self.plan_file(plan)),
            *arguments,
        ]

    def own(self, plan, *arguments, succeeds=True, python=None):
        result = subprocess.run(
            self.command(plan, *arguments, python=python),
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert (result.returncode == 0) == succeeds, (
            result.returncode,
            result.stdout,
            result.stderr,
        )
        return result

    def ledger(self, name):
        return self.state / name

    def backups(self, name="materialize"):
        return sorted((self.state / name).glob("*.bak/*"))


def snapshot(path):
    info = path.stat()
    return path.read_bytes(), stat.S_IMODE(info.st_mode), info.st_mtime_ns


def identity(path):
    info = path.lstat()
    return info.st_dev, info.st_ino


def wait_for(predicate, message):
    deadline = time.monotonic() + 30
    while not predicate():
        assert time.monotonic() < deadline, message
        time.sleep(0.005)


# ── Plan shapes ─────────────────────────────────────────────────────


def dir_target(units, path="settings", ledger="materialize/settings.manifest"):
    return {"codec": "dir", "ledger": ledger, "path": path, "units": units}


def doc_target(units, codec="json", path="settings/mcp.json", ledger="json-settings/mcp.json"):
    return {"codec": codec, "ledger": ledger, "path": path, "units": units}


def mcp_plan(mode, servers):
    """The kiro bundle of design §2: both targets, always, in a fixed order."""
    return {
        "targets": [
            dir_target(
                {"mcp.json": {"mode": "0444", "text": WHOLE}}
                if mode == "overwrite" and servers
                else {}
            ),
            doc_target(
                {"text": json.dumps({"mcpServers": servers})} if mode == "merge" else {}
            ),
        ]
    }


# ── Cases ───────────────────────────────────────────────────────────


def transitions(fixture):
    """The four mcp transition cells of design §2, each from a fresh write."""
    config = fixture.root / "settings/mcp.json"
    whole = fixture.ledger("materialize/settings.manifest")
    leaves = fixture.ledger("json-settings/mcp.json")

    def overwritten():
        for ledger in (whole, leaves):
            ledger.unlink(missing_ok=True)
        config.unlink(missing_ok=True)
        fixture.own(mcp_plan("overwrite", SERVERS))
        assert config.read_text() == WHOLE and whole.is_file() and not leaves.exists()

    # overwrite -> merge: the whole-file claim is RELEASED. No backup, no
    # delete, the mode survives, and a hand edit survives with it.
    overwritten()
    native = json.loads(config.read_text())
    native["mcpServers"]["hand"] = {"url": "https://hand.invalid"}
    config.chmod(0o644)
    config.write_text(json.dumps(native))
    config.chmod(0o444)
    fixture.own(mcp_plan("merge", SERVERS))
    assert json.loads(config.read_text()) == {"mcpServers": dict(SERVERS, **{"hand": native["mcpServers"]["hand"]})}
    assert not whole.exists() and leaves.is_file()
    assert stat.S_IMODE(config.stat().st_mode) == 0o444
    assert not fixture.backups()
    print("PASS transitions: overwrite -> merge released the file claim")

    # merge -> overwrite: the leaves are retracted FIRST, then the directory
    # write adopts the file it did not record, backing it up.
    fixture.own(mcp_plan("overwrite", SERVERS))
    assert config.read_text() == WHOLE and whole.is_file() and not leaves.exists()
    assert len(fixture.backups()) == 1
    print("PASS transitions: merge -> overwrite retracted then adopted")

    # overwrite -> empty merge: RELEASED, because the producer is the claim
    # even when it resolves to zero leaves.
    overwritten()
    before = snapshot(config)
    fixture.own(mcp_plan("merge", {}))
    assert snapshot(config) == before, "an empty merge rewrote the co-owned file"
    assert not whole.exists() and not leaves.exists()
    print("PASS transitions: overwrite -> empty merge released, bytes untouched")

    # overwrite -> empty overwrite: DELETED, because nothing claims the path.
    overwritten()
    fixture.own(mcp_plan("overwrite", {}))
    assert not config.exists() and not whole.exists() and not leaves.exists()
    print("PASS transitions: overwrite -> empty overwrite deleted the file")


def write_arms(fixture):
    """Every arm of the write half of the clobber table."""
    managed = fixture.root / "settings"
    target = managed / "unit.txt"
    ledger = fixture.ledger("materialize/settings.manifest")
    plan = {"targets": [dir_target({"unit.txt": {"mode": "0444", "text": "ours\n"}})]}

    # fresh
    fixture.own(plan)
    assert target.read_text() == "ours\n" and stat.S_IMODE(target.stat().st_mode) == 0o444
    witness = hashlib.sha256(b"ours\n").hexdigest()
    assert ledger.read_text() == f"unit.txt\t{witness}\n", ledger.read_text()
    print("PASS write_arms: fresh")

    # match, identical: skipped, no mtime churn
    os.utime(target, ns=(10**9, 10**9))
    before = snapshot(target)
    fixture.own(plan)
    assert snapshot(target) == before, "an unchanged unit was republished"
    print("PASS write_arms: match skipped with mtime unchanged")

    # mismatch: backed up, then overwritten
    target.chmod(0o644)
    target.write_text("hand edit\n")
    result = fixture.own(plan)
    assert "was edited since it was materialized" in result.stderr, result.stderr
    assert "overwriting" in result.stderr
    backups = fixture.backups()
    assert len(backups) == 1 and backups[0].read_text() == "hand edit\n"
    # `cp -p` parity: the backup carries the mode the user's file had.
    assert stat.S_IMODE(backups[0].stat().st_mode) == 0o644
    assert target.read_text() == "ours\n" and stat.S_IMODE(target.stat().st_mode) == 0o444
    print("PASS write_arms: mismatch backed up then overwritten")

    # unrecorded: backed up, then adopted
    ledger.unlink()
    target.chmod(0o644)
    target.write_text("foreign\n")
    result = fixture.own(plan)
    assert "existed but was not managed" in result.stderr, result.stderr
    assert "adopting" in result.stderr
    backups = fixture.backups()
    # Compared as a SET on purpose: two backups of the same file in the same
    # second are distinguished only by mkstemp's random suffix, so the epoch in
    # the name orders them by second and not within one.
    assert {backup.read_text() for backup in backups} == {"hand edit\n", "foreign\n"}
    assert len(backups) == 2
    assert target.read_text() == "ours\n"
    print("PASS write_arms: unrecorded backed up then adopted")

    # symlink: replaced, never compared. The destination must survive.
    elsewhere = fixture.root / "elsewhere.txt"
    elsewhere.write_text("ours\n")
    target.unlink()
    target.symlink_to(elsewhere)
    fixture.own(plan)
    assert not target.is_symlink() and target.read_text() == "ours\n"
    assert elsewhere.read_text() == "ours\n", "the symlink destination was written through"
    print("PASS write_arms: symlink replaced, destination untouched")

    # non-regular: loud, never clobbered, never claimed.
    ledger.unlink()
    target.unlink()
    os.mkfifo(target)
    # Never open or read it: a faulty regular-file arm would block here, which
    # must surface as the subprocess timeout rather than a hang.
    before = identity(target)
    result = fixture.own(plan, succeeds=False)
    assert "is not a regular file or symlink" in result.stderr, result.stderr
    assert "refusing to clobber" in result.stderr
    assert "unresolved target conflicts" in result.stderr
    assert stat.S_ISFIFO(target.lstat().st_mode) and identity(target) == before
    assert not ledger.exists(), "a refused write claimed the FIFO in the ledger"
    print("PASS write_arms: FIFO refused loudly and left alone")


def remove_arms(fixture):
    """Every arm of the remove half of the clobber table."""
    managed = fixture.root / "settings"
    target = managed / "unit.txt"
    ledger = fixture.ledger("materialize/settings.manifest")
    declared = {"targets": [dir_target({"unit.txt": {"mode": "0644", "text": "ours\n"}})]}
    drained = {"targets": [dir_target({})]}

    # regular file we own, unmodified: removed with no backup.
    fixture.own(declared)
    fixture.own(drained)
    assert not target.exists() and not ledger.exists()
    assert not fixture.backups()
    print("PASS remove_arms: owned file removed, ledger unlinked, no backup")

    # already gone: silent.
    fixture.own(declared)
    target.unlink()
    fixture.own(drained)
    assert not ledger.exists()
    print("PASS remove_arms: absent unit is a silent no-op")

    # edited since we wrote it: backed up, then removed.
    fixture.own(declared)
    target.write_text("hand edit\n")
    result = fixture.own(drained)
    assert "was edited since it was materialized" in result.stderr, result.stderr
    backups = fixture.backups()
    assert len(backups) == 1 and backups[0].read_text() == "hand edit\n"
    assert not target.exists()
    print("PASS remove_arms: edited file backed up then removed")

    # symlink: never user content, removed.
    fixture.own(declared)
    elsewhere = fixture.root / "elsewhere.txt"
    elsewhere.write_text("destination\n")
    target.unlink()
    target.symlink_to(elsewhere)
    fixture.own(drained)
    assert not target.is_symlink() and not target.exists()
    assert elsewhere.read_text() == "destination\n", "removal followed the symlink"
    print("PASS remove_arms: symlink removed, destination untouched")

    # non-regular: loud, left in place, and the ledger still stops claiming it.
    fixture.own(declared)
    target.unlink()
    os.mkfifo(target)
    before = identity(target)
    result = fixture.own(drained, succeeds=False)
    assert "is not a regular file or symlink" in result.stderr, result.stderr
    assert "leaving it in place" in result.stderr
    assert stat.S_ISFIFO(target.lstat().st_mode) and identity(target) == before
    assert not ledger.exists(), "a refused removal kept claiming the FIFO"
    print("PASS remove_arms: FIFO refused loudly and left alone")


def drain(fixture):
    """N -> 0 on both codecs."""
    managed = fixture.root / "settings"
    ledger = fixture.ledger("materialize/settings.manifest")
    units = {name: {"mode": "0444", "text": f"{name}\n"} for name in ("a.txt", "b.txt")}
    fixture.own({"targets": [dir_target(units)]})
    assert sorted(path.name for path in managed.iterdir()) == ["a.txt", "b.txt"]
    assert len(ledger.read_text().splitlines()) == 2
    fixture.own({"targets": [dir_target({})]})
    assert list(managed.iterdir()) == [], "drained directory still holds files"
    assert not ledger.exists(), "drained directory kept its ledger"
    print("PASS drain: dir codec removed every unit and unlinked the ledger")

    document = fixture.root / "settings/cli.json"
    leaves = fixture.ledger("json-settings/cli.json")
    declared = {"nested": {"ours": {"deep": 1}}}
    fixture.own(
        {
            "targets": [
                doc_target(
                    {"text": json.dumps(declared)},
                    path="settings/cli.json",
                    ledger="json-settings/cli.json",
                )
            ]
        }
    )
    native = json.loads(document.read_text())
    native["nested"]["theirs"] = 2
    native["runtime"] = {"trust": "yes"}
    document.write_text(json.dumps(native, indent=2) + "\n")
    fixture.own(
        {
            "targets": [
                doc_target({}, path="settings/cli.json", ledger="json-settings/cli.json")
            ]
        }
    )
    assert json.loads(document.read_text()) == {
        "nested": {"theirs": 2},
        "runtime": {"trust": "yes"},
    }, document.read_text()
    assert not leaves.exists(), "drained document kept its ledger"
    print("PASS drain: doc codec deleted its leaves and kept every sibling")

    # The same drain again, with the owned leaf as the only child: the empty
    # parent table goes with it, and an unowned sibling file is byte-identical.
    sibling = fixture.root / "settings/untouched.json"
    sibling.write_text("{}\n")
    before = snapshot(sibling)
    fixture.own(
        {
            "targets": [
                doc_target(
                    {"text": json.dumps({"only": {"ours": 1}})},
                    path="settings/cli.json",
                    ledger="json-settings/cli.json",
                )
            ]
        }
    )
    fixture.own(
        {
            "targets": [
                doc_target({}, path="settings/cli.json", ledger="json-settings/cli.json")
            ]
        }
    )
    assert "only" not in json.loads(document.read_text()), "empty parent survived"
    assert snapshot(sibling) == before
    print("PASS drain: empty parents pruned, unowned sibling byte-identical")


def two_phase(fixture):
    """The HM pair: `--phase prune` deletes, `--phase all` finishes the job."""
    unit = fixture.root / "settings/unit.txt"
    document = fixture.root / "settings/cli.json"
    whole = fixture.ledger("materialize/settings.manifest")
    leaves = fixture.ledger("json-settings/cli.json")
    declared = {
        "targets": [
            dir_target({"unit.txt": {"mode": "0444", "text": "ours\n"}}),
            doc_target(
                {"text": json.dumps({"ours": 1})},
                path="settings/cli.json",
                ledger="json-settings/cli.json",
            ),
        ]
    }
    drained = {
        "targets": [
            dir_target({}),
            doc_target({}, path="settings/cli.json", ledger="json-settings/cli.json"),
        ]
    }
    fixture.own(declared)
    assert unit.is_file() and whole.is_file() and leaves.is_file()
    before = snapshot(document), snapshot(leaves), whole.read_bytes()

    # Phase one runs BEFORE checkLinkTargets: the real file has to be gone by
    # then, but the ledger may not be rewritten (activation can still die
    # before phase two, and the ledger is what makes the retry idempotent) and
    # a document must not be touched at all by a process that will not finish
    # its read-modify-write.
    fixture.own(drained, "--phase", "prune")
    assert not unit.exists(), "the prune phase left the retired file behind"
    assert whole.read_bytes() == before[2], "the prune phase rewrote a ledger"
    assert (snapshot(document), snapshot(leaves)) == before[:2], \
        "the prune phase touched a document target"

    fixture.own(drained, "--phase", "all")
    assert not whole.exists() and not leaves.exists()
    assert json.loads(document.read_text()) == {}
    print("PASS two_phase: prune deleted without rewriting, write finished the drain")


def virgin(fixture):
    """Virgin plus empty is a strict no-op: not one directory is created."""
    plan = {
        "targets": [
            dir_target({}),
            doc_target({}),
            # A producer that resolves to zero leaves is also nothing to do,
            # and must not parse (or create) the document it would have owned.
            doc_target(
                {"text": "{}"}, path="settings/cli.json", ledger="json-settings/cli.json"
            ),
        ]
    }
    fixture.own(plan)
    assert list(fixture.root.iterdir()) == [], "a no-op run created a target directory"
    assert not fixture.state.exists(), "a no-op run created the state directory"
    fixture.own(plan, "--phase", "prune")
    assert list(fixture.root.iterdir()) == [] and not fixture.state.exists()
    print("PASS virgin: no target directory, no state directory, no ledger")

    # Same shape, but the document exists and is not even JSON. An empty
    # declaration must leave an externally managed file byte-identical.
    foreign = fixture.root / "settings/cli.json"
    foreign.parent.mkdir(parents=True)
    foreign.write_text("externally managed, not JSON\n")
    before = snapshot(foreign)
    fixture.own(plan)
    assert snapshot(foreign) == before
    assert not fixture.state.exists()
    print("PASS virgin: externally managed document left byte-identical")


def modes(fixture):
    """Documents preserve the mode they have; directories impose the declared one."""
    document = fixture.root / "settings/cli.json"
    target = doc_target(
        {"text": json.dumps({"ours": 1})},
        path="settings/cli.json",
        ledger="json-settings/cli.json",
    )
    # New documents are private regardless of umask (see the umask(0) below).
    fixture.own({"targets": [target]})
    assert stat.S_IMODE(document.stat().st_mode) == 0o600
    for mode in (0o400, 0o600, 0o640):
        document.chmod(mode)
        fixture.own({"targets": [target]})
        assert stat.S_IMODE(document.stat().st_mode) == mode, oct(mode)
        changed = doc_target(
            {"text": json.dumps({"ours": mode})},
            path="settings/cli.json",
            ledger="json-settings/cli.json",
        )
        fixture.own({"targets": [changed]})
        assert json.loads(document.read_text())["ours"] == mode
        assert stat.S_IMODE(document.stat().st_mode) == mode, f"changed write lost {oct(mode)}"
    print("PASS modes: doc codec preserved 0400/0600/0640 and used 0600 for a new file")

    unit = fixture.root / "settings/unit.txt"
    for mode in ("0400", "0444", "0640"):
        fixture.own({"targets": [dir_target({"unit.txt": {"mode": mode, "text": "ours\n"}})]})
        assert stat.S_IMODE(unit.stat().st_mode) == int(mode, 8), mode
    # This ASSERTION IS THE PIN, not an invariant: rewriting the same bytes at
    # a wider declared mode widens the file, because the directory codec
    # sets the declared mode unconditionally. Design open question 1 asks
    # the operator whether to change that; changing it must fail here first.
    fixture.own({"targets": [dir_target({"unit.txt": {"mode": "0400", "text": "ours\n"}})]})
    assert stat.S_IMODE(unit.stat().st_mode) == 0o400
    fixture.own({"targets": [dir_target({"unit.txt": {"mode": "0444", "text": "ours\n"}})]})
    assert stat.S_IMODE(unit.stat().st_mode) == 0o444, "the 0400 -> 0444 widening changed"
    print("PASS modes: dir codec imposed each declared mode, including the widening")


def renderer(fixture):
    """A failing renderer leaves every config file and every ledger identical."""
    document = fixture.root / "settings/cli.json"
    unit = fixture.root / "settings/unit.txt"
    good = {
        "targets": [
            dir_target({"unit.txt": {"mode": "0444", "run": "printf 'rendered\\n'"}}),
            doc_target(
                {"run": "printf '{\"ours\": 1}'"},
                path="settings/cli.json",
                ledger="json-settings/cli.json",
            ),
        ]
    }
    fixture.own(good)
    assert unit.read_text() == "rendered\n"
    assert json.loads(document.read_text()) == {"ours": 1}
    before = [
        snapshot(path)
        for path in (
            unit,
            document,
            fixture.ledger("materialize/settings.manifest"),
            fixture.ledger("json-settings/cli.json"),
        )
    ]

    for failing in (
        "printf 'partial'; exit 3",
        "printf 'partial\\n' >&2; false",
        "exec /nonexistent/renderer",
    ):
        broken = json.loads(json.dumps(good))
        broken["targets"][0]["units"]["unit.txt"]["run"] = failing
        result = fixture.own(broken, succeeds=False)
        assert "renderer exited" in result.stderr, result.stderr
        assert [
            snapshot(path)
            for path in (
                unit,
                document,
                fixture.ledger("materialize/settings.manifest"),
                fixture.ledger("json-settings/cli.json"),
            )
        ] == before, f"a failed renderer moved bytes: {failing}"
    assert not list((fixture.root / "settings").glob(".*.nat-tmp.*"))
    print("PASS renderer: three failure shapes, every byte and both ledgers identical")


def legacy(fixture):
    """Both legacy ledgers, written by TODAY's code, read and pruned by own.py.

    This is the positive control for "no migration code needed": nothing here
    constructs a ledger by hand, so a format drift in either reader fails.
    """
    produced = subprocess.run(
        [TOOLS["legacyDir"]], env=fixture.environment, capture_output=True, text=True, timeout=60
    )
    assert produced.returncode == 0, produced.stderr
    unit = fixture.root / "managed/legacy.txt"
    manifest = fixture.ledger("materialize/own-legacy.manifest")
    assert unit.read_text() == "legacy payload\n"
    recorded = manifest.read_text()
    assert recorded == f"legacy.txt\t{hashlib.sha256(unit.read_bytes()).hexdigest()}\n", recorded
    fixture.own(
        {
            "targets": [
                dir_target({}, path="managed", ledger="materialize/own-legacy.manifest")
            ]
        }
    )
    assert not unit.exists(), "own.py did not prune from the generated TSV manifest"
    assert not manifest.exists()
    assert not fixture.backups(), "a witness from the TSV manifest was misread as an edit"
    print("PASS legacy: TSV manifest from materialize.nix read, pruned, unlinked")

    document = fixture.root / "config.json"
    v1 = fixture.ledger("json-settings/own-legacy.json")
    declared = {"owned": {"leaf": 1}, "other": 2}
    reconciled = subprocess.run(
        [TOOLS["python"], TOOLS["legacyDoc"], "--format", "json",
         "--config", str(document), "--manifest", str(v1)],
        input=json.dumps(declared), env=fixture.environment,
        capture_output=True, text=True, timeout=60,
    )
    assert reconciled.returncode == 0, reconciled.stderr
    assert json.loads(v1.read_text())["version"] == 1
    native = json.loads(document.read_text())
    native["native"] = {"kept": True}
    document.write_text(json.dumps(native, indent=2) + "\n")
    fixture.own(
        {
            "targets": [
                doc_target({}, path="config.json", ledger="json-settings/own-legacy.json")
            ]
        }
    )
    assert json.loads(document.read_text()) == {"native": {"kept": True}}, document.read_text()
    assert not v1.exists()
    print("PASS legacy: v1 JSON manifest from reconcile-toml.py read, pruned, unlinked")


def lock(fixture):
    """The lock is the one the generated bash holds, and it really blocks."""
    plan = {"targets": [dir_target({"unit.txt": {"mode": "0444", "text": "ours\n"}})]}
    unit = fixture.root / "settings/unit.txt"
    held = fixture.state / "materialize/lock"
    held.parent.mkdir(mode=0o700, parents=True)
    with held.open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        blocked = subprocess.Popen(
            fixture.command(plan), env=fixture.environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            assert blocked.poll() is None, blocked.communicate()
            assert not unit.exists(), "a unit was published while the lock was held"
            time.sleep(0.005)
    assert blocked.wait(timeout=30) == 0, blocked.communicate()
    assert unit.read_text() == "ours\n"
    print("PASS lock: own.py blocked on the state-dir-wide lock, then published")

    # Two identical invocations, overlapping on purpose. Their renderers hold
    # each other at a barrier so both are in flight, and the end state must be
    # exactly one unit, one consistent ledger and no live temporaries.
    barrier = fixture.root / "barrier"
    barrier.mkdir()
    concurrent = {
        "targets": [
            dir_target(
                {
                    "unit.txt": {
                        "mode": "0444",
                        "run": f"{TOOLS['python']} {sys.argv[0]} render {barrier} 2",
                    }
                }
            )
        ]
    }
    processes = [
        subprocess.Popen(
            fixture.command(concurrent), env=fixture.environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True,
        )
        for _ in range(2)
    ]
    try:
        wait_for(
            lambda: len(list(barrier.glob("*.arrived"))) == 2
            or any(process.poll() is not None for process in processes),
            "both invocations never reached the renderer",
        )
        for process in processes:
            stdout, stderr = process.communicate(timeout=60)
            assert process.returncode == 0, (process.returncode, stdout, stderr)
        assert unit.read_text() == "rendered concurrently\n"
        ledger = fixture.ledger("materialize/settings.manifest")
        assert ledger.read_text() == (
            f"unit.txt\t{hashlib.sha256(unit.read_bytes()).hexdigest()}\n"
        ), ledger.read_text()
        assert not list(unit.parent.glob(".*.nat-tmp.*")), "a live temporary survived"
        assert not list(ledger.parent.glob(".*.nat-tmp.*")), "a live ledger temporary survived"
        assert not fixture.backups(), "an overlapping invocation lost ownership"
        print("PASS lock: two overlapping invocations converged on one state")
    finally:
        for process in processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()


def lazy_toml(fixture):
    """The TOML codec works, and only it needs tomlkit."""
    document = fixture.root / "config.toml"
    document.write_text('[projects."/repo"]\ntrust_level = "trusted"\n')
    target = doc_target(
        {"text": json.dumps({"features": {"memories": True}})},
        codec="toml",
        path="config.toml",
        ledger="toml-settings/codex.toml.json",
    )
    fixture.own({"targets": [target]}, python=TOOLS["tomlPython"])
    body = document.read_text()
    assert '[projects."/repo"]' in body and "trust_level" in body, body
    assert "memories = true" in body, body
    fixture.own({"targets": [doc_target({}, codec="toml", path="config.toml", ledger="toml-settings/codex.toml.json")]},
                python=TOOLS["tomlPython"])
    # Not a byte comparison: a tomlkit set-then-delete round trip leaves the
    # blank line its table occupied, exactly as reconcile-toml.py does today.
    drained = document.read_text()
    assert "memories" not in drained and "[features]" not in drained, drained
    assert '[projects."/repo"]' in drained and 'trust_level = "trusted"' in drained, drained
    assert not fixture.ledger("toml-settings/codex.toml.json").exists()
    print("PASS lazy_toml: TOML leaves set and retracted, native table untouched")

    # The import is lazy: the same interpreter that just ran every JSON and
    # dir case cannot even import tomlkit, so a JSON caller's closure has no
    # reason to carry it.
    probe = subprocess.run([TOOLS["python"], "-c", "import tomlkit"], capture_output=True, text=True)
    assert probe.returncode != 0 and "tomlkit" in probe.stderr, probe.stderr
    before = document.read_bytes()
    result = fixture.own({"targets": [target]}, succeeds=False)
    assert "tomlkit" in result.stderr, result.stderr
    assert document.read_bytes() == before, "a failed TOML import moved bytes"
    print("PASS lazy_toml: the JSON interpreter has no tomlkit, and only TOML needs it")


def rejections(fixture):
    """A malformed plan fails closed, before anything is opened."""
    for arguments, plan in (
        ("traversing unit address", {"targets": [dir_target({"../escape": {"text": "x"}})]}),
        ("dot-prefixed unit address", {"targets": [dir_target({".hidden": {"text": "x"}})]}),
        ("traversing ledger", {"targets": [dir_target({}, ledger="../escape.manifest")]}),
        ("absolute path", {"targets": [dir_target({"unit": {"text": "x"}}, path="/etc")]}),
        ("unknown codec", {"targets": [doc_target({}, codec="yaml")]}),
        ("duplicate ledger", {"targets": [dir_target({}), doc_target({}, ledger="materialize/settings.manifest")]}),
        ("two content tags", {"targets": [dir_target({"unit": {"store": "/dev/null", "text": "x"}})]}),
        ("missing field", {"targets": [{"codec": "dir", "path": "settings", "units": {}}]}),
    ):
        result = fixture.own(plan, succeeds=False)
        assert result.stderr.startswith("own: "), (arguments, result.stderr)
        assert list(fixture.root.iterdir()) == [], (arguments, "a rejected plan touched the root")
        assert not fixture.state.exists(), (arguments, "a rejected plan created state")
    print("PASS rejections: eight malformed plans refused before any container opened")


CASES = {
    "drain": drain,
    "lazy_toml": lazy_toml,
    "legacy": legacy,
    "lock": lock,
    "modes": modes,
    "rejections": rejections,
    "remove_arms": remove_arms,
    "renderer": renderer,
    "transitions": transitions,
    "two_phase": two_phase,
    "virgin": virgin,
    "write_arms": write_arms,
}


def render(barrier, expected):
    """Hold every overlapping invocation until all of them have arrived."""
    barrier = Path(barrier)
    (barrier / f"{os.getpid()}.arrived").touch()
    wait_for(
        lambda: len(list(barrier.glob("*.arrived"))) >= int(expected),
        "the other invocation never reached the renderer",
    )
    sys.stdout.write("rendered concurrently\n")


if __name__ == "__main__":
    if sys.argv[1] == "render":
        render(sys.argv[2], sys.argv[3])
    else:
        # Every mode assertion below is about the mode the program sets, not
        # about the one the process inherited.
        os.umask(0)
        TOOLS.update(json.loads(Path(sys.argv[1]).read_text()))
        selected = sys.argv[2:] or sorted(CASES)
        for name in selected:
            with tempfile.TemporaryDirectory() as directory:
                CASES[name](Fixture(directory))
        print(f"PASS: ai-own runtime, {len(selected)} cases")

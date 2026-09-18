"""Exercise generated scripts; barriers force duplicate invocations to overlap."""

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


def wait_for(predicate, message, observe=lambda: None):
    deadline = time.monotonic() + 15
    while not predicate():
        observe()
        assert time.monotonic() < deadline, message
        time.sleep(0.005)


def render(expected):
    """Hold partial renderer output while the materializer owns its lock."""
    barrier = Path(os.environ["ORACLE_BARRIER"])
    identifier = os.environ["ORACLE_INVOCATION"]
    payload = expected.read_bytes()
    midpoint = len(payload) // 2
    sys.stdout.buffer.write(payload[:midpoint])
    sys.stdout.buffer.flush()
    (barrier / f"{identifier}.rendering").touch()
    wait_for(lambda: (barrier / f"{identifier}.release").exists(),
             f"{identifier}: renderer was never released")
    sys.stdout.buffer.write(payload[midpoint:])


def fixture(root):
    home, state = root / "home", root / "state"
    home.mkdir()
    target = home / "managed/payload.txt"
    manifest = state / "nix-agentic-tools/materialize/oracle-runtime.manifest"
    environment = dict(os.environ, DEVENV_ROOT=str(home), DEVENV_STATE=str(state),
                       HOME=str(home), XDG_STATE_HOME=str(state), ORACLE_BARRIER=str(root))
    return target, manifest, environment


def activate(script, environment):
    return subprocess.run([script], env=environment, capture_output=True,
                          text=True, timeout=20)


def fifo(case, root):
    target, manifest, environment = fixture(root)
    target.parent.mkdir()
    # An unowned FIFO blocks adoption by the write phase. Do not open/read it:
    # a faulty regular-file test would block, which must fail via the timeout.
    os.mkfifo(target)
    for phase, script in (("write", case["initial"]), ("prune", case["empty"])):
        identity = target.lstat()
        result = activate(script, environment)
        assert result.returncode != 0, f"{case['backend']} {phase}: FIFO collision succeeded"
        assert "not a regular file or symlink" in result.stderr, result.stderr
        assert "ERROR: materialize(oracle-runtime)" in result.stderr, result.stderr
        assert str(target) in result.stderr, result.stderr
        after = target.lstat()
        assert stat.S_ISFIFO(after.st_mode), f"{phase}: FIFO was replaced"
        assert (after.st_dev, after.st_ino) == (identity.st_dev, identity.st_ino), \
            f"{phase}: FIFO identity changed"
        print(f"PASS: {case['backend']} FIFO {phase}: loud refusal, same FIFO")
        if phase == "write":
            assert not manifest.exists() or manifest.read_bytes() == b"", \
                "failed write claimed foreign FIFO"
            # Establish genuine ownership, then replace the owned file with a
            # foreign FIFO before asking the empty generation to prune it.
            target.unlink()
            initial = activate(case["initial"], environment)
            assert initial.returncode == 0, initial.stderr
            assert target.read_bytes() == b"previous generation\n"
            assert manifest.read_text().startswith("payload.txt\t")
            target.unlink()
            os.mkfifo(target)


def concurrent(case, root):
    target, manifest, environment = fixture(root)
    initial = activate(case["initial"], environment)
    assert initial.returncode == 0, initial.stderr
    old = target.read_bytes()
    expected = Path(case["expected"]).read_bytes()
    assert old != expected and len(expected) > 65536
    processes = []

    def start(identifier):
        # Both children execute this exact same generated script. Only their
        # test-renderer barrier identities differ.
        process = subprocess.Popen(
            [case["concurrent"]],
            env=dict(environment, ORACLE_INVOCATION=identifier),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True,
        )
        processes.append(process)
        return process

    def observe():
        assert target.read_bytes() in (old, expected), "reader observed a partial payload"
        lines = manifest.read_text().splitlines()
        assert len(lines) == 1, f"reader observed corrupt manifest: {lines!r}"
        name, digest = lines[0].split("\t")
        assert name == "payload.txt" and digest in (
            hashlib.sha256(old).hexdigest(), hashlib.sha256(expected).hexdigest()
        ), f"reader observed corrupt ledger: {lines!r}"

    try:
        first = start("first")
        wait_for(lambda: (root / "first.rendering").exists() or first.poll() is not None,
                 "first invocation never reached the renderer")
        assert first.poll() is None, first.communicate()
        assert target.read_bytes() == old, "partial renderer output was published"
        second = start("second")
        # Hold the first inside its renderer while the second attempts entry.
        # Without serialization the second reaches its renderer or sweeps the
        # first's live temporary files; both are deterministic failures here.
        deadline = time.monotonic() + 1
        observations = 0
        while time.monotonic() < deadline:
            assert first.poll() is None and second.poll() is None, \
                "an overlapping invocation failed before release"
            assert not (root / "second.rendering").exists(), \
                "second invocation entered the renderer while first held the lock"
            observe()
            observations += 1
            time.sleep(0.005)
        assert observations > 0
        (root / "first.release").touch()
        wait_for(lambda: (root / "second.rendering").exists() or second.poll() is not None,
                 "second invocation never reached the renderer", observe)
        assert second.poll() is None, second.communicate()
        assert target.read_bytes() == expected, "first invocation did not publish complete payload"
        observe()
        (root / "second.release").touch()
        wait_for(lambda: all(process.poll() is not None for process in processes),
                 "concurrent invocations did not finish", observe)
        for process in processes:
            stdout, stderr = process.communicate(timeout=20)
            assert process.returncode == 0, (process.returncode, stdout, stderr)
        assert target.read_bytes() == expected, "final payload is incomplete"
        assert manifest.read_text() == f"payload.txt\t{hashlib.sha256(expected).hexdigest()}\n", \
            "final manifest does not match the complete payload"
        assert stat.S_IMODE(target.stat().st_mode) == 0o444
        assert not list(target.parent.glob(".*.nat-tmp.*")), "live file temporary survived"
        assert not list(manifest.parent.glob(".*.nat-tmp.*")), "live ledger temporary survived"
        assert not list(manifest.parent.glob("*.bak/*")), "duplicate invocation lost ownership"
        print(f"PASS: {case['backend']} identical concurrent script; {observations} complete snapshots")
    finally:
        for process in processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()


if sys.argv[1] == "render":
    render(Path(sys.argv[2]))
else:
    cases = json.loads(Path(sys.argv[2]).read_text())
    assert len(cases) == 2 and {case["backend"] for case in cases} == {"devenv", "hm"}
    control = {"concurrent": concurrent, "fifo": fifo}[sys.argv[1]]
    for case in cases:
        with tempfile.TemporaryDirectory() as directory:
            control(case, Path(directory))

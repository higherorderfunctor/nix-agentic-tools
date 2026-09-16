"""Assert semble-kiro-acp.py attributes a teardown kill to whoever sent it.

The driver SIGKILLs a child that outlives its post-stdin-EOF budget and then
reads `proc.returncode`. Judging a status the harness manufactured turned four
CI runs red across five weeks while every assertion the check exists to make had
already passed. Nothing exercised those branches, which is why it survived.

argv: <semble-kiro-acp.py> <fake-acp.py>
"""

import json
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

DRIVER, FAKE = sys.argv[1], sys.argv[2]


def shim(directory):
    """An executable stand-in for `kiro-cli-chat`.

    The driver spawns its argv[1] directly, so the fake has to be executable
    with a shebang. Keeping the fixture a plain module and wrapping it here
    means the same file runs identically under Nix, where store sources are
    not executable, and from a checkout.
    """
    path = Path(directory) / "kiro-cli-chat"
    path.write_text(f'#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(FAKE)} "$@"\n')
    path.chmod(0o755)
    return str(path)


def drive(teardown, kiro, workspace):
    result = subprocess.run(
        [sys.executable, DRIVER, kiro, "semble-search", "control-search", workspace],
        capture_output=True,
        env={"FAKE_TEARDOWN": teardown, "PATH": "/nonexistent"},
        text=True,
    )
    return result.returncode, result.stdout, result.stderr


def expect(condition, message, stderr):
    if not condition:
        raise SystemExit(f"teardown-contract: {message}\n--- driver stderr ---\n{stderr}")


with tempfile.TemporaryDirectory() as root:
    workspace, kiro = str(Path(root) / "workspace"), shim(root)
    Path(workspace).mkdir()
    # 1. The regression itself. A child that outruns the budget is the harness's
    #    kill, so the run passes -- and says out loud who sent the signal.
    code, out, err = drive("hang", kiro, workspace)
    expect(code == 0, f"a harness-killed child must not fail the check (exit {code})", err)
    expect("harness SIGKILLed ACP" in err, "the kill must be attributed to the harness", err)
    expect("ACP exited with status -9" not in err, "the old mis-attributed message must be gone", err)
    teardown = {name: json.loads(out)[name]["teardown"] for name in ("configured", "control")}
    expect(all(record["harness_kill"] for record in teardown.values()), f"both agents must record the kill: {teardown}", err)

    # 2. The assertion that must NOT have been given up: a server that panics on
    #    stdin EOF still fails, and is described as its own choice.
    code, out, err = drive("101", kiro, workspace)
    expect(code != 0, "an autonomous non-zero exit must still fail the check", err)
    expect("exited with status 101 on its own" in err, "an autonomous exit must be named as such", err)
    expect("harness SIGKILLed" not in err, "no kill was sent, so none may be claimed", err)

    # 3. A third party (an OOM kill, an external SIGTERM) is not the harness.
    #    This is the branch that makes the harness's own claim falsifiable.
    code, out, err = drive("signal", kiro, workspace)
    expect(code != 0, "a third-party signal must still fail the check", err)
    expect("killed by signal 15 on its own" in err, "a signal must not be rendered as an exit status", err)
    expect("harness sent no signal" in err, "the harness must state positively that it sent nothing", err)

    # 4. The happy path stays silent and records a clean teardown.
    code, out, err = drive("0", kiro, workspace)
    expect(code == 0, f"a clean exit must pass (exit {code})", err)
    expect("harness SIGKILLed" not in err, "a clean exit must not report a kill", err)
    teardown = {name: json.loads(out)[name]["teardown"] for name in ("configured", "control")}
    expect(not any(record["harness_kill"] for record in teardown.values()), f"a clean exit must record no kill: {teardown}", err)

print("teardown-contract: all four teardown branches behave")

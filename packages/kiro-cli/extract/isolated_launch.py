# cspell:ignore CFFIXED killpg
"""Launch the Kiro chat binary in a throwaway HOME and copy out a file it
materializes on first run.

Shared by embedded-tui.py (the TUI JavaScript) and kas-bundle.py (the KAS
engine bundle). Both rely on the same fact: the binary unpacks embedded assets
on launch, before anything needs an account or the network, so a dummy
KIRO_API_KEY in an isolated HOME is enough to get them.
"""

import os
import pty
import select
import shutil
import signal
import subprocess
import time
from pathlib import Path


def signal_group(child, sig):
    """Signal the child's process group, treating an exited group as gone.

    Darwin's killpg answers EPERM, not ESRCH, while every member of the group
    is a zombie -- here, a leader that exited but is not reaped yet. EPERM is
    accepted only once poll() has reaped that leader and a retry agrees the
    group is gone; while the leader lives, EPERM is a real failure and raises.
    """
    try:
        os.killpg(child.pid, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        if child.poll() is None:
            raise
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass


def materialize(binary, args, root, destination, find, what, cert_file, env=None, timeout=120):
    """Run `binary args` under `root` until `find(root)` names one file.

    `find` returns every complete candidate; more than one is an error, because
    copying an arbitrary one would hide which asset the result describes. The
    whole process group is torn down afterwards, so nothing the binary spawned
    (KAS, node) outlives the call.
    """
    root = Path(root)
    home = root / "home"
    workspace = root / "workspace"
    home.mkdir()
    workspace.mkdir()
    child_env = {
        "CFFIXED_USER_HOME": str(home),
        "HOME": str(home),
        "KIRO_API_KEY": "offline-extraction-fixture",
        "PATH": os.environ.get("PATH", ""),
        "SSL_CERT_FILE": cert_file,
        "TERM": "xterm-256color",
        "XDG_CACHE_HOME": str(root / "cache"),
        "XDG_CONFIG_HOME": str(root / "config"),
    } | (env or {})
    master, slave = pty.openpty()
    child = subprocess.Popen(
        [binary, *args],
        cwd=workspace,
        env=child_env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    output = b""
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.2)
            if readable:
                try:
                    output = (output + os.read(master, 65536))[-4096:]
                except OSError:
                    pass
            # Sampled BEFORE the search: a child that writes the asset and then
            # exits between the two would otherwise be reported as failing.
            exited = child.poll() is not None
            found = find(root)
            if len(found) > 1:
                raise RuntimeError(f"multiple {what} candidates: {found}")
            if found:
                shutil.copyfile(found[0], destination)
                return
            if exited:
                raise RuntimeError(
                    f"{binary} exited before its {what} was materialized "
                    f"(exit {child.returncode}); output tail:\n"
                    + output.decode(errors="replace")
                )
        raise RuntimeError(
            f"{what} materialization timed out after {timeout} seconds; output tail:\n"
            + output.decode(errors="replace")
        )
    finally:
        signal_group(child, signal.SIGTERM)
        time.sleep(0.2)
        signal_group(child, signal.SIGKILL)
        child.wait()
        os.close(master)

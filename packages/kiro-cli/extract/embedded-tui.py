# cspell:ignore CFFIXED killpg
import hashlib
import os
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def signal_group(child, sig):
    """Signal the child's process group, treating an exited group as gone.

    On Darwin, killpg can answer EPERM when any group member cannot be signalled,
    including during teardown while the leader is still exiting. If the leader
    is alive, signal it directly instead: cleanup closes the pty master and
    waits for the child, then sends SIGKILL 0.2 seconds later if needed.
    If the leader has exited, retry killpg to confirm the group is gone.
    """
    try:
        os.killpg(child.pid, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        if child.poll() is None:
            try:
                child.send_signal(sig)
            except ProcessLookupError:
                pass
            return
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass


# Usage: embedded-tui.py <tui|kas> <binary> <destination> <cert-file> [fake-kas]
mode, binary, destination, cert_file, *extra = sys.argv[1:]
if mode not in ("tui", "kas") or len(extra) != (mode == "tui"):
    raise ValueError("tui mode needs a fake KAS; kas mode does not")
engine = "node_modules/@kiro/agent/dist/server/acp-server.js"
asset_name = "tui.js" if mode == "tui" else "acp-server.js"
what = "checksum-validated embedded TUI" if mode == "tui" else "KAS engine bundle"
timeout = 120 if mode == "tui" else 180
with tempfile.TemporaryDirectory(prefix=f"kiro-{mode}-") as root:
    root = Path(root)
    home = root / "home"
    workspace = root / "workspace"
    home.mkdir()
    workspace.mkdir()
    env = {
        "CFFIXED_USER_HOME": str(home),
        "HOME": str(home),
        "KIRO_API_KEY": "offline-extraction-fixture",
        "PATH": os.environ.get("PATH", ""),
        "SSL_CERT_FILE": cert_file,
        "TERM": "xterm-256color",
        "XDG_CACHE_HOME": str(root / "cache"),
        "XDG_CONFIG_HOME": str(root / "config"),
    }
    if mode == "tui":
        # Stop before agent startup; only the TUI needs the fake KAS.
        env.update(KIRO_KAS_NODE_PATH=extra[0], KIRO_KAS_SERVER_PATH=extra[0])
    master, slave = pty.openpty()
    child = subprocess.Popen(
        [binary, *(["--v3", "chat"] if mode == "tui" else ["acp", "--agent-engine", "v3"])],
        cwd=workspace,
        env=env,
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
            # Poll before finding: an asset written just before exit is valid.
            exited = child.poll() is not None
            verified = []
            if mode == "kas":
                # KAS renames its complete version directory out of staging.
                verified = [
                    path for path in root.glob("home/**/kiro-cli/kas/*/" + engine)
                    if not path.parents[5].name.startswith(".")
                ]
            for asset in root.rglob("tui.js") if mode == "tui" else []:
                checksum = asset.with_name("tui.js.sha256")
                if checksum.is_file():
                    expected = checksum.read_text().strip()
                    actual = hashlib.sha256(asset.read_bytes()).hexdigest()
                    if actual == expected:
                        verified.append(asset)
            if len(verified) > 1:
                raise RuntimeError(f"multiple {what} candidates: {verified}")
            if verified:
                shutil.copyfile(verified[0], destination)
                break
            if exited:
                raise RuntimeError(
                    f"chat exited before its {what} was materialized "
                    f"(exit {child.returncode}); output tail:\n"
                    + output.decode(errors="replace")
                )
        else:
            paths = sorted(str(path.relative_to(root)) for path in root.rglob(asset_name))
            raise RuntimeError(
                f"{what} materialization timed out after {timeout} seconds; "
                f"isolated candidates: {paths}; output tail:\n"
                + output.decode(errors="replace")
            )
    finally:
        os.close(master)
        signal_group(child, signal.SIGTERM)
        time.sleep(0.2)
        signal_group(child, signal.SIGKILL)
        child.wait()

if mode == "tui" and Path(destination).stat().st_size < 100_000:
    raise RuntimeError("embedded TUI is unexpectedly small")

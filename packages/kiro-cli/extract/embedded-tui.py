# cspell:ignore killpg
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


binary, destination, fake_kas, cert_file = sys.argv[1:]
with tempfile.TemporaryDirectory(prefix="kiro-tui-") as root:
    root = Path(root)
    home = root / "home"
    workspace = root / "workspace"
    home.mkdir()
    workspace.mkdir()
    env = {
        "CFFIXED_USER_HOME": str(home),
        "HOME": str(home),
        "KIRO_API_KEY": "offline-extraction-fixture",
        "KIRO_KAS_NODE_PATH": fake_kas,
        "KIRO_KAS_SERVER_PATH": fake_kas,
        "PATH": os.environ.get("PATH", ""),
        "SSL_CERT_FILE": cert_file,
        "TERM": "xterm-256color",
        "XDG_CACHE_HOME": str(root / "cache"),
        "XDG_CONFIG_HOME": str(root / "config"),
    }
    master, slave = pty.openpty()
    child = subprocess.Popen(
        [binary, "--v3", "chat"],
        cwd=workspace,
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    deadline = time.monotonic() + 120
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.2)
            if readable:
                try:
                    os.read(master, 65536)
                except OSError:
                    pass
            verified = []
            for asset in root.rglob("tui.js"):
                checksum = asset.with_name("tui.js.sha256")
                if checksum.is_file():
                    expected = checksum.read_text().strip()
                    actual = hashlib.sha256(asset.read_bytes()).hexdigest()
                    if actual == expected:
                        verified.append(asset)
            if len(verified) > 1:
                raise RuntimeError("multiple checksum-validated embedded TUI assets")
            if verified:
                shutil.copyfile(verified[0], destination)
                break
            if child.poll() is not None:
                raise RuntimeError(
                    "chat exited before its embedded TUI was materialized "
                    f"(exit {child.returncode})"
                )
        else:
            paths = sorted(str(path.relative_to(root)) for path in root.rglob("tui.js"))
            raise RuntimeError(
                "embedded TUI materialization timed out after 120 seconds; "
                f"isolated TUI candidates: {paths}"
            )
    finally:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        time.sleep(0.2)
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        os.close(master)

if Path(destination).stat().st_size < 100_000:
    raise RuntimeError("embedded TUI is unexpectedly small")

# cspell:ignore checksummed killpg pgid unreaped
import hashlib
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


materializer, fake_kas, cert_file = sys.argv[1:]
layouts = [
    ".local/share/kiro-cli",
    "Library/Application Support/kiro-cli",
]


def write_assets(selected):
    """Fake-chat source that materializes a checksummed TUI in each layout."""
    return (
        f"for layout in {selected!r}:\n"
        " asset=Path(os.environ['HOME'])/layout/'tui.js'\n"
        " asset.parent.mkdir(parents=True)\n"
        " data=b'fixture-tui'*12000\n"
        " asset.write_bytes(data)\n"
        " asset.with_name('tui.js.sha256').write_text(hashlib.sha256(data).hexdigest())\n"
    )


for case, selected in [
    ("linux", layouts[:1]),
    ("darwin", layouts[1:]),
    ("ambiguous", layouts),
]:
    with tempfile.TemporaryDirectory(prefix=f"kiro-materializer-{case}-") as tmp:
        root = Path(tmp)
        binary = root / "fake-chat"
        ready = root / "descendant-ready"
        pid_file = root / "descendant.pid"
        destination = root / "tui.js"
        child_code = (
            "import signal,time;from pathlib import Path;"
            "signal.signal(signal.SIGTERM,signal.SIG_IGN);"
            f"Path({str(ready)!r}).touch();time.sleep(30)"
        )
        binary.write_text(
            f"#!{sys.executable}\n"
            "import hashlib, os, signal, subprocess, sys, time\n"
            "from pathlib import Path\n"
            f"ready=Path({str(ready)!r})\n"
            f"pid_file=Path({str(pid_file)!r})\n"
            f"child=subprocess.Popen([sys.executable,'-c',{child_code!r}])\n"
            "pid_file.write_text(str(child.pid))\n"
            "while not ready.exists(): time.sleep(0.01)\n"
            + write_assets(selected)
            + "time.sleep(30)\n"
        )
        compile(binary.read_text(), str(binary), "exec")
        binary.chmod(0o755)
        result = subprocess.run(
            [sys.executable, materializer, str(binary), str(destination), fake_kas, cert_file],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if case == "ambiguous":
            assert result.returncode != 0
            assert "multiple checksum-validated" in result.stderr, result.stderr
        else:
            assert result.returncode == 0, result.stderr
            assert hashlib.sha256(destination.read_bytes()).hexdigest() == hashlib.sha256(
                b"fixture-tui" * 12000
            ).hexdigest()
        pid = int(pid_file.read_text())
        for _ in range(50):
            stat = Path(f"/proc/{pid}/stat")
            if not stat.exists() or stat.read_text().split()[2] == "Z":
                break
            time.sleep(0.1)
        else:
            raise AssertionError(f"materializer left descendant {pid} running")


# Darwin's killpg answers EPERM, not ESRCH, while every member of the group is a
# zombie. Linux signals zombies without complaint, so emulate that answer by
# wrapping os.killpg around the materializer. "zombie" lets the leader outlive
# asset detection, then exit before the delayed killpg inspects its group, so
# teardown meets an exited but unreaped leader it must treat as gone. "deny"
# refuses a live group, which the materializer must still report as a failure.
shim = """
import os, runpy, sys, time
mode, materializer, *args = sys.argv[1:]
real_killpg = os.killpg
def states(pgid):
    found = []
    for pid in filter(str.isdigit, os.listdir('/proc')):
        try:
            stat = open(f'/proc/{pid}/stat').read()
        except OSError:
            continue
        fields = stat.rsplit(')', 1)[1].split()
        if int(fields[2]) == pgid:
            found.append(fields[0])
    return found
def killpg(pgid, sig):
    if mode == 'deny':
        raise PermissionError(1, 'Operation not permitted')
    time.sleep(1)
    found = states(pgid)
    if found and all(state == 'Z' for state in found):
        raise PermissionError(1, 'Operation not permitted')
    real_killpg(pgid, sig)
os.killpg = killpg
sys.argv = [materializer, *args]
runpy.run_path(materializer, run_name='__main__')
"""
if Path("/proc/self/stat").exists():
    for case, tail in [
        ("zombie", "time.sleep(0.3)\nos._exit(0)\n"),
        ("deny", "time.sleep(30)\n"),
    ]:
        with tempfile.TemporaryDirectory(prefix=f"kiro-materializer-{case}-") as tmp:
            root = Path(tmp)
            binary = root / "fake-chat"
            pid_file = root / "leader.pid"
            destination = root / "tui.js"
            binary.write_text(
                f"#!{sys.executable}\n"
                "import hashlib, os, time\n"
                "from pathlib import Path\n"
                f"Path({str(pid_file)!r}).write_text(str(os.getpid()))\n"
                + write_assets(layouts[:1])
                + tail
            )
            binary.chmod(0o755)
            result = subprocess.run(
                [sys.executable, "-c", shim, case, materializer, str(binary),
                 str(destination), fake_kas, cert_file],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if case == "zombie":
                assert result.returncode == 0, result.stderr
                assert destination.read_bytes() == b"fixture-tui" * 12000
            else:
                assert result.returncode != 0
                assert "PermissionError" in result.stderr, result.stderr
                try:
                    os.killpg(int(pid_file.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

import hashlib
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


materializer, fake_kas, cert_file = sys.argv[1:]
with tempfile.TemporaryDirectory(prefix="kiro-materializer-fixtures-") as tmp:
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
        "asset=Path(os.environ['HOME'])/'.local/share/kiro-cli/tui.js'\n"
        "asset.parent.mkdir(parents=True)\n"
        "data=b'fixture-tui'*12000\n"
        "asset.write_bytes(data)\n"
        "asset.with_name('tui.js.sha256').write_text(hashlib.sha256(data).hexdigest())\n"
        "time.sleep(30)\n"
    )
    compile(binary.read_text(), str(binary), "exec")
    binary.chmod(0o755)
    result = subprocess.run(
        [sys.executable, materializer, str(binary), str(destination), fake_kas, cert_file],
        capture_output=True,
        text=True,
        timeout=10,
    )
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

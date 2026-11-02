# cspell:ignore guestfwd
"""Exercise door PID-file cleanup and process identity without KVM."""

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

launcher, runner, network_device = sys.argv[1:]
match = re.search(r"guestfwd=tcp:10\.0\.2\.100:7000-cmd:(\S+)", network_device)
assert match, network_device
wrapper = match.group(1)

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    result = subprocess.run([wrapper], cwd=root, env=dict(os.environ, SANDBOX_DOOR_TEST_MARKER="host-only"), stdin=subprocess.DEVNULL, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert not list(root.glob("door-*.pid")), "completed door left its PID file"
    assert "MARKER None" in result.stdout
    assert (root / "doors.log").read_text() == "DOOR_STDERR_MUST_NOT_REACH_GUEST\n"

    stub = root / "runner"
    stub.write_text(
        f"#!{sys.executable}\n"
        "import pathlib, time\n"
        "runtime = pathlib.Path.cwd()\n"
        "print('RUNTIME=' + str(runtime), flush=True)\n"
        "(runtime / 'status').write_text('exited:0\\n')\n"
        "time.sleep(0.1)\n"
    )
    stub.chmod(0o755)
    host = root / "host"
    source = Path(launcher).read_text()
    assert source.count(runner) == 1
    assert 'read -r pid start_time < "$pid_file"' in source
    assert 'read -r -a process <<< "${stat##*) }"' in source
    assert 'if [[ ${process[19]:-} == "$start_time" ]]; then' in source
    assert 'kill "$pid" 2>/dev/null || :' in source
    host.write_text(source.replace(runner, str(stub)).replace("/dev/kvm", str(root)))
    host.chmod(0o755)
    result = subprocess.run([host], env=dict(os.environ, TMPDIR=str(root)), text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    runtime_dir = next(line.removeprefix("RUNTIME=") for line in result.stdout.splitlines() if line.startswith("RUNTIME="))
    assert not Path(runtime_dir).exists()

print("PASS: completed door removes its PID file; cleanup checks process start time and clears the runtime")

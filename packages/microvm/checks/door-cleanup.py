# cspell:ignore guestfwd prctl socketpair
"""Exercise door cleanup against live commands, stale identities and exit statuses."""

import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time


def process_fields(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()
    except FileNotFoundError:
        return None


def stopped(pid):
    fields = process_fields(pid)
    return fields is None or fields[0] == "Z"


if sys.argv[1] == "--runner":
    root = Path(os.environ["TEST_ROOT"])
    runtime = Path.cwd()
    door = subprocess.Popen([os.environ["TEST_WRAPPER"]], stdin=int(os.environ["TEST_SOCKET"]), stdout=subprocess.PIPE, text=True)
    header = door.stdout.readline().split()
    pid = int(header[1])
    command = int(Path(f"/proc/{pid}/task/{pid}/children").read_text().strip())
    sentinel = int(os.environ["TEST_SENTINEL"])
    # The stale record has a live PID but the wrong start time. Its comm contains
    # spaces and a closing parenthesis, like names the /proc parser must tolerate.
    start = int(process_fields(sentinel)[19])
    (runtime / "door-7000-stale.pid").write_text(f"{sentinel} {start + 1}\n")
    (runtime / "door-7000-empty.pid").touch()
    (runtime / "status").write_text(f"exited:{os.environ['TEST_GUEST_STATUS']}\n")
    (runtime / "bundle-status").write_text("empty\n")
    (root / "report").write_text(json.dumps(dict(command=command, door=pid, runtime=str(runtime))))
    raise SystemExit(int(os.environ["TEST_RUNNER_STATUS"]))

launcher, runner, network_device, *mode = sys.argv[1:]
match = re.search(r"guestfwd=tcp:10\.0\.2\.100:7000-cmd:(\S+)", network_device)
assert match, network_device
wrapper = match.group(1)

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    checkout = root / "checkout"
    checkout.mkdir()
    env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
    if mode == ["--repo"]:
        subprocess.run(["git", "init", "--quiet", "--initial-branch=fixture", str(checkout)], env=env, check=True)
        subprocess.run(["git", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "--allow-empty", "-m", "fixture"], cwd=checkout, env=env, check=True)
    result = subprocess.run([wrapper], cwd=root, env=dict(os.environ, SANDBOX_DOOR_TEST_MARKER="host-only"), stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert not list(root.glob("door-*.pid")), "completed door left its PID file"
    assert "MARKER None" in result.stdout
    assert (root / "doors.log").read_text() == "DOOR_STDERR_MUST_NOT_REACH_GUEST\n"

    stub = root / "runner"
    stub.write_text(f"#!{sys.executable}\nimport runpy, sys\nsys.argv = [{__file__!r}, '--runner']\nrunpy.run_path({__file__!r}, run_name='__main__')\n")
    stub.chmod(0o755)
    host = root / "host"
    source = Path(launcher).read_text()
    assert source.count(runner) == 1
    host.write_text(source.replace(runner, str(stub)).replace("/dev/kvm", str(root)))
    host.chmod(0o755)
    sentinel = subprocess.Popen([sys.executable, "-c", "import ctypes, signal; ctypes.CDLL(None).prctl(15, b'stale) door pid'); signal.pause()"], start_new_session=True)
    try:
        for guest_status, runner_status, expected in [(0, 0, 0), (37, 0, 37), (0, 17, 125)]:
            connection, peer = socket.socketpair()
            try:
                result = subprocess.run(
                    [host],
                    cwd=checkout,
                    env=dict(env, TEST_GUEST_STATUS=str(guest_status), TEST_ROOT=str(root), TEST_RUNNER_STATUS=str(runner_status), TEST_SENTINEL=str(sentinel.pid), TEST_SOCKET=str(connection.fileno()), TEST_WRAPPER=wrapper, TMPDIR=str(root)),
                    pass_fds=(connection.fileno(),), text=True, capture_output=True, timeout=10,
                )
                report = json.loads((root / "report").read_text())
                assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
                assert ("VM runner failed" in result.stderr) == bool(runner_status), result.stderr
                assert not Path(report["runtime"]).exists()
                for _ in range(100):
                    if stopped(report["door"]) and stopped(report["command"]):
                        break
                    time.sleep(0.01)
                assert stopped(report["door"]) and stopped(report["command"]), report
                assert sentinel.poll() is None, "stale record killed an unrelated process"
                print(f"PASS: repo={bool(mode)} guest={guest_status} runner={runner_status} launcher={result.returncode}; live door and command stopped, stale PID spared, empty record ignored, runtime removed")
            finally:
                connection.close()
                peer.close()
    finally:
        sentinel.terminate()
        sentinel.wait(timeout=5)

print("PASS: completed door removes its PID file; live cleanup preserves process identity and launcher status")

# cspell:ignore ABRT virtio
"""Exercise the production host parser and guest decoder without KVM."""

import concurrent.futures
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

launcher, runner, guest, python, completion, systemctl = sys.argv[1:]
cases = [
    [],
    ["--"],
    ["--", ""],
    ["--", "a b", "", "'\"", "line\nbreak", "雪", "--", "$(touch injected); *"],
    ["--", "x" * 16384],
    ["--", os.fsdecode(bytes([255]))],
]


def digest(args):
    return hashlib.sha256(b"".join(os.fsencode(arg) + b"\0" for arg in args)).hexdigest()


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    guest_script = root / "guest"
    guest_script.write_text(
        Path(guest).read_text().replace("/run/sandbox/argv", '"$SANDBOX_ARGV_FILE"')
    )
    guest_script.chmod(0o755)
    stub = root / "runner"
    stub.write_text(
        f"#!{python}\n"
        "import os, pathlib, subprocess, time\n"
        "cwd = pathlib.Path.cwd()\n"
        "assert cwd.stat().st_mode & 0o777 == 0o700\n"
        "assert (cwd / 'argv').stat().st_mode & 0o777 == 0o600\n"
        "print('RUNTIME=' + str(cwd), flush=True)\n"
        "time.sleep(0.2)\n"
        "os.environ['SANDBOX_ARGV_FILE'] = str(cwd / 'argv')\n"
        f"subprocess.run([{str(guest_script)!r}], check=True)\n"
        "(cwd / 'status').write_text(os.environ.get('GUEST_STATUS', 'exited:0\\n'))\n"
        "raise SystemExit(int(os.environ.get('RUNNER_EXIT', '0')))\n"
    )
    stub.chmod(0o755)
    host = root / "host"
    source = Path(launcher).read_text()
    assert source.count(runner) == 1
    assert source.count("/dev/kvm") == 3
    host.write_text(source.replace(runner, str(stub)).replace("/dev/kvm", str(root)))
    host.chmod(0o755)
    env = dict(os.environ, TMPDIR=str(root))

    def invoke(args):
        return subprocess.run([str(host), *args], env=env, text=True, capture_output=True)

    with concurrent.futures.ThreadPoolExecutor() as pool:
        results = list(pool.map(invoke, cases))
    runtime_dirs = []
    for args, result in zip(cases, results, strict=True):
        assert result.returncode == 0, result.stderr
        forwarded = args[1:] if args else []
        assert f"SANDBOX_ARGV={len(forwarded)}:{digest(forwarded)}:" in result.stdout
        runtime_dir = next(line.removeprefix("RUNTIME=") for line in result.stdout.splitlines() if line.startswith("RUNTIME="))
        assert not Path(runtime_dir).exists()
        runtime_dirs.append(runtime_dir)
    assert len(set(runtime_dirs)) == len(cases)
    assert not (root / "injected").exists()
    for invalid in ["--help", "--version", "hello", ""]:
        result = invoke([invalid])
        assert result.returncode == 2
        assert "use -- before guest arguments" in result.stderr
        assert not result.stdout
    env["RUNNER_EXIT"] = "17"
    result = invoke([])
    assert result.returncode == 125
    assert "VM runner failed" in result.stderr
    runtime_dir = next(line.removeprefix("RUNTIME=") for line in result.stdout.splitlines() if line.startswith("RUNTIME="))
    assert not Path(runtime_dir).exists()
    env.pop("RUNNER_EXIT")
    for status, expected in [
        ("exited:42\n", 42),
        ("exited:255\n", 255),
        ("killed:TERM\n", 143),
        ("killed:32\n", 160),
        ("killed:33\n", 161),
        ("killed:0\n", 125),
        ("killed:65\n", 125),
        ("dumped:ABRT\n", 134),
        ("", 125),
        ("exited:256\n", 125),
        ("exited:0\nexited:42\n", 125),
        ("killed:INVALID\n", 125),
    ]:
        env["GUEST_STATUS"] = status
        result = invoke([])
        assert result.returncode == expected, (status, result.returncode, result.stderr)
        if expected == 125:
            assert "without a valid guest completion" in result.stderr
    assert sorted(p.name for p in root.iterdir()) == ["guest", "host", "runner"]
print("PASS: parser, exact argv, zero/empty distinction, injection, parallel isolation, completion statuses, VM failure and cleanup")

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    reboot = root / "reboot"
    reboot.write_text(f"#!{python}\nimport os, pathlib\npathlib.Path(os.environ['REBOOT_FILE']).touch()\n")
    reboot.chmod(0o755)
    reporter = root / "reporter"
    source = Path(completion).read_text()
    assert source.count(systemctl) == 1
    reporter.write_text(source.replace(systemctl, str(reboot)).replace("/dev/virtio-ports/sandbox.status", '"$STATUS_FILE"'))
    reporter.chmod(0o755)
    status_file = root / "status"
    reboot_file = root / "rebooted"
    env = {k: v for k, v in os.environ.items() if k not in ("EXIT_CODE", "EXIT_STATUS", "SERVICE_RESULT")}
    env.update(STATUS_FILE=str(status_file), REBOOT_FILE=str(reboot_file))
    for service, code, status, expected in [
        ("success", "exited", "0", "exited:0\n"),
        ("exit-code", "exited", "42", "exited:42\n"),
        ("signal", "killed", "TERM", "killed:TERM\n"),
        ("core-dump", "dumped", "ABRT", "dumped:ABRT\n"),
        ("exit-code", "", "", ""),  # ExecStartPre fails; no main process.
        ("timeout", "killed", "TERM", ""),
    ]:
        result = subprocess.run([str(reporter)], env=dict(env, SERVICE_RESULT=service, EXIT_CODE=code, EXIT_STATUS=status), capture_output=True)
        assert result.returncode == 0, result.stderr
        assert reboot_file.exists()
        assert (status_file.read_text() if status_file.exists() else "") == expected
        status_file.unlink(missing_ok=True)
        reboot_file.unlink()
    result = subprocess.run([str(reporter)], env=dict(env, SERVICE_RESULT="success", EXIT_CODE="exited", EXIT_STATUS="0", STATUS_FILE=str(root / "missing" / "status")), capture_output=True)
    assert result.returncode != 0
    assert reboot_file.exists()
print("PASS: guest completion, preparation failure, timeout rejection and reboot after reporting failure")

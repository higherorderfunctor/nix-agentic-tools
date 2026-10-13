"""Exercise the production host parser and guest decoder without KVM."""

import concurrent.futures
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

launcher, runner, guest, python = sys.argv[1:]
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
    assert result.returncode == 17
    runtime_dir = next(line.removeprefix("RUNTIME=") for line in result.stdout.splitlines() if line.startswith("RUNTIME="))
    assert not Path(runtime_dir).exists()
print("PASS: parser, exact argv, zero/empty distinction, injection, parallel isolation and cleanup")

# cspell:ignore ABRT undelimited virtio
"""Exercise the production host parser and guest decoder without KVM."""

import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

launcher, runner, guest, python, completion, systemctl = sys.argv[1:]


def write_executable(path, source):
    path.write_text(source)
    path.chmod(0o755)
    return path


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    guest_script = write_executable(
        root / "guest",
        Path(guest).read_text().replace("/run/sandbox/argv", '"$SANDBOX_ARGV_FILE"'),
    )
    stub = write_executable(
        root / "runner",
        f"#!{python}\n"
        "import os, pathlib, subprocess, time\n"
        "cwd = pathlib.Path.cwd()\n"
        "assert cwd.stat().st_mode & 0o777 == 0o700, 'runtime directory is not private'\n"
        "assert (cwd / 'argv').stat().st_mode & 0o777 == 0o600, 'argv is not private'\n"
        "print('RUNTIME=' + str(cwd), flush=True)\n"
        # Keep runners alive long enough for parallel calls to contend for the directory.
        "time.sleep(0.2)\n"
        "os.environ['SANDBOX_ARGV_FILE'] = str(cwd / 'argv')\n"
        f"subprocess.run([{str(guest_script)!r}], check=True)\n"
        "(cwd / 'status').write_text(os.environ['GUEST_STATUS'])\n"
        "raise SystemExit(int(os.environ['RUNNER_EXIT']))\n",
    )
    source = Path(launcher).read_text()
    assert source.count(runner) == 1 and "/dev/kvm" in source, "host fixture seams moved"
    host = write_executable(
        root / "host", source.replace(runner, str(stub)).replace("/dev/kvm", str(root))
    )
    env = dict(os.environ, LC_ALL="C", TMPDIR=str(root), GUEST_STATUS="exited:0\n", RUNNER_EXIT="0")

    def invoke(args=(), **overrides):
        return subprocess.run([str(host), *args], env=env | overrides, text=True, capture_output=True)

    def observation(result, key):
        (value,) = [line[len(key):] for line in result.stdout.splitlines() if line.startswith(key)]
        return value

    def removed_runtime(result, case):
        runtime = Path(observation(result, "RUNTIME="))
        assert not runtime.exists(), (case, runtime)
        return runtime

    # The marker stays observable even after the launcher cleans up the guest's cwd.
    shell_text = '$(touch "$TMPDIR/injected"); *'
    argv_cases = [
        ("bare invocation does not synthesize an empty argument", [], []),
        ("delimiter alone does not forward the delimiter", ["--"], []),
        ("a single empty argument is not dropped", ["--", ""], [b""]),
        (
            "arguments keep their order, word boundaries and shell metacharacters",
            ["--", "a b", "", "'\"", "line\nbreak", "雪", "--", shell_text],
            [b"a b", b"", b"'\"", b"line\nbreak", b"\xe9\x9b\xaa", b"--", b'$(touch "$TMPDIR/injected"); *'],
        ),
        ("a payload larger than a page is not truncated", ["--", "x" * 16384], [b"x" * 16384]),
        ("an argument need not be valid UTF-8", ["--", os.fsdecode(b"\xff")], [b"\xff"]),
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(argv_cases)) as pool:
        results = list(pool.map(invoke, (args for _, args, _ in argv_cases)))
    runtime_dirs = []
    for (case, _, expected), result in zip(argv_cases, results, strict=True):
        assert result.returncode == 0, (case, result.stderr)
        # Compare observed guest argv bytes, not the launcher's NUL encoding.
        actual = [bytes.fromhex(arg) for arg in json.loads(observation(result, "SANDBOX_ARGV="))]
        assert actual == expected, case
        runtime_dirs.append(removed_runtime(result, case))
    assert len(set(runtime_dirs)) == len(argv_cases), "parallel launches reused a runtime directory"
    assert not (root / "injected").exists(), "guest argument executed a shell substitution"

    for case, invalid in [
        ("an empty host argument is not a bare invocation", ""),
        ("a reserved flag does not print generated help", "--help"),
        ("an undelimited word does not become guest argv", "hello"),
    ]:
        result = invoke([invalid])
        assert result.returncode == 2, (case, result)
        assert "use -- before guest arguments" in result.stderr, (case, result)
        assert not result.stdout, (case, "invalid invocation reached the runner", result.stdout)

    # The stub reports success before failing; the runner failure must take precedence.
    result = invoke(RUNNER_EXIT="17")
    assert result.returncode == 125 and "VM runner failed" in result.stderr, result

    invalid_completion = "without a valid guest completion"
    for case, status, expected, diagnostic in [
        ("an absent record does not imply guest success", "", 125, invalid_completion),
        ("an exit above 255 does not wrap to success", "exited:256\n", 125, invalid_completion),
        ("an ordinary guest exit is not replaced with the runner exit", "exited:42\n", 42, None),
        ("exit 125 from the guest is not a transport failure", "exited:125\n", 125, None),
        ("the maximum guest exit is accepted", "exited:255\n", 255, None),
        ("a core dump uses the signal exit convention", "dumped:ABRT\n", 134, None),
        ("a named signal resolves to its signal exit", "killed:TERM\n", 143, None),
        ("a raw signal without a Bash name is accepted", "killed:32\n", 160, None),
        ("an out-of-range high signal is rejected", "killed:65\n", 125, invalid_completion),
        ("signal zero is not a termination signal", "killed:0\n", 125, invalid_completion),
        ("an unrecognized signal name fails resolution", "killed:INVALID\n", 125, invalid_completion),
        ("two completion records are not accepted as one", "exited:0\nexited:42\n", 125, invalid_completion),
    ]:
        result = invoke(GUEST_STATUS=status)
        assert result.returncode == expected, (case, result)
        if diagnostic is not None:
            assert diagnostic in result.stderr, (case, result)
        else:
            assert not result.stderr, (case, result)
    assert sorted(p.name for p in root.iterdir()) == ["guest", "host", "runner"], "completion handling leaked a runtime directory"
print("PASS: parser, exact argv, zero/empty distinction, injection, parallel isolation, completion statuses, VM failure and cleanup")

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    reboot = write_executable(
        root / "reboot",
        f"#!{python}\nimport os, pathlib, sys\n"
        "assert sys.argv[1:] == ['--no-block', 'reboot'], sys.argv[1:]\n"
        "pathlib.Path(os.environ['REBOOT_FILE']).touch()\n",
    )
    source = Path(completion).read_text()
    assert source.count(systemctl) == 1, "reboot fixture seam moved"
    reporter = write_executable(
        root / "reporter",
        source.replace(systemctl, str(reboot)).replace("/dev/virtio-ports/sandbox.status", '"$STATUS_FILE"'),
    )
    status_file = root / "status"
    reboot_file = root / "rebooted"
    env = dict(os.environ, LC_ALL="C", REBOOT_FILE=str(reboot_file))

    def report(service, code, status, destination=status_file):
        return subprocess.run(
            [str(reporter)],
            env=dict(env, SERVICE_RESULT=service, EXIT_CODE=code, EXIT_STATUS=status, STATUS_FILE=str(destination)),
            text=True,
            capture_output=True,
        )

    for case, service, code, status, expected in [
        ("success publishes an explicit zero exit", "success", "exited", "0", "exited:0\n"),
        ("normal failure publishes the actual exit", "exit-code", "exited", "42", "exited:42\n"),
        ("signal termination publishes a named signal", "signal", "killed", "TERM", "killed:TERM\n"),
        ("core dump is reported as such", "core-dump", "dumped", "ABRT", "dumped:ABRT\n"),
        ("preparation failure does not invent main-process status", "exit-code", "", "", None),
        ("timeout does not publish its kill as normal completion", "timeout", "killed", "TERM", None),
    ]:
        result = report(service, code, status)
        assert result.returncode == 0, (case, result)
        assert reboot_file.exists(), (case, "reporter did not request reboot")
        assert (status_file.read_text() if status_file.exists() else None) == expected, case
        status_file.unlink(missing_ok=True)
        reboot_file.unlink()

    missing = root / "missing" / "status"
    result = report("success", "exited", "0", missing)
    assert result.returncode == 1 and f"{missing}: No such file or directory" in result.stderr, result
    assert reboot_file.exists(), "failed write skipped the reboot request"
print("PASS: guest completion, preparation failure, timeout rejection and reboot after reporting failure")

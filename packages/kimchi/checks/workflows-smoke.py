"""Credential-free external registration and slash-command dispatch contract."""
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile

kimchi, package, observer = sys.argv[1:]
entry = str(Path(package) / "src/host/extension.ts")
with tempfile.TemporaryDirectory() as scratch:
    root = Path(scratch)
    for name, configured, project, negative in [
        ("global", True, False, False),
        ("project", True, True, False),
        ("absent", False, False, True),
    ]:
        base = root / name
        home, cwd = base / "home", base / "project"
        home.mkdir(parents=True)
        cwd.mkdir()
        env = {"HOME": str(home), "PATH": os.environ["PATH"], "KIMCHI_ENABLE_RESOURCES": "", "KIMCHI_TELEMETRY_ENABLED": "0"}
        for key, directory in [
            ("TMPDIR", "tmp"),
            ("XDG_CACHE_HOME", "cache"),
            ("XDG_CONFIG_HOME", "config"),
            ("XDG_DATA_HOME", "data"),
            ("XDG_RUNTIME_DIR", "runtime"),
            ("XDG_STATE_HOME", "state"),
        ]:
            path = base / directory
            path.mkdir(mode=0o700)
            env[key] = str(path)
        if configured:
            settings = (cwd if project else home) / ".config/kimchi/harness/settings.json"
            settings.parent.mkdir(parents=True)
            settings.write_text(json.dumps({"extensions": [entry]}))
        args = [kimchi]
        if project:
            args.append("--approve")
        args += ["--mode", "json", "--session-dir", str(base / "sessions"), "-e", observer, "-p", "/workflow list"]
        with subprocess.Popen(args, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True) as process:
            try:
                stdout, stderr = process.communicate(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                raise
            result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
        assert result.returncode == 0, (name, result.stdout, result.stderr)
        assert "Extension error" not in result.stderr and "Failed to load extension" not in result.stderr, result.stderr
        lines = result.stderr.splitlines()
        commands = json.loads(next(line.removeprefix("E2E_COMMANDS ") for line in lines if line.startswith("E2E_COMMANDS ")))
        counts = json.loads(next(line.removeprefix("E2E_COUNTS ") for line in lines if line.startswith("E2E_COUNTS ")))
        assert counts == {"agent_start": 0, "input": int(negative), "model_requests": 0}, (name, counts)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        assert events and all(event["type"] == "session" for event in events), (name, events)
        if negative:
            assert commands == [] and "E2E_NOTIFY" not in result.stderr, result.stderr
        else:
            assert len(commands) == 1 and commands[0]["name"] == "workflow", commands
            assert commands[0]["sourceInfo"]["path"] == entry, commands
            assert "E2E_NOTIFY" in result.stderr and "No workflows found in" in result.stderr, result.stderr
        print(f"PASS: {name}")

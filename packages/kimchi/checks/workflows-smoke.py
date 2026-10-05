"""Credential-free package registration, toggle and slash-command contract."""
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile

kimchi, package, observer = sys.argv[1:]
source = "extensions/workflows"


def run(args, cwd, env):
    with subprocess.Popen(args, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
        result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result


def dispatch(args, cwd, env, negative):
    result = run(args, cwd, env)
    assert "Extension error" not in result.stderr and "Failed to load extension" not in result.stderr, result.stderr
    lines = result.stderr.splitlines()
    commands = json.loads(next(line.removeprefix("E2E_COMMANDS ") for line in lines if line.startswith("E2E_COMMANDS ")))
    counts = json.loads(next(line.removeprefix("E2E_COUNTS ") for line in lines if line.startswith("E2E_COUNTS ")))
    assert counts == {"agent_start": 0, "input": int(negative), "model_requests": 0}, counts
    events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    assert events and all(event["type"] == "session" for event in events), events
    if negative:
        assert commands == [] and "E2E_NOTIFY" not in result.stderr, result.stderr
    else:
        assert len(commands) == 1 and commands[0]["name"] == "workflow", commands
        assert commands[0]["sourceInfo"]["source"] == source, commands
        assert "E2E_NOTIFY" in result.stderr and "No workflows found in" in result.stderr, result.stderr


with tempfile.TemporaryDirectory() as scratch:
    root = Path(scratch)
    for name, configured, project in [
        ("global", True, False),
        ("project", True, True),
        ("absent", False, False),
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
        user_settings = home / ".config/kimchi/harness/settings.json"
        if configured:
            settings = (cwd if project else home) / ".config/kimchi/harness/settings.json"
            link = settings.parent / source
            link.parent.mkdir(parents=True)
            link.symlink_to(package, target_is_directory=True)
            settings.write_text(json.dumps({"packages": [source]}))
        trust_args = ["--approve"] if project else []
        listing_args = [kimchi, "resources", "list", *trust_args]
        listing = run(listing_args, cwd, env)
        rows = [line.split(maxsplit=2) for line in listing.stdout.splitlines() if "plugins.package." in line]
        if configured:
            assert len(rows) == 1 and rows[0][0] == "enabled" and source in rows[0][2], listing.stdout
            resource_id = rows[0][1]
        else:
            assert rows == [], listing.stdout
        args = [kimchi, *trust_args, "--mode", "json", "--session-dir", str(base / "sessions"), "-e", observer, "-p", "/workflow list"]
        dispatch(args, cwd, env, negative=not configured)
        print(f"PASS: {name}")
        if configured:
            # Resource toggles are user scope even for project packages.
            user_settings.parent.mkdir(parents=True, exist_ok=True)
            declared = json.loads(user_settings.read_text()) if user_settings.exists() else {}
            declared["resources"] = {resource_id: False}
            user_settings.write_text(json.dumps(declared))
            disabled_listing = run(listing_args, cwd, env)
            assert any(line.split()[:2] == ["disabled", resource_id] for line in disabled_listing.stdout.splitlines()), disabled_listing.stdout
            dispatch(args, cwd, env, negative=True)
            print(f"PASS: {name}-disabled")

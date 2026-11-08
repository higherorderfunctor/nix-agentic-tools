"""Credential-free package registration, toggle and slash-command contract."""
import json
import os
import shutil
import signal
from pathlib import Path
import subprocess
import sys
import tempfile

kimchi, package, observer, delivery = sys.argv[1:]
delivered = {entry["name"]: entry for entry in json.loads(Path(delivery).read_text())}
source = "packages/workflows"


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


def fixture(base):
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
    return home, cwd, env


with tempfile.TemporaryDirectory() as scratch:
    root = Path(scratch)
    for name, configured, project in [
        ("global", True, False),
        ("project", True, True),
        ("absent", False, False),
    ]:
        base = root / name
        home, cwd, env = fixture(base)
        user_settings = home / ".config/kimchi/harness/settings.json"
        if configured:
            settings = (cwd if project else home) / ".config/kimchi/harness/settings.json"
            link = settings.parent / source
            link.parent.mkdir(parents=True)
            artifact = Path(delivered[name]["extension"])
            # Every entry is an absolute link into the original package, with
            # no dependency payload copied into the generated delivery tree.
            entries = list(artifact.iterdir())
            assert {entry.name for entry in entries} == {entry.name for entry in Path(package).iterdir()}, artifact
            for entry in entries:
                assert entry.is_symlink() and entry.readlink() == Path(package) / entry.name, entry
            link.symlink_to(artifact, target_is_directory=True)
            shutil.copyfile(delivered[name]["settings"], settings)
        trust_args = ["--approve"] if project else []
        listing_args = [kimchi, "resources", "list", *trust_args]
        listing = run(listing_args, cwd, env)
        rows = [line.split(maxsplit=2) for line in listing.stdout.splitlines() if "plugins.package." in line]
        if configured:
            assert len(rows) == 1 and rows[0][0] == "enabled" and source in rows[0][2], listing.stdout
            resource_id = rows[0][1]
            assert resource_id == "plugins.package.packages-workflows", resource_id
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

    # The child normally follows a background step spawn. This check starts it
    # directly and dispatches an observer command instead, so no credentials or
    # inference are needed. Copy src to model two installed copies with distinct
    # real entry paths; runtime dependencies still come from the built package.
    output_schema = {
        "additionalProperties": False,
        "properties": {"answer": {"type": "string"}},
        "required": ["answer"],
        "type": "object",
    }
    for name, handoff, expected_tools, expected_commands in [
        # Output-schema handoff through saved-trust bootstrap.
        ("valid", {"identity": {"attempt": 1, "path": "step", "runId": "smoke"}, "outputSchema": output_schema}, ["workflow_submit_result"], []),
        # Ordinary and invalid-handoff controls.
        ("absent", None, [], ["workflow"]),
        ("malformed", "{", [], []),
    ]:
        base = root / ("handoff-" + name)
        home, cwd, env = fixture(base)
        for scope, parent in [("global", home), ("project", cwd)]:
            harness = parent / ".config/kimchi/harness"
            payload = harness / source
            payload.mkdir(parents=True)
            for entry in Path(package).iterdir():
                if entry.name == "src":
                    shutil.copytree(entry, payload / entry.name)
                else:
                    (payload / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
            settings = json.loads(Path(delivered[scope]["settings"]).read_text())
            # Keep both production declarations; a one-scope fixture hides the bug.
            assert settings["packages"] == [source], settings
            if scope == "global":
                # User scope only, as in production: trust then comes from trust.json alone.
                settings["defaultProjectTrust"] = "ask"
            (harness / "settings.json").write_text(json.dumps(settings))
        (home / ".config/kimchi/harness/trust.json").write_text(json.dumps({str(cwd): True}))
        if handoff is not None:
            # Match writeStepOutputToolSpec's JSON shape, including its identity.
            note = base / "step.output-tools.json"
            note.write_text(json.dumps(handoff) if isinstance(handoff, dict) else handoff)
            env["KIMCHI_WORKFLOW_STEP_OUTPUT_TOOLS"] = str(note)
        args = [kimchi, "--mode", "json", "--session-dir", str(base / "sessions"), "-e", observer, "-p", "/e2e_probe"]
        result = run(args, cwd, env)
        assert "Extension error" not in result.stderr and "Failed to load extension" not in result.stderr, result.stderr
        lines = result.stderr.splitlines()
        observation = json.loads(next(line.removeprefix("E2E_HANDOFF ") for line in lines if line.startswith("E2E_HANDOFF ")))
        counts = json.loads(next(line.removeprefix("E2E_COUNTS ") for line in lines if line.startswith("E2E_COUNTS ")))
        tool_names = [tool["name"] for tool in observation["submit"]]
        command_names = [command["name"] for command in observation["workflowCommands"]]
        print(f"handoff-{name}: exit={result.returncode} submit={tool_names} workflow={command_names} env={observation['handoffEnvPresent']} counts={counts}", flush=True)
        # Catch consumed-but-lost handoffs, duplicate tools and accidental asks.
        assert tool_names == expected_tools, "missing or unexpected submit tools after saved-trust bootstrap: " + repr(observation)
        # Invalid handoffs must stay steps; ordinary sessions must stay hosts.
        assert command_names == expected_commands, observation
        if expected_tools:
            # A generic submit schema would lose the step's required answer.
            assert observation["submit"][0]["parameters"]["properties"]["result"] == output_schema, observation
        # The environment transport must not survive for descendant processes.
        assert observation["handoffEnvPresent"] is False, observation
        # Fail if the probe falls through to ordinary input or inference.
        assert counts == {"agent_start": 0, "input": 0, "model_requests": 0}, counts
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        # Agent output would reveal dispatch beyond the observer command.
        assert events and all(event["type"] == "session" for event in events), events
        print(f"PASS: handoff-{name}")

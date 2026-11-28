"""Credential-free package registration, toggle and slash-command contract."""
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

kimchi, package, observer, delivery = sys.argv[1:]
delivered = {entry["name"]: entry for entry in json.loads(Path(delivery).read_text())}
source = "packages/workflows"
resource_id = "plugins.package.packages-workflows"


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


def observation(lines, tag):
    prefix = tag + " "
    matches = [line.removeprefix(prefix) for line in lines if line.startswith(prefix)]
    assert len(matches) == 1, (tag, lines)
    return json.loads(matches[0])


def probe(args, cwd, env, *, expected_input):
    result = run(args, cwd, env)
    assert "Extension error" not in result.stderr and "Failed to load extension" not in result.stderr, result.stderr
    lines = result.stderr.splitlines()
    # Unregistered commands alone should reach input; no row may start inference.
    counts = observation(lines, "E2E_COUNTS")
    assert counts == {"agent_start": 0, "input": expected_input, "model_requests": 0}, counts
    events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    assert events, events
    return lines


def dispatch(args, cwd, env, *, enabled):
    lines = probe(args, cwd, env, expected_input=0 if enabled else 1)
    commands = observation(lines, "E2E_COMMANDS")
    assert [command["name"] for command in commands] == (["workflow"] if enabled else []), commands
    if enabled:
        assert commands[0]["sourceInfo"]["source"] == source, commands
        # Registration alone does not prove the slash command reached its handler.
        notifications = [json.loads(line.removeprefix("E2E_NOTIFY ")) for line in lines if line.startswith("E2E_NOTIFY ")]
        assert any("No workflows found in" in item["message"] for item in notifications), notifications
    else:
        assert not any(line.startswith("E2E_NOTIFY ") for line in lines), lines


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


def resource_rows(args, cwd, env):
    result = run(args, cwd, env)
    return [line.split(maxsplit=2) for line in result.stdout.splitlines() if "plugins.package." in line]


with tempfile.TemporaryDirectory() as scratch:
    root = Path(scratch)
    for name, configured, project in [
        # No declaration must not activate a leftover builtin extension.
        ("absent", False, False),
        # User delivery must load without requiring project trust.
        ("global", True, False),
        # An approved project settings file must resolve its own package path.
        ("project", True, True),
    ]:
        base = root / name
        home, cwd, env = fixture(base)
        user_settings = home / ".config/kimchi/harness/settings.json"
        if configured:
            settings = (cwd if project else home) / ".config/kimchi/harness/settings.json"
            link = settings.parent / source
            link.parent.mkdir(parents=True)
            artifact = Path(delivered[name]["extension"])
            if name == "global":
                # Both backends stage the same link tree. Check its shape once to
                # catch a copied dependency payload instead of absolute links.
                entries = list(artifact.iterdir())
                names = {entry.name for entry in entries}
                assert names == {entry.name for entry in Path(package).iterdir()}, artifact
                for entry in entries:
                    assert entry.is_symlink() and entry.readlink() == Path(package) / entry.name, entry
            link.symlink_to(artifact, target_is_directory=True)
            shutil.copyfile(delivered[name]["settings"], settings)
        trust_args = ["--approve"] if project else []
        listing_args = [kimchi, "resources", "list", *trust_args]
        rows = resource_rows(listing_args, cwd, env)
        assert [row[:2] for row in rows] == ([["enabled", resource_id]] if configured else []), rows
        if configured:
            assert source in rows[0][2], rows
        args = [kimchi, *trust_args, "--mode", "json", "--session-dir", str(base / "sessions"), "-e", observer, "-p", "/workflow list"]
        dispatch(args, cwd, env, enabled=configured)
        print(f"PASS: {name}")
        if configured:
            # Resource toggles are user scope even for project packages.
            user_settings.parent.mkdir(parents=True, exist_ok=True)
            declared = json.loads(user_settings.read_text()) if user_settings.exists() else {}
            declared["resources"] = {resource_id: False}
            user_settings.write_text(json.dumps(declared))
            rows = resource_rows(listing_args, cwd, env)
            assert [row[:2] for row in rows] == [["disabled", resource_id]], rows
            dispatch(args, cwd, env, enabled=False)
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
        # No handoff must leave normal host registration intact.
        ("absent", None, [], ["workflow"]),
        # A malformed handoff must not fall back to host registration.
        ("malformed", "{", [], []),
        # Saved-trust bootstrap must not consume the handoff before registration.
        ("valid", {"identity": {"attempt": 1, "path": "step", "runId": "smoke"}, "outputSchema": output_schema}, ["workflow_submit_result"], []),
    ]:
        base = root / ("handoff-" + name)
        home, cwd, env = fixture(base)
        # Keep both production declarations; a one-scope fixture hides the bug.
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
        lines = probe(args, cwd, env, expected_input=0)
        handoff_state = observation(lines, "E2E_HANDOFF")
        tool_names = [tool["name"] for tool in handoff_state["submit"]]
        command_names = [command["name"] for command in handoff_state["workflowCommands"]]
        # Catch consumed-but-lost handoffs, duplicate tools and accidental asks.
        assert tool_names == expected_tools, "missing or unexpected submit tools after saved-trust bootstrap: " + repr(handoff_state)
        # Invalid handoffs must stay steps; ordinary sessions must stay hosts.
        assert command_names == expected_commands, handoff_state
        if expected_tools or expected_commands:
            # Project-over-user precedence: a surviving user copy registers the same names.
            scopes = {entry["sourceInfo"]["scope"] for entry in handoff_state["submit"] + handoff_state["workflowCommands"]}
            assert scopes == {"project"}, handoff_state
        if expected_tools:
            # A generic submit schema would lose the step's required answer.
            assert handoff_state["submit"][0]["parameters"]["properties"]["result"] == output_schema, handoff_state
            # The environment transport must not survive for descendant processes.
            assert handoff_state["handoffEnvPresent"] is False, handoff_state
        print(f"PASS: handoff-{name}")

"""Execute module-produced wrappers; no provider requests or live credentials."""

import json
import os
from pathlib import Path
import re
import selectors
import shlex
import signal
import subprocess
import sys
from unittest.mock import patch

fixture = json.loads(Path(sys.argv[1]).read_text())
expected = {
    "devenv": ("work", "/tmp/oauth-project/mcp-oauth/devenv/work"),
    "hm": ("personal", "/tmp/oauth-hm/mcp-oauth/hm/personal"),
}
credentials = ["/run/secrets/oauth-id", "/run/secrets/oauth-secret"]


def wrapper_manifest(wrapper):
    # Read the actual wrapper's argv so a dead manifest cannot satisfy the test.
    words = shlex.split(next(line for line in Path(wrapper).read_text().splitlines()
                             if line.startswith("exec ")))
    path = words[words.index("--manifest") + 1]
    return path, json.loads(Path(path).read_text())


def invoke(wrapper, args, env):
    return subprocess.run([wrapper, *args], env=env, text=True, capture_output=True, timeout=10)


for backend, (_, root) in expected.items():
    entry = fixture["proxy"][backend]
    # A client must not see Authorization or the remote address.
    assert entry["clients"] == {
        "meeting": {"type": "http", "url": "http://127.0.0.1:19592/"},
        "messaging": {"type": "http", "url": "http://127.0.0.1:19593/"},
    }
    # Losing scope breaks service ownership even if the client still connects.
    assert entry["rootOwners"] == ["mcp-proxy-meeting"]
    assert entry["runtimeOwners"] == ["mcp-proxy-messaging"]
    assert entry["restartPaths"] == {"mcp-proxy-meeting": [], "mcp-proxy-messaging": []}
    # Read the configuration each real service launches. Do not recompute the
    # renderer's variable name; both references must agree on the same capture.
    token_path = str(Path(root).with_name("work") / "access-token")
    for endpoint in ("meeting", "messaging"):
        name = f"mcp-proxy-{endpoint}"
        script = Path(entry["commands"][name][0]).read_text()
        source = Path(re.search(r"--config (\S+) --adapter", script)[1]).read_text()
        header = re.findall(r'^\s*header_up Authorization "Bearer \{vars\.([^}]+)\}"$', source, re.M)
        assert f"vars {header[0]} {{file.{token_path}}}" in source, (backend, name, source)
        # The URL is the only launcher environment value; the token is not a
        # startup secret and rotating the file must not restart the proxy.
        assert list(entry["proxyEnvironments"][name].values()) == [f"https://mcp.example.test/mcp/{endpoint}"]

    print(f"PASS: {backend} exact clients, owners, token paths and generated header")

sys.path.insert(0, fixture["cliSource"])
import cli

for backend in expected:
    entry = fixture["mounted"][backend]
    # Disabled instances cannot emit accounts; unrelated accounts must survive
    # the mount but not appear in its login picker.
    assert entry["accounts"] == ["sample-personal", "sample-work", "unrelated"]
    assert list(entry["commands"]) == [
        "mcp-oauth-sample-personal", "mcp-oauth-sample-work", "mcp-oauth-unrelated"]
    assert len(entry["logins"]) == 1
    alias = entry["logins"][0]
    assert sorted(path.name for path in Path(alias).parent.iterdir()) == ["sample-login"]
    _, config = wrapper_manifest(alias)
    root = "/tmp/mounted-hm" if backend == "hm" else "/tmp/mounted-project"
    assert entry["claims"] == [
        root + f"/mcp-oauth/{backend}/sample-personal",
        root + f"/mcp-oauth/{backend}/sample-work",
        root + f"/mcp-oauth/{backend}/unrelated"]
    # Catch per-instance state/credential collisions and overwritten scope defaults.
    assert sorted(config["accounts"]) == ["sample-personal", "sample-work", "unrelated"]
    for instance, scopes in (("personal", ["data:read"]), ("work", ["override:read"])):
        account = config["accounts"]["sample-" + instance]
        assert account["login"] == {"instance": instance, "owner": "sample", "profile": "sample"}
        assert account["provider"] == {
            "authorizeUrl": "https://identity.example/authorize",
            "extraScopes": ["keys:read"], "loginLifetimeDays": 30,
            "tokenUrl": "https://identity.example/token"}
        assert account["scopes"] == scopes
        assert account["client_id_file"] == f"/run/secrets/{instance}-id"
        assert account["client_secret_file"] == f"/run/secrets/{instance}-secret"
        assert account["state_dir"] == root + f"/mcp-oauth/{backend}/sample-{instance}"
    with patch.object(cli.sys.stdin, "isatty", return_value=True), patch.object(
        cli.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "sample-work\n")
    ) as picker:
        assert cli.owner_selection(config, "sample", None) == "sample-work"
        options = picker.call_args.args[0][5:]
        assert options == ["personal — login required (no state)\tsample-personal",
                           "work — login required (no state)\tsample-work"]
    assert cli.owner_selection(config, "sample", "work") == "sample-work"
    # Resolve the public ID with no client ID available to start provider login.
    assert not Path(config["accounts"]["sample-work"]["client_id_file"]).exists()
    result = invoke(alias, ["work"], os.environ)
    assert result.returncode == 1 and "unknown instance" not in result.stderr, result
    for reason, args, code, message in (
        ("disabled instance must not resolve", ["disabled"], 1, "unknown instance"),
        ("unrelated account must not resolve", ["unrelated"], 1, "unknown instance"),
        ("internal ID must not resolve", ["sample-work"], 1, "unknown instance"),
        ("alias cannot change owner", ["--owner", "other"], 2, "backend options cannot be overridden"),
    ):
        result = invoke(alias, args, os.environ)
        assert (result.returncode, result.stderr.strip()) == (code, f"mcp-oauth: {message}"), (reason, result)

    print(f"PASS: {backend} mounted defaults, overrides, single login, isolated accounts and selection")

fixture = fixture["backends"]

for backend, (name, root) in expected.items():
    entry = fixture[backend]
    wrapper = entry["command"][0]
    other = fixture["devenv" if backend == "hm" else "hm"]["command"][0]
    manifest_path, manifest = wrapper_manifest(wrapper)
    # Losing backend identity or including the disabled account changes discovery.
    assert manifest["backend"] == backend
    assert list(manifest["accounts"]) == [name], manifest
    assert manifest["accounts"][name] == {
        "client_id_file": credentials[0],
        "client_secret_file": credentials[1],
        "login": None,
        "provider": {
            "authorizeUrl": "https://identity.example/authorize",
            "extraScopes": ["keys:read"] if backend == "devenv" else [],
            "loginLifetimeDays": 30 if backend == "devenv" else None,
            "tokenUrl": "https://identity.example/token",
        },
        "redirect_uri": "http://localhost:8080/callback",
        "scopes": ["data:read", "profile:read"],
        "state_dir": root,
    }
    # Check service launch, secret prerequisites and absence of token-triggered
    # restarts separately from what the wrapper itself does when called.
    assert entry["installed"]
    assert entry["command"] == [wrapper, "daemon", name]
    assert entry["claims"] == [root]
    assert entry["services"] == [f"mcp-oauth-{name}"]
    if backend == "hm":
        assert entry["restartOnChange"] == []
    assert entry["environment"] == {
        "MCP_OAUTH_CLIENT_ID": {"_redact": {"file": credentials[0]}},
        "MCP_OAUTH_CLIENT_SECRET": {"_redact": {"file": credentials[1]}},
    }
    assert entry["activation"] == [] and entry["files"] == {}
    assert entry["prerequisites"] == (
        {"After": ["network.target", "sops-nix.service"], "Wants": ["sops-nix.service"]}
        if backend == "hm" else {"watchPaths": credentials})
    launcher_text = Path(shlex.split(entry["launcher"])[0]).read_text()
    assert wrapper in launcher_text and "daemon" in launcher_text
    assert all(path in launcher_text for path in credentials)
    assert "access-token" not in launcher_text and "state.json" not in launcher_text

    # Deliberately hostile opposite-backend PATH and storage hints must not
    # change either discovery or the absolute path in recovery diagnostics.
    env = dict(os.environ, PATH=str(Path(other).parent) + ":" + os.environ["PATH"],
               HOME="/tmp/hostile-home", XDG_STATE_HOME="/tmp/hostile-state",
               MCP_OAUTH_WRAPPER=other)
    env.pop("DEVENV_STATE", None)
    env.pop("DEVENV_ROOT", None)
    result = invoke(wrapper, ["status"], env)
    assert result.returncode == 0 and "login required" in result.stdout.lower(), result
    for reason, args, code, message in (
        ("other backend's account stays hidden", ["status", "personal" if backend == "devenv" else "work"],
         1, "unknown account"),
        ("manifest override before command", ["--manifest", manifest_path, "status"],
         2, "backend options cannot be overridden"),
        ("inline manifest override after command", ["status", "--manifest=" + manifest_path],
         2, "backend options cannot be overridden"),
        ("abbreviated manifest override", ["--man", manifest_path, "status"],
         2, "backend options cannot be overridden"),
        ("wrapper identity cannot be overridden", ["--wrapper", other, "status"],
         2, "backend options cannot be overridden"),
    ):
        result = invoke(wrapper, args, env)
        assert (result.returncode, result.stderr.strip()) == (code, f"mcp-oauth: {message}"), (reason, result)
    result = invoke(wrapper, ["--help"], env)
    assert result.returncode == 0 and "--wrapper" not in result.stdout

    daemon = subprocess.Popen([wrapper, "daemon", name], env=env, text=True,
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        with selectors.DefaultSelector() as ready:
            ready.register(daemon.stderr, selectors.EVENT_READ)
            assert ready.select(10), "daemon did not report recovery"
            diagnostic = daemon.stderr.readline().strip()
        prefix = "mcp-oauth: Login required: "
        assert diagnostic.startswith(prefix), diagnostic
        recovery = shlex.split(diagnostic.removeprefix(prefix))
        assert recovery == [wrapper, "login", name], recovery
    finally:
        daemon.send_signal(signal.SIGTERM)
        daemon.communicate(timeout=10)
    assert daemon.returncode == 0
    print(f"PASS: {backend} manifest, service, wrapper isolation and absolute recovery")

assert not Path("/tmp/hostile-state/mcp-oauth").exists()
assert not Path("/tmp/hostile-home/.local/state/mcp-oauth").exists()
print("PASS: no environment fallback, token restart trigger or activation refresh")

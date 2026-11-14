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

fixture = json.loads(Path(sys.argv[1]).read_text())
expected = {
    "devenv": ("work", "/tmp/oauth-project/mcp-oauth/devenv/work"),
    "hm": ("personal", "/tmp/oauth-hm/mcp-oauth/hm/personal"),
}
credentials = ["/run/secrets/oauth-id", "/run/secrets/oauth-secret"]


def invoke(wrapper, args, env):
    return subprocess.run([wrapper, *args], env=env, text=True, capture_output=True, timeout=10)


for backend, entry in fixture["proxy"].items():
    assert entry["clients"] == {
        "meeting": {"type": "http", "url": "http://127.0.0.1:19592/"},
        "messaging": {"type": "http", "url": "http://127.0.0.1:19593/"},
    }
    assert entry["rootOwners"] == ["mcp-proxy-meeting"]
    assert entry["runtimeOwners"] == ["mcp-proxy-messaging"]
    assert entry["restartPaths"] == {"mcp-proxy-meeting": [], "mcp-proxy-messaging": []}
    for command in entry["commands"].values():
        script = Path(command[0]).read_text()
        source = Path(re.search(r"--config (\S+) --adapter", script)[1]).read_text()
        token_path = entry["stateRoot"] + f"/mcp-oauth/{backend}/work/access-token"
        assert token_path in source
        assert "Bearer {vars.file_" in source
    print(f"PASS: {backend} exact clients, owners, token paths and generated header")

fixture = fixture["backends"]

for backend, (name, root) in expected.items():
    entry = fixture[backend]
    wrapper = entry["command"][0]
    other = fixture["devenv" if backend == "hm" else "hm"]["command"][0]
    script = Path(wrapper).read_text()
    words = shlex.split(next(line for line in script.splitlines() if line.startswith("exec ")))
    manifest_path = words[words.index("--manifest") + 1]
    manifest = json.loads(Path(manifest_path).read_text())
    assert set(manifest) == {"accounts", "backend"}
    assert manifest["backend"] == backend
    assert list(manifest["accounts"]) == [name], manifest
    assert manifest["accounts"][name] == {
        "client_id_file": credentials[0],
        "client_secret_file": credentials[1],
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
    assert entry["installed"]
    assert entry["command"] == [wrapper, "daemon", name]
    assert entry["claims"] == [root]
    assert entry["services"] == [f"mcp-oauth-{name}"]
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
    assert Path(root).is_dir()
    for args in (["status", "personal" if backend == "devenv" else "work"],
                 ["status", "two words"], ["status", "disabled"],
                 ["--home", "status"], ["--manifest", manifest_path, "status"],
                 ["status", "--manifest=" + manifest_path], ["--man", manifest_path, "status"],
                 ["--wrapper", other, "status"]):
        result = invoke(wrapper, args, env)
        assert result.returncode != 0, args
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

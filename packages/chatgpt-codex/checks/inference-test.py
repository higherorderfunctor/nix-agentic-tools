"""Offline ai.settings.inference contract: the pinned Codex sends every request to the
selected proxy with the selected client key, through Home Manager's user
config.toml and devenv's launcher. Mock proxies listen on loopback inside the
build sandbox."""

import json
import os
import shutil
import subprocess
import sys
import threading
import tomllib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

codex, key_file, cases_file = sys.argv[1:]
cases = json.loads(Path(cases_file).read_text())
key_path = Path(key_file)
HM_PORT, DEVENV_PORT = 8317, 8318

requests = []
lock = threading.Lock()


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def record(self):
        length = int(self.headers.get("content-length") or 0)
        if length:
            self.rfile.read(length)
        with lock:
            requests.append(
                {
                    "auth": self.headers.get("authorization"),
                    "headers": dict(self.headers),
                    "method": self.command,
                    "path": self.path.split("?")[0],
                    "port": self.server.server_address[1],
                }
            )

    def reply(self, status, kind, body):
        self.send_response(status)
        self.send_header("content-type", kind)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.record()
        self.reply(200, "application/json", b'{"object": "list", "data": [], "models": []}')

    def do_POST(self):
        self.record()
        events = [
            {"type": "response.created", "response": {"id": "r1"}},
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "message",
                    "role": "assistant",
                    "id": "m1",
                    "content": [{"type": "output_text", "text": "MOCK-OK"}],
                },
            },
            {"type": "response.completed", "response": {"id": "r1", "usage": None}},
        ]
        body = "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events)
        self.reply(200, "text/event-stream", body.encode())

    def log_message(self, *_):
        pass


for port in (HM_PORT, DEVENV_PORT):
    server = ThreadingHTTPServer(("127.0.0.1", port), Proxy)
    threading.Thread(target=server.serve_forever, daemon=True).start()

tmp = Path(os.environ["TMPDIR"])
project = tmp / "project"
project.mkdir()


def run(binary, config, *, command_key, file_key):
    """Run Codex with distinct reference values and fresh user state."""
    key_path.write_text(file_key + "\n\n")
    home = tmp / "home"
    shutil.rmtree(home, ignore_errors=True)
    codex_home = home / ".codex"
    codex_home.mkdir(parents=True)
    if config is not None:
        text = Path(config).read_text()
        (codex_home / "config.toml").write_text(text)
    # Inherited OpenAI credentials must never reach the proxy.
    (codex_home / "auth.json").write_text(json.dumps({"OPENAI_API_KEY": "inherited-auth-json"}))
    with lock:
        requests.clear()
    environment = {
        "CODEX_HOME": str(codex_home),
        "CODEX_PROXY_TEST_STATUS": "0",
        "CODEX_PROXY_TEST_VALUE": command_key + "\n\n",
        "DEVENV_ROOT": str(project),
        "CODEX_API_KEY": "inherited-codex-key",
        "HOME": str(home),
        "OPENAI_API_KEY": "inherited-openai-key",
        "PATH": os.environ["PATH"],
        "TERM": "dumb",
    }
    result = subprocess.run(
        ["timeout", "90", binary, "exec", "--skip-git-repo-check", "say hi"],
        cwd=project,
        env=environment,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
    )
    with lock:
        return result, list(requests)


def expect(name, result, seen, port, key):
    if result.returncode != 0:
        sys.exit(f"FAIL {name}: codex exited {result.returncode}: {result.stderr}")
    posts = [r for r in seen if r["method"] == "POST" and r["path"] == "/v1/responses"]
    if not posts:
        sys.exit(f"FAIL {name}: no POST /v1/responses reached a proxy.\nseen={seen}\nstderr={result.stderr}")
    wrong = [r for r in seen if r["port"] != port or r["auth"] != f"Bearer {key}"]
    if wrong:
        sys.exit(f"FAIL {name}: expected port {port} with Bearer {key}, got {wrong}")
    leaked = [n for r in seen for n, v in r["headers"].items() if "inherited" in v]
    if leaked:
        sys.exit(f"FAIL {name}: inherited credential in headers {leaked}")
    print(f"ok: {name}: {len(seen)} requests, all to :{port} with the selected key")


def run_helper(form, **variables):
    config = Path(cases["configs"][form])
    helper = tomllib.loads(config.read_text())["model_providers"]["ai-inference"]["auth"]["command"]
    return subprocess.run([helper], env=dict(os.environ, **variables), capture_output=True, text=True, timeout=10)


# HTTP disallows embedded newlines. Check preserved bytes and literal shell
# syntax at the helper boundary.
secret = "probe ' \" \\ $HOME $(touch injected) `touch injected`\nnext"
key_path.write_text(secret + "\n\n")
result = run_helper("concat")
assert (result.returncode, result.stdout, result.stderr) == (
    0,
    'prefix-"\'$HOME$(touch injected)`probe \' " \\ $HOME $(touch injected) `touch injected`\nnext-suffix',
    "",
), ("concat did not preserve literal affixes around the file value", result)
assert not Path("injected").exists(), "concat evaluated literal shell syntax"

# Fail after the command has already printed the value.
result = run_helper("command", CODEX_PROXY_TEST_STATUS="7", CODEX_PROXY_TEST_VALUE=secret + "\n\n")
assert (result.returncode, result.stdout, result.stderr) == (
    1, "", "ai.codex.settings.inference.key: reference command failed\n"
), ("wrong command failure or leaked reference output", result)

# The precedence cases below exercise HM command delivery and devenv command
# and file delivery; devenv concat also runs with no user config.
# Vary the file and command inputs so using the wrong reference cannot pass.
wire_keys = {
    "concat": 'prefix-"\'$HOME$(touch injected)`sk-file-suffix',
    "file": "sk-file",
}
for form, key in wire_keys.items():
    inputs = {"command_key": "sk-command", "file_key": "sk-file"}
    expect(f"hm auth reads the {form} reference", *run(codex, cases["configs"][form], **inputs), HM_PORT, key)
    if form == "concat":
        expect("devenv auth reads the concat reference", *run(cases["launchers"][form], None, **inputs), DEVENV_PORT, key)

# A higher layer must win both the endpoint and credential, not just one.
expect(
    "HM runtime selection overrides shared inference",
    *run(codex, cases["hmOverride"], command_key="sk-runtime", file_key="sk-shared"),
    DEVENV_PORT,
    "sk-runtime",
)
expect(
    "devenv session selection overrides HM user config",
    *run(cases["launchers"]["command"], cases["configs"]["file"], command_key="sk-devenv", file_key="sk-hm"),
    DEVENV_PORT,
    "sk-devenv",
)
# A deep merge under a reused provider ID would inherit incompatible legacy auth.
legacy = tmp / "legacy.toml"
legacy.write_text(
    'model_provider = "ai-inference"\n[model_providers.ai-inference]\n'
    'name = "ai-inference"\nbase_url = "http://127.0.0.1:8317/v1"\n'
    'wire_api = "responses"\nexperimental_bearer_token = "sk-user-legacy"\n'
)
expect(
    "legacy user auth + devenv file",
    *run(cases["launchers"]["file"], legacy, command_key="sk-unused", file_key="sk-selected"),
    DEVENV_PORT,
    "sk-selected",
)

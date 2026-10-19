# cspell:ignore urandom
"""Offline ai.proxy contract: the pinned Codex sends every request to the
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


def run(binary, config, key):
    """One `codex exec` with a fresh Codex home holding `config`, or none."""
    home = Path(tmp / "home")
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
        "CODEX_PROXY_TEST_VALUE": key + "\n\n",
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


def resolved(form, key):
    return 'prefix-"\'$HOME$(touch injected)`' + key + "-suffix" if form == "concat" else key


# Exercise runtime bytes directly: HTTP disallows embedded newlines, while a
# reference must preserve them without interpreting any shell metacharacters.
secret = "secret-" + os.urandom(16).hex() + " ' \" \\ $HOME $(touch injected) `touch injected`\nnext"
helper_cases = 0
for form, config in cases["configs"].items():
    provider = tomllib.loads(Path(config).read_text())["model_providers"]["ai-proxy"]
    helper = provider["auth"]["command"]
    key_path.write_text(secret + "\n\n")
    environment = dict(os.environ, CODEX_PROXY_TEST_STATUS="0", CODEX_PROXY_TEST_VALUE=secret + "\n\n")
    result = subprocess.run([helper], env=environment, capture_output=True, text=True)
    assert (result.returncode, result.stdout, result.stderr) == (0, resolved(form, secret), ""), form
    assert not Path("injected").exists(), (form, "shell injection")
    helper_cases += 1
    if form == "command":
        environment["CODEX_PROXY_TEST_STATUS"] = "7"
    else:
        key_path.unlink()
    result = subprocess.run([helper], env=environment, capture_output=True, text=True)
    assert result.returncode != 0 and result.stdout == "", (form, "failed reference succeeded")
    assert "ai.codex.proxy.key:" in result.stderr and secret not in result.stderr, form
    helper_cases += 1
print(f"verified {helper_cases} Codex helper cases: file, command, concat, multiline bytes and failures")

# Each reference form reaches the selected proxy through real Codex provider
# auth. A legacy bearer token in the user layer must not contaminate devenv's
# separately named provider, and devenv must win over Home Manager's endpoint.
for form, config in cases["configs"].items():
    key = f"sk-hm-{form}"
    key_path.write_text(key + "\n\n")
    expect(f"hm {form}", *run(codex, config, key), HM_PORT, resolved(form, key))
for form, binary in cases["launchers"].items():
    key = f"sk-devenv-{form}"
    key_path.write_text(key + "\n\n")
    expect(f"devenv {form}", *run(binary, None, key), DEVENV_PORT, resolved(form, key))
key_path.write_text("sk-selected\n")
expect(
    "hm + devenv command",
    *run(cases["launchers"]["command"], cases["configs"]["file"], "sk-selected"),
    DEVENV_PORT,
    "sk-selected",
)
legacy = tmp / "legacy.toml"
legacy.write_text(
    'model_provider = "ai-proxy"\n[model_providers.ai-proxy]\n'
    'name = "ai-proxy"\nbase_url = "http://127.0.0.1:8317/v1"\n'
    'wire_api = "responses"\nexperimental_bearer_token = "sk-user-legacy"\n'
)
expect(
    "legacy user auth + devenv file",
    *run(cases["launchers"]["file"], legacy, "sk-selected"),
    DEVENV_PORT,
    "sk-selected",
)

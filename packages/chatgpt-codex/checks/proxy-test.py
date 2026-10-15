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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

(
    codex,
    hm_plain,
    hm_file,
    hm_helper,
    devenv_plain,
    devenv_file,
    secrets_placeholder,
) = sys.argv[1:]
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
secrets = tmp / "secrets"
secrets.mkdir()
(secrets / "hm-key").write_text("sk-hm-file\n")
project = tmp / "project"
project.mkdir()


def run(binary, config):
    """One `codex exec` with a fresh Codex home holding `config`, or none."""
    home = Path(tmp / "home")
    shutil.rmtree(home, ignore_errors=True)
    codex_home = home / ".codex"
    codex_home.mkdir(parents=True)
    if config is not None:
        text = Path(config).read_text().replace(secrets_placeholder, str(secrets))
        (codex_home / "config.toml").write_text(text)
    with lock:
        requests.clear()
    environment = {
        "CODEX_HOME": str(codex_home),
        "DEVENV_ROOT": str(project),
        "HOME": str(home),
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
    posts = [r for r in seen if r["method"] == "POST" and r["path"] == "/v1/responses"]
    if not posts:
        sys.exit(f"FAIL {name}: no POST /v1/responses reached a proxy.\nseen={seen}\nstderr={result.stderr}")
    wrong = [r for r in seen if r["port"] != port or r["auth"] != f"Bearer {key}"]
    if wrong:
        sys.exit(f"FAIL {name}: expected port {port} with Bearer {key}, got {wrong}")
    print(f"ok: {name}: {len(seen)} requests, all to :{port} with the selected key")


# Home Manager: the provider and its key form in user config.toml.
expect("hm plain", *run(codex, hm_plain), HM_PORT, "sk-hm-plain")
expect("hm file", *run(codex, hm_file), HM_PORT, "sk-hm-file")
expect("hm helper", *run(codex, hm_helper), HM_PORT, "sk-hm-helper")

# devenv alone: the url form as eval-time session flags, in each key form a
# session flag renders differently: a plain key's `experimental_bearer_token`
# and a file key's command-backed `auth` inline table.
expect("devenv url plain", *run(devenv_plain, None), DEVENV_PORT, "sk-devenv-plain")
expect("devenv url file", *run(devenv_file, None), DEVENV_PORT, "sk-devenv-file")

# Both: devenv's own provider id wins over Home Manager's user provider, even
# with the other key form (a shared id would fail to load).
expect("hm + devenv url", *run(devenv_file, hm_plain), DEVENV_PORT, "sk-devenv-file")

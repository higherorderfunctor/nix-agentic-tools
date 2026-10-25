"""Exercise generated Airlock launchers with pinned Claude and fake OAuth offline."""

# cspell:ignore keyout

import base64
import json
import os
from pathlib import Path
import pty
import re
import select
import socketserver
import ssl
import subprocess
import sys
import threading
import time
import traceback


OLD_ACCESS = "sk-ant-oat01-FAKE-OLD-ACCESS-OFFLINE"
OLD_REFRESH = "FAKE-OLD-REFRESH-OFFLINE"
NEW_ACCESS = "sk-ant-oat01-FAKE-NEW-ACCESS-OFFLINE"
NEW_REFRESH = "FAKE-NEW-REFRESH-OFFLINE"
LOGIN_CODE = "FAKE-OFFLINE-AUTHORIZATION-CODE"
PROMPT = "AIRLOCK_OFFLINE_PROMPT_SENTINEL_7419"
REPLY = "AIRLOCK_OFFLINE_RESPONSE_SENTINEL_5273"
MESSAGES_BODY_LIMIT = 1 << 20


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(30)
            line, headers, _ = self.read(self.request)
            if not line.startswith("CONNECT "):
                return
            host = line.split()[1]
            assert host in ("api.anthropic.com:443", "platform.claude.com:443")
            assert headers.get("proxy-authorization") == self.server.authorization
            self.server.hosts.add(host)
            self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            with self.server.tls.wrap_socket(self.request, server_side=True) as connection:
                while True:
                    line, headers, body = self.read(connection)
                    if not line:
                        break
                    path = line.split()[1].split("?", 1)[0]
                    if path == "/v1/oauth/token":
                        fields = json.loads(body)
                        if fields.get("grant_type") == "authorization_code":
                            assert fields.get("code") == LOGIN_CODE
                            self.server.login_seen.set()
                            self.send(connection, 200, {
                                "access_token": OLD_ACCESS,
                                "refresh_token": OLD_REFRESH,
                                "expires_in": 3600,
                                "refresh_token_expires_in": 2592000,
                                "scope": "user:inference user:profile",
                            })
                            continue
                        self.server.refresh_tokens.append({
                            "is_new": fields.get("refresh_token") == NEW_REFRESH,
                            "is_old": fields.get("refresh_token") == OLD_REFRESH,
                        })
                        assert fields["grant_type"] == "refresh_token"
                        assert fields["refresh_token"] in (OLD_REFRESH, NEW_REFRESH)
                        self.server.refresh_seen.set()
                        self.send(connection, 200, {
                            "access_token": NEW_ACCESS,
                            "refresh_token": NEW_REFRESH,
                            "expires_in": 3600,
                            "refresh_token_expires_in": 2592000,
                            "scope": "user:inference user:profile",
                        })
                    elif path == "/api/oauth/profile":
                        authorization = headers.get("authorization")
                        assert authorization in (f"Bearer {OLD_ACCESS}", f"Bearer {NEW_ACCESS}")
                        self.server.profile_tokens.append(authorization == f"Bearer {NEW_ACCESS}")
                        self.server.profile_seen.set()
                        self.send(connection, 200, {
                            "account": {"uuid": "fake-account", "email": "fake@example.invalid"},
                            "organization": {"uuid": "fake-org"},
                        })
                    elif path == "/api/claude_cli/bootstrap":
                        self.send(connection, 200, {})
                    elif path == "/v1/messages":
                        assert headers.get("authorization") == f"Bearer {NEW_ACCESS}"
                        shape = self.messages_first_party_shape(body)
                        self.server.messages_first_party.append(shape)
                        assert all(shape.values()), "Messages first-party identity shape mismatch"
                        self.server.messages_seen.set()
                        self.send_messages(connection)
                        break
                    else:
                        self.send(connection, 401, {"error": "offline_fixture"})
                    if headers.get("connection", "").lower() == "close":
                        break
        except ConnectionResetError:
            # Claude may close an idle keep-alive tunnel after finishing a request.
            pass
        except Exception as error:
            self.server.failures.append(
                (type(error).__name__, traceback.extract_tb(error.__traceback__)[-1].lineno)
            )

    @staticmethod
    def read(connection):
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 65536:
            chunk = connection.recv(1)
            if not chunk:
                return "", {}, b""
            data += chunk
        head, separator, _ = data.partition(b"\r\n\r\n")
        assert separator, "oversized HTTP headers"
        lines = head.decode("latin1").split("\r\n")
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                name, value = line.split(":", 1)
                headers[name.lower()] = value.strip()
        size = int(headers.get("content-length", "0"))
        assert size >= 0, "negative HTTP body length"
        assert "transfer-encoding" not in headers, "unsupported HTTP transfer encoding"
        request_path = lines[0].split()[1].split("?", 1)[0]
        token_request = request_path == "/v1/oauth/token"
        messages_request = request_path == "/v1/messages"
        if token_request:
            assert size <= 65536, "oversized fake token request"
        if messages_request:
            assert size <= MESSAGES_BODY_LIMIT, "oversized fake Messages request"
        body = bytearray()
        remaining = size
        while remaining:
            chunk = connection.recv(min(remaining, 65536))
            if not chunk:
                raise ValueError("incomplete HTTP body")
            remaining -= len(chunk)
            if token_request or messages_request:
                body.extend(chunk)
        return lines[0], headers, body

    @staticmethod
    def messages_first_party_shape(body):
        """Return only booleans describing the signed billing block, never its bytes."""
        try:
            document = json.loads(body)
            parsed = isinstance(document, dict)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return {"json": False, "system": False, "billing": False, "cch": False}
        blocks = document.get("system", []) if parsed else []
        system_is_list = isinstance(blocks, list)
        billing = [
            block.get("text")
            for block in blocks if isinstance(block, dict)
            and isinstance(block.get("text"), str)
            and block["text"].startswith("x-anthropic-billing-header:")
        ] if system_is_list else []
        return {
            "json": parsed,
            "system": system_is_list,
            "billing": bool(billing),
            "cch": any(
                re.search(r"(?:^|[;:])\s*cch=[0-9a-f]+\s*(?:;|$)", text)
                for text in billing
            ),
        }

    @staticmethod
    def send(connection, status, payload):
        body = json.dumps(payload).encode()
        connection.sendall(
            f"HTTP/1.1 {status} fixture\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: keep-alive\r\n\r\n".encode()
            + body
        )

    @staticmethod
    def send_messages(connection):
        message = {
            "id": "msg_fake_offline", "type": "message", "role": "assistant",
            "content": [], "model": "claude-sonnet-4-5", "stop_reason": None,
            "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 0},
        }
        events = [
            ("message_start", {"type": "message_start", "message": message}),
            ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": REPLY}}),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 1}}),
            ("message_stop", {"type": "message_stop"}),
        ]
        body = "".join(f"event: {name}\ndata: {json.dumps(payload)}\n\n" for name, payload in events).encode()
        connection.sendall(
            f"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
            + body
        )


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


def certificate(root):
    config = root / "cert.cnf"
    config.write_text(
        "[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n"
        "[dn]\nCN=offline.invalid\n[v3]\n"
        "subjectAltName=DNS:api.anthropic.com,DNS:platform.claude.com\n"
        "basicConstraints=CA:TRUE\nkeyUsage=digitalSignature,keyCertSign,keyEncipherment\n"
    )
    cert = root / "cert.pem"
    key = root / "key.pem"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "1", "-keyout", str(key), "-out", str(cert), "-config", str(config)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return cert, key


def run_backend(backend, paths, root, cert, tls):
    workspace = root / backend
    workspace.mkdir()
    home = workspace / "home"
    home.mkdir()
    user = home / ".claude"
    user.mkdir()
    project = workspace / ".claude"
    project.mkdir()
    config = user if backend == "hm" else workspace / "config"
    config.mkdir(exist_ok=True)
    (home / ".claude.json").write_text(json.dumps({"hasCompletedOnboarding": True, "numStartups": 1}))
    settings = user / "settings.json" if backend == "hm" else project / "settings.json"
    settings.write_text(json.dumps(paths["settings"]))
    token = "fake-CONNECT-token-offline"
    state_root = Path("/build/airlock-service-runtime")
    state_root.mkdir(mode=0o700, exist_ok=True)
    ca_dir = state_root / "airlock-18418"
    ca_dir.mkdir(mode=0o700, exist_ok=True)
    (ca_dir / "ca.pem").write_bytes(cert.read_bytes())
    config_path = workspace / "service-path"
    env = os.environ | {
        "AIRLOCK_TEST_TOKEN": token,
        "AIRLOCK_TEST_CONFIG_PATH": str(config_path),
        "AIRLOCK_TEST_BWRAP_LOG": os.devnull,
        "AIRLOCK_TEST_DESTINATION": paths["destination"],
        "HOME": str(home),
        "CLAUDE_CONFIG_DIR": str(config),
        "CLAUDE_CODE_OAUTH_TOKEN": "fake-INHERITED-must-be-cleared",
        "XDG_RUNTIME_DIR": str(workspace / "runtime"),
        "NODE_EXTRA_CA_CERTS": str(cert),
        "SSL_CERT_FILE": str(cert),
        "CI": "1",
        "TERM": "dumb",
    }
    subprocess.run([paths["service"]], cwd=workspace, env=env, capture_output=True, check=True)
    rendered = json.loads(Path(config_path.read_text()).read_text())
    assert rendered["clients"]["harness"]["token_file"]
    assert rendered["credentials"]["upstream"]["auth"] == {"type": "oauth_managed"}
    assert paths["settings"]["env"]["CLAUDE_CODE_OAUTH_TOKEN"] == ""
    with Server(("127.0.0.1", 18418), Handler) as server:
        server.tls = tls
        server.authorization = "Basic " + base64.b64encode(f"harness:{token}".encode()).decode()
        server.hosts = set()
        server.failures = []
        server.refresh_tokens = []
        server.login_seen = threading.Event()
        server.refresh_seen = threading.Event()
        server.profile_seen = threading.Event()
        server.profile_tokens = []
        server.messages_seen = threading.Event()
        server.messages_first_party = []
        threading.Thread(target=server.serve_forever, daemon=True).start()
        login_status, login_prompt = native_login(paths["launcher"], workspace, env)
        assert login_status == 0 and server.login_seen.is_set(), (
            backend, "native login failed", login_status, login_prompt,
            sorted(server.hosts), server.failures,
        )
        stored_login = json.loads((config / ".credentials.json").read_text())["claudeAiOauth"]
        assert stored_login["accessToken"] == NEW_ACCESS and stored_login["refreshToken"] == NEW_REFRESH, (
            backend, "native login stored unexpected pair", sorted(stored_login), server.refresh_tokens,
        )
        assert server.refresh_tokens and server.refresh_tokens[0]["is_old"]
        refresh_count_after_login = len(server.refresh_tokens)
        stored_login["expiresAt"] = int(time.time() * 1000) - 60000
        (config / ".credentials.json").write_text(json.dumps({"claudeAiOauth": stored_login}))
        run = subprocess.run(
            [paths["launcher"], "-p", PROMPT, "--output-format", "json", "--no-session-persistence"],
            cwd=workspace, env=env, capture_output=True, timeout=30,
        )
        server.shutdown()
    assert not server.failures, (backend, "handler failures (type, source line)", server.failures, server.refresh_tokens, fake_token_state(config))
    assert run.stdout, (
        backend,
        "empty native stdout",
        run.returncode,
        len(run.stderr),
        [marker for marker in (
            b"AIRLOCK_TEST_DESTINATION", b"CA is unavailable", b"system roots",
            b"service config", b"client token", b"Traceback", b"AssertionError",
            b"CLAUDE_CONFIG_DIR", b"Permission denied", b"No such file",
        ) if marker in run.stderr],
        server.refresh_seen.is_set(),
        server.profile_seen.is_set(),
        server.messages_seen.is_set(),
        sorted(server.hosts),
        fake_token_state(config),
    )
    output = json.loads(run.stdout)
    assert run.returncode == 0 and output.get("is_error") is False and output.get("result") == REPLY, (backend, run.returncode)
    assert server.refresh_seen.is_set() and server.profile_seen.is_set() and server.messages_seen.is_set()
    assert server.messages_first_party and all(
        all(shape.values()) for shape in server.messages_first_party
    ), (backend, server.messages_first_party)
    assert any(server.profile_tokens)
    assert len(server.refresh_tokens) > refresh_count_after_login and server.refresh_tokens[-1]["is_new"], (backend, server.refresh_tokens)
    assert "platform.claude.com:443" in server.hosts and "api.anthropic.com:443" in server.hosts
    stored = json.loads((config / ".credentials.json").read_text())["claudeAiOauth"]
    assert stored["accessToken"] == NEW_ACCESS and stored["refreshToken"] == NEW_REFRESH
    assert not (workspace / "bwrap.jsonl").exists()
    for path in workspace.rglob("*"):
        if path.is_file():
            content = path.read_bytes()
            assert PROMPT.encode() not in content and REPLY.encode() not in content, (backend, path)
    print(f"PASS {backend}: pinned Claude logged in and refreshed through generated launcher, stored fake pair, used fake access with first-party cch billing signature for profile and Messages")


def fake_token_state(config):
    stored = json.loads((config / ".credentials.json").read_text())["claudeAiOauth"]
    return {
        "access_is_new": stored.get("accessToken") == NEW_ACCESS,
        "access_is_old": stored.get("accessToken") == OLD_ACCESS,
        "refresh_is_new": stored.get("refreshToken") == NEW_REFRESH,
        "refresh_is_old": stored.get("refreshToken") == OLD_REFRESH,
    }


def native_login(launcher, workspace, env):
    master, slave = pty.openpty()
    process = subprocess.Popen(
        [launcher, "auth", "login"], cwd=workspace, env=env,
        stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
    )
    os.close(slave)
    output = bytearray()
    supplied = False
    deadline = time.monotonic() + 30
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.2)
            if readable:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    chunk = b""
                if chunk:
                    output.extend(chunk)
                    assert len(output) < 131072, "native login output too large"
                    if b"Paste code here if prompted" in output and not supplied:
                        state = re.search(rb"[?&]state=([^&\s]+)", output)
                        code = LOGIN_CODE.encode() + (b"#" + state.group(1) if state else b"")
                        os.write(master, code + b"\n")
                        supplied = True
                elif process.poll() is not None:
                    break
            if process.poll() is not None:
                break
        else:
            process.kill()
            process.wait()
            raise AssertionError((
                "native login timeout", supplied, b"state=" in output,
                b"Invalid" in output or b"invalid" in output,
            ))
        return process.wait(), supplied
    finally:
        os.close(master)


def main():
    paths = json.loads(Path(sys.argv[1]).read_text())
    root = Path(os.environ["TMPDIR"])
    cert, key = certificate(root)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    tls.set_alpn_protocols(["http/1.1"])
    for backend, fixture in paths.items():
        run_backend(backend, fixture, root, cert, tls)


if __name__ == "__main__":
    main()

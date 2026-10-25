"""Drive source-contract routes through the real Airlock service and launcher."""

import base64
from http.client import HTTPResponse
import http.server
import json
import os
from pathlib import Path
import socket
import socketserver
import ssl
import subprocess
import sys
import threading
import time
from urllib.parse import unquote, urlsplit

CLIENT_TOKEN = "fake-COMPOSITE-client-token-offline"
PRIMARY_TOKEN = "fake-COMPOSITE-primary-token-offline"
ZAI_TOKEN = "fake-COMPOSITE-zai-token-offline"
CLASSIFIER_BETA = "auto-mode-classifier-2026-07-16"
DANGEROUS_BETA = "dangerous-tool-use-2026-09-03"
CONNECT_HOST = "api.anthropic.com:18420"
REQUEST_BODY_LIMIT = 64 << 10
REQUEST_RECORD_LIMIT = 64
PROCESS_OUTPUT_LIMIT = 64 << 10
CONTENT_SCAN_LIMIT = 1 << 20
CLASSIFIER_BODY = b'{"model":"glm-4.7","messages":[]}'
REMOTE_CONTROL = [
    ("POST", "/v1/environments/bridge", b'{"environment":"fake"}'),
    ("GET", "/v1/environments/fake-env-id/work/poll", b""),
    ("POST", "/v1/environments/fake-env-id/work/ack", b'{"work":"fake"}'),
    ("POST", "/v1/environments/fake-env-id/work/stop", b'{"reason":"fake"}'),
    ("DELETE", "/v1/environments/bridge/fake-env-id", b""),
    ("POST", "/v1/environments/bridge/fake-env-id/offline", b'{"offline":true}'),
]
EXPECTED = [
    ("POST", "/v1/messages", CLASSIFIER_BODY, PRIMARY_TOKEN),
    ("POST", "/api/anthropic/v1/messages", CLASSIFIER_BODY, ZAI_TOKEN),
    *[(method, path, body, PRIMARY_TOKEN) for method, path, body in REMOTE_CONTROL],
]


class UpstreamHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_DELETE(self):
        self.respond()

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > REQUEST_BODY_LIMIT:
            self.send_response(413)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = self.rfile.read(length)
        record = (
            self.command,
            self.path,
            body,
            self.headers.get("X-Api-Key"),
        )
        if len(self.server.records) < REQUEST_RECORD_LIMIT:
            self.server.records.append(record)
        payload = b'{"type":"composite-ok"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


class UpstreamServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def finish_request(self, request, client_address):
        with self.tls_context.wrap_socket(request, server_side=True) as tls:
            super().finish_request(tls, client_address)


def certificate(root):
    config = root / "cert.cnf"
    config.write_text(
        "[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n"
        "[dn]\nCN=composite.invalid\n[v3]\n"
        "subjectAltName=DNS:api.anthropic.com,IP:127.0.0.1\n"
        "basicConstraints=critical,CA:FALSE\n"
        "keyUsage=critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\n"
        "subjectKeyIdentifier=hash\n"
        "authorityKeyIdentifier=keyid,issuer\n"
    )
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-sha256",
            "-nodes",
            "-days",
            "1",
            "-keyout",
            str(root / "key.pem"),
            "-out",
            str(root / "cert.pem"),
            "-config",
            str(config),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return root / "cert.pem"


class OutputCollector:
    """Collect each pipe once in memory, failing closed above an explicit bound."""

    def __init__(self, process):
        self.data = (bytearray(), bytearray())
        self.total_lengths = [0, 0]
        self.truncated = [False, False]
        self.threads = [
            threading.Thread(target=self._read, args=(stream, index), daemon=True)
            for index, stream in enumerate((process.stdout, process.stderr))
        ]
        for thread in self.threads:
            thread.start()

    def _read(self, stream, index):
        while True:
            chunk = stream.read(8192)
            if not chunk:
                return
            self.total_lengths[index] += len(chunk)
            remaining = PROCESS_OUTPUT_LIMIT - len(self.data[index])
            if remaining:
                self.data[index].extend(chunk[:remaining])
            if self.total_lengths[index] > PROCESS_OUTPUT_LIMIT:
                self.truncated[index] = True

    def wait_eofs(self, timeout):
        deadline = time.monotonic() + timeout
        for thread in self.threads:
            thread.join(max(0.0, deadline - time.monotonic()))
        assert not any(thread.is_alive() for thread in self.threads), (
            "service output readers did not reach end of stream"
        )

    def bytes(self):
        return self.data[0] + self.data[1]

    def close(self):
        for stream in self.data:
            del stream[:]

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


def assert_private_output(content):
    for token in (CLIENT_TOKEN, PRIMARY_TOKEN, ZAI_TOKEN):
        assert token.encode() not in content, "credential appears in subprocess output"
    markers = sorted(marker for marker in content_markers() if marker)
    matches = [index for index, marker in enumerate(markers) if marker in content]
    assert not matches, f"request or response marker indexes in output: {matches}"


def diagnostic_reasons(content):
    normalized = content.lower()
    markers = (
        "XDG_RUNTIME_DIR",
        "not on tmpfs or ramfs",
        "state_dir",
        "could not load secrets",
        "secret file",
        "is empty after trimming",
        "could not read secret file",
        "reference command failed",
        "reference resolved empty",
        "gateway socket",
        "Address already in use",
        "unexpected argument",
        "invalid subcommand",
        "Usage:",
        "No such file",
        "Permission denied",
        "storage",
        "libnss_wrapper",
        "shared object",
        'invalid "anthropic" endpoint',
    )
    return [
        marker
        for marker in markers
        if marker.lower().encode() in normalized
    ]


def wait_tcp(port, process, collector):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            collector.wait_eofs(1)
            output = collector.bytes()
            assert not any(collector.truncated), "service output exceeded its bounded buffer"
            assert_private_output(output)
            recognized = diagnostic_reasons(output)
            raise AssertionError(
                f"Airlock service exited before listening with status {process.returncode}; "
                f"recognized reasons {recognized}"
            )
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise AssertionError("Airlock service did not listen")

def exchange(tls, method, path, body, beta=None):
    headers = [
        ("Host", "api.anthropic.com:18420"),
        ("Content-Length", str(len(body))),
    ]
    if beta:
        headers.append(("Anthropic-Beta", beta))
    request = f"{method} {path} HTTP/1.1\r\n".encode()
    request += "".join(f"{name}: {value}\r\n" for name, value in headers).encode()
    request += b"Connection: keep-alive\r\n\r\n" + body
    tls.sendall(request)
    response = HTTPResponse(tls)
    response.begin()
    payload = response.read()
    status = response.status
    return status, payload


def run_client():
    arguments = sys.argv[2:]
    assert arguments[:4] == [
        "--setting-sources",
        os.environ["AIRLOCK_TEST_BACKEND"],
        "--settings",
        arguments[3],
    ]
    assert arguments[4:] == ["--composite"]
    overlay = json.loads(Path(arguments[3]).read_text())
    environment = os.environ | overlay["env"]
    assert environment["ANTHROPIC_BASE_URL"] == ""
    proxy = urlsplit(environment["HTTPS_PROXY"])
    assert proxy.hostname == "127.0.0.1" and proxy.port == int(os.environ["AIRLOCK_TEST_PORT"])
    authorization = base64.b64encode(
        f"{unquote(proxy.username)}:{unquote(proxy.password)}".encode()
    ).decode()
    with socket.create_connection((proxy.hostname, proxy.port), timeout=10) as tunnel:
        tunnel.sendall(
            f"CONNECT {CONNECT_HOST} HTTP/1.1\r\n"
            f"Proxy-Authorization: Basic {authorization}\r\n\r\n".encode()
        )
        answer = tunnel.recv(4096)
        assert answer.startswith(b"HTTP/1.1 200"), "CONNECT was not accepted"
        context = ssl.create_default_context(cafile=os.environ["AIRLOCK_TEST_CA"])
        # Airlock's pre-existing leaf omits the optional Authority Key Identifier
        # extension. Python's stricter optional profile rejects that leaf; certificate
        # chaining, CERT_REQUIRED, and hostname checking remain active.
        context.verify_flags &= ~ssl.VERIFY_X509_STRICT
        with context.wrap_socket(tunnel, server_hostname="api.anthropic.com") as tls:
            statuses = []
            statuses.append(exchange(tls, "POST", "/v1/messages", CLASSIFIER_BODY, CLASSIFIER_BETA))
            statuses.append(exchange(tls, "POST", "/v1/messages", CLASSIFIER_BODY, DANGEROUS_BETA))
            for method, path, body in REMOTE_CONTROL:
                statuses.append(exchange(tls, method, path, body))
    assert all(
        status == 200 and payload == b'{"type":"composite-ok"}'
        for status, payload in statuses
    ), "composite response status or payload length mismatch"
    Path(os.environ["AIRLOCK_TEST_RESULT"]).write_text(json.dumps({"routed": len(statuses)}))


def run_backend(backend, paths, root, cert):
    workspace = root / backend
    workspace.mkdir()
    home = workspace / "home"
    config_dir = home / ".claude"
    config_dir.mkdir(parents=True)
    runtime = Path(f"/dev/shm/airlock-composite-{backend}-runtime")
    state = Path(f"/build/airlock-composite-{backend}-state")
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    runtime.chmod(0o700)
    state.chmod(0o700)
    hosts = workspace / "hosts"
    hosts.write_text("127.0.0.1 api.anthropic.com\n")
    server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_context.load_cert_chain(cert, root / "key.pem")
    records = []
    with UpstreamServer(("127.0.0.1", 18420), UpstreamHandler) as upstream:
        upstream.tls_context = server_context
        upstream.records = records
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        result = workspace / "result.json"
        environment = os.environ | {
            "AIRLOCK_TEST_BACKEND": "user" if backend == "hm" else "project",
            "AIRLOCK_TEST_BWRAP_LOG": os.devnull,
            "AIRLOCK_TEST_CA": str(runtime / "airlock-18418" / "ca.pem"),
            "AIRLOCK_TEST_DESTINATION": paths["destination"],
            "AIRLOCK_TEST_PORT": "18418",
            "AIRLOCK_TEST_PRIMARY_TOKEN": PRIMARY_TOKEN,
            "AIRLOCK_TEST_RESULT": str(result),
            "AIRLOCK_TEST_TOKEN": CLIENT_TOKEN,
            "AIRLOCK_TEST_ZAI_TOKEN": ZAI_TOKEN,
            "CLAUDE_CONFIG_DIR": str(config_dir),
            "HOME": str(home),
            "HOSTNAME": "composite-offline.invalid",
            "LD_PRELOAD": paths["nssLibrary"],
            "NSS_WRAPPER_HOSTS": str(hosts),
            "SSL_CERT_FILE": str(cert),
            "XDG_RUNTIME_DIR": str(runtime),
        }
        service = subprocess.Popen(
            [paths["service"]],
            cwd=workspace,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        service_exited = False
        launched = None
        with OutputCollector(service) as collector:
            try:
                try:
                    wait_tcp(18418, service, collector)
                except BaseException:
                    service_exited = True
                    raise
                launched = subprocess.run(
                    [paths["launcher"], "--composite"],
                    cwd=workspace,
                    env=environment,
                    capture_output=True,
                    timeout=30,
                )
                assert launched.returncode == 0, (
                    f"generated launcher exited with status {launched.returncode}; "
                    f"stderr bytes {len(launched.stderr)}"
                )
                assert json.loads(result.read_text()) == {"routed": len(EXPECTED)}
                assert len(records) == len(EXPECTED), (
                    f"captured request count {len(records)} differs from expected {len(EXPECTED)}"
                )
                for index, (actual, expected) in enumerate(zip(records, EXPECTED)):
                    assert actual[0] == expected[0], f"request {index} method mismatch"
                    assert actual[1] == expected[1], f"request {index} path mismatch"
                    assert actual[2] == expected[2], f"request {index} body mismatch"
                    assert actual[3] == expected[3], f"request {index} credential mismatch"
                for artifact in (paths["launcher"], paths["service"]):
                    content = Path(artifact).resolve().read_bytes()
                    for token in (CLIENT_TOKEN, PRIMARY_TOKEN, ZAI_TOKEN):
                        assert token.encode() not in content, (
                            f"credential appears in artifact {artifact}"
                        )
            finally:
                service.terminate()
                collector.wait_eofs(5)
                service.wait(timeout=5)
                assert service.returncode in ((0, -15) if not service_exited else (1, -15)), (
                    f"Airlock service exit status {service.returncode}"
                )
                service_output = collector.bytes()
                assert not any(collector.truncated), "service output exceeded its bounded buffer"
                captured_outputs = (
                    service_output,
                    launched.stdout if launched else b"",
                    launched.stderr if launched else b"",
                )
                for content in captured_outputs:
                    assert_private_output(content)
                scan_durable_content((workspace, state, runtime))
                upstream.shutdown()
                upstream.server_close()
    print(f"PASS {backend}: real Airlock service and generated launcher preserved classifier, model, and remote-control routes")

def content_markers():
    markers = {
        CLASSIFIER_BODY,
        b'{"type":"composite-ok"}',
        CLASSIFIER_BETA.encode(),
        DANGEROUS_BETA.encode(),
    }
    for method, path, body in REMOTE_CONTROL:
        markers.update((path.encode(), body))
    return tuple(markers)


def scan_durable_content(roots):
    markers = sorted(marker for marker in content_markers() if marker)
    for root in roots:
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            size = path.stat().st_size
            assert size <= CONTENT_SCAN_LIMIT, f"oversized durable artifact {path.name}"
            content = path.read_bytes()
            matches = [
                index for index, marker in enumerate(markers) if marker in content
            ]
            assert not matches, f"request or response marker indexes in {path.name}: {matches}"


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "client":
        run_client()
        return
    fixtures = json.loads(Path(sys.argv[1]).read_text())
    root = Path(os.environ["TMPDIR"]) / "airlock-composite-routes"
    root.mkdir(parents=True)
    cert = certificate(root)
    for backend, paths in fixtures.items():
        run_backend(backend, paths, root, cert)


if __name__ == "__main__":
    main()

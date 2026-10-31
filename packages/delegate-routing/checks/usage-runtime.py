"""Exercise real curl transport against a local CPA management fixture."""

import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

SCRIPTS = Path(sys.argv.pop(1))
SECRET = 'management-"quoted\\key'
CLAUDE = {"five_hour": {"utilization": 23}, "seven_day": None}
CODEX = {"rate_limit": {"primary_window": {"used_percent": 37, "reset_at": 1900000000}}}

ZAI = {"code": 200, "data": {"level": "MAX", "limits": [
    {"unit": unit, "number": number, "percentage": 29, "nextResetTime": 1900000000000}
    for unit, number in [(3, 5), (6, 1)]]}}

OPENCODE = {"usage": {
    "rolling": {"status": "ok", "percent": 12.5, "resetsAt": "2030-03-17T17:46:40.000Z"},
    "weekly": {"status": "rate-limited", "percent": 100, "resetsAt": "2030-03-17T17:46:40Z"},
    "monthly": {"status": "ok", "percent": 40, "resetsAt": "2030-03-17T19:46:40+02:00"}}}
ROUTES = ("claude", "codex")

class UsageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.helpers = {}
        for vendor in ["claude", "codex", "opencode", "zai"]:
            helper = self.home / f"{vendor}-usage"
            helper.write_text(f"#!{shutil.which('bash')}\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n" + (SCRIPTS / "usage-cpa.sh").read_text() + "\n" + (SCRIPTS / f"{vendor}-usage.sh").read_text())
            helper.chmod(0o755)
            self.helpers[vendor] = str(helper)
        self.key = self.home / "management-key"
        self.key.write_text(SECRET + "\n")
        self.files = [self.account("claude", "a"), self.account("codex", "b")]
        self.configs = {"claude": [], "openai-compatibility": []}
        self.requests = []
        self.management_status = 200
        self.envelope = None
        self.raw = None
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.handle_request()

            def do_POST(self):
                self.handle_request()

            def handle_request(self):
                size = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(size)) if size else None
                owner.requests.append((self.command, self.path, dict(self.headers), body))
                if self.path == "/v0/management/auth-files":
                    response = {"files": owner.files}
                elif self.path.startswith("/v8/management/config/api-keys/"):
                    response = owner.configs.get(self.path.rsplit("/", 1)[1])
                    if response is None:
                        self.send_error(404)
                        return
                elif self.path == "/v0/management/api-call":
                    usage = (ZAI if "api.z.ai" in body["url"] else OPENCODE if "opencode.ai" in body["url"]
                             else CLAUDE if "anthropic.com" in body["url"] else CODEX)
                    response = owner.envelope or {"status_code": 200, "body": json.dumps(usage)}
                else:
                    self.send_error(404)
                    return
                self.send_response(owner.management_status)
                self.end_headers()
                self.wfile.write(owner.raw if owner.raw is not None else json.dumps(response).encode())

        self.handler = Handler
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.addCleanup(self.server.server_close)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("DELEGATE_USAGE_CPA_")}
        self.env.update(HOME=str(self.home), TZ="UTC")

    @staticmethod
    def account(provider, index, **extra):
        return dict(provider=provider, account_type="oauth", auth_index=index, disabled=False, email=f"{index}@example.test", **extra)

    def run_helper(self, vendor, cpa=True, route=None, **overrides):
        env = self.env.copy()
        routed = vendor in ("opencode", "zai")
        route = route or ("claude" if routed else vendor)
        if cpa:
            env.update({f"DELEGATE_USAGE_CPA_{route.upper()}_URL": self.url,
                        f"DELEGATE_USAGE_CPA_{route.upper()}_MANAGEMENT_KEY_FILE": str(self.key)})
        env.update(overrides)
        result = subprocess.run([self.helpers[vendor]] + ([route] if routed else []), env=env, text=True, capture_output=True, timeout=10)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        return result

    def direct_codex(self):
        # The real direct helper must still initialize app-server and request the
        # rate limit, even after the CPA account list gives no matching login.
        executable = self.home / "bin/codex"
        executable.parent.mkdir()
        executable.write_text(f"#!{sys.executable}\n" + '''import json, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get("id") == 1:
        assert message["method"] == "initialize"
        print(json.dumps({"id": 1, "result": {}}), flush=True)
    elif message.get("id") == 2:
        assert message["method"] == "account/rateLimits/read"
        print(json.dumps({"id": 2, "result": {"rateLimits": {"primary": {"usedPercent": 11, "resetsAt": 1900000000}}}}), flush=True)
''')
        executable.chmod(0o755)
        self.env["PATH"] = str(executable.parent) + os.pathsep + self.env["PATH"]

    def test_vendor_requests_and_multiple_accounts(self):
        self.files.append(self.account("codex", "c", id_token={"chatgpt_account_id": "account-c"}))
        self.files.append(dict(self.account("codex", "disabled"), disabled=True))
        self.files.append(dict(self.account("codex", "api-key"), account_type="api_key"))
        for vendor, expected in [("claude", ["a"]), ("codex", ["b", "c"])]:
            with self.subTest(vendor=vendor):
                self.requests.clear()
                result = self.run_helper(vendor)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                values = [json.loads(block) for block in result.stdout.replace("}\n{", "}\0{").split("\0")]
                self.assertEqual([item["account"]["auth_index"] for item in values], expected)
                for method, path, headers, body in self.requests:
                    self.assertEqual(headers["Authorization"], f"Bearer {SECRET}")
                    self.assertNotIn("usage-queue", path)
                    if method == "POST":
                        self.assertEqual(body["header"]["Authorization"], "Bearer $TOKEN$")
                        self.assertEqual(body["method"], "GET")
                        expected_url = "https://api.anthropic.com/api/oauth/usage" if vendor == "claude" else "https://chatgpt.com/backend-api/wham/usage"
                        self.assertEqual(body["url"], expected_url)
                if vendor == "claude":
                    self.assertEqual(values[0]["five_hour"], CLAUDE["five_hour"])
                    self.assertEqual(self.requests[1][3]["header"]["anthropic-beta"], "oauth-2025-04-20")
                else:
                    self.assertEqual(values[0]["remainingPercent"], 63)
                    self.assertEqual(self.requests[-1][3]["header"]["Chatgpt-Account-Id"], "account-c")

    def test_keys_never_reach_tool_arguments_or_environment(self):
        binary = self.home / "bin"
        binary.mkdir()
        for tool in ["curl", "jq", "python3"]:
            real = shutil.which(tool)
            executable = binary / tool
            executable.write_text(f"#!{sys.executable}\n" + f'''import os, sys
for secret in [{SECRET!r}, "upstream-private-key"]:
    assert secret not in " ".join(sys.argv)
    assert secret not in os.environ.values()
os.execv({real!r}, [{real!r}] + sys.argv[1:])
''')
            executable.chmod(0o755)
        self.configs["claude"] = [{"base-url": "https://api.z.ai/api/anthropic", "keys": [
            {"api-key": "upstream-private-key", "auth_index": "z1"}]}]
        self.configs["codex"] = [{"base-url": "https://opencode.ai/inference/go/openai/v1", "keys": [
            {"api-key": "upstream-private-key", "auth_index": "o1"}]}]
        for vendor in ["codex", "opencode", "zai"]:
            result = self.run_helper(vendor, PATH=str(binary) + os.pathsep + self.env["PATH"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("upstream-private-key", result.stdout + result.stderr)

    def test_direct_codex_and_configured_missing_login(self):
        self.direct_codex()
        result = self.run_helper("codex", cpa=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["usedPercent"], 11)
        self.files = []
        result = self.run_helper("codex")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no enabled codex login", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_zai_transports_and_key_ambiguity(self):
        def group(key, index, host="api.z.ai"):
            return {"base-url": f"https://{host}/api/anthropic", "keys": [{"api-key": key, "auth_index": index}]}
        self.configs = {"claude": [group("upstream-private-key", "z1")],
                        "openai-compatibility": [group("upstream-private-key", "z2"), group("other-private-key", "evil", "api.z.ai.evil.test")]}
        result = self.run_helper("zai")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(json.loads(result.stdout)["windows"]), {"5h", "1w"})
        self.assertEqual(self.requests[-1][3]["auth_index"], "z1")
        self.assertEqual(self.requests[-1][3]["header"]["Authorization"], "Bearer $TOKEN$")
        for surface in ["claude", "openai-compatibility"]:
            with self.subTest(surface=surface):
                self.configs = {}
                self.configs[surface] = [group("upstream-private-key", "only")]
                result = self.run_helper("zai", route="codex")
                self.assertEqual(result.returncode, 0, result.stderr)
        for groups in [[], [group("upstream-private-key", "z1"), group("different-private-key", "z2")],
                       [group("upstream-private-key", "z1", "api.z.ai.evil.test")]]:
            self.configs = {"claude": groups, "openai-compatibility": []}
            result = self.run_helper("zai")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly one distinct key", result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertNotIn("private-key", result.stderr)

    def test_direct_zai_and_route(self):
        executable = self.home / "bin/curl"
        executable.parent.mkdir()
        executable.write_text(f"#!{sys.executable}\n" + f'''import sys
assert "Authorization: Bearer direct-zai-key" in sys.stdin.read()
assert "/api/monitor/usage/quota/limit" in sys.argv[-1]
print({json.dumps(json.dumps(ZAI))})
''')
        executable.chmod(0o755)
        self.key.write_text("direct-zai-key")
        result = self.run_helper("zai", cpa=False, ZAI_API_KEY_FILE=str(self.key), PATH=str(executable.parent) + os.pathsep + self.env["PATH"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["windows"]["5h"]["remainingPercent"], 71)
        result = subprocess.run([self.helpers["zai"]], env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected route", result.stderr)

    def test_opencode_transports_and_projection(self):
        def group(key, index, base):
            return {"base-url": base, "keys": [{"api-key": key, "auth_index": index}]}
        go = "https://opencode.ai/inference/go"
        # One Go key on every transport, plus keys that only look like Go.
        self.configs = {"claude": [group("upstream-private-key", "g1", go + "/anthropic"),
                                   group("zen-private-key", "zen", "https://opencode.ai/zen/v1")],
                        "codex": [group("upstream-private-key", "g2", go + "/openai/v1")],
                        "openai-compatibility": [group("upstream-private-key", "g3", go + "/openai/v1"),
                                                 group("other-private-key", "evil", "https://opencode.ai.evil.test/inference/go/openai/v1"),
                                                 group("prefix-private-key", "gox", "https://opencode.ai/inference/gox/v1")]}
        for route in ROUTES:
            with self.subTest(route=route):
                self.requests.clear()
                result = self.run_helper("opencode", route=route)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                windows = json.loads(result.stdout)["windows"]
                self.assertEqual(windows, {
                    "rolling": {"status": "ok", "usedPercent": 12.5, "remainingPercent": 87.5, "resetsAt": "2030-03-17 17:46:40 UTC"},
                    "weekly": {"status": "rate-limited", "usedPercent": 100, "remainingPercent": 0, "resetsAt": "2030-03-17 17:46:40 UTC"},
                    "monthly": {"status": "ok", "usedPercent": 40, "remainingPercent": 60, "resetsAt": "2030-03-17 17:46:40 UTC"}})
                self.assertEqual([path for _, path, _, _ in self.requests[:3]],
                                 [f"/v8/management/config/api-keys/{surface}" for surface in ["claude", "codex", "openai-compatibility"]])
                call = self.requests[-1][3]
                self.assertEqual(call["auth_index"], "g1")
                self.assertEqual(call["url"], "https://opencode.ai/zen/go/v1/usage")
                self.assertEqual(call["header"]["Authorization"], "Bearer $TOKEN$")
        # Only the Go surface counts: a key elsewhere on opencode.ai is not ambiguity.
        for groups in [[], [group("upstream-private-key", "g1", go + "/anthropic"), group("different-private-key", "g2", go + "/openai/v1")],
                       [group("upstream-private-key", "g1", "https://opencode.ai/zen/v1")]]:
            self.configs = {"claude": groups}
            result = self.run_helper("opencode")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly one distinct key", result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertNotIn("private-key", result.stderr)
        self.configs = {"claude": [group("upstream-private-key", "g1", go + "/anthropic")]}
        for envelope in [{"status_code": 403, "body": "private-response-body"},
                         {"status_code": 200, "body": json.dumps({"usage": {"rolling": OPENCODE["usage"]["rolling"]}})},
                         {"status_code": 200, "body": json.dumps({"usage": dict(OPENCODE["usage"], weekly={"status": "ok", "percent": "1", "resetsAt": "2030-03-17T17:46:40Z"})})},
                         {"status_code": 200, "body": json.dumps({"usage": dict(OPENCODE["usage"], weekly={"status": "paused", "percent": 1, "resetsAt": "2030-03-17T17:46:40Z"})})},
                         {"status_code": 200, "body": "private-response-body"}]:
            with self.subTest(envelope=envelope["body"][:40]):
                self.envelope = envelope
                result = self.run_helper("opencode")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("vendor HTTP 403" if envelope["status_code"] == 403 else "invalid opencode usage", result.stderr)
                self.assertNotIn("private-response-body", result.stdout + result.stderr)
                self.assertEqual(result.stdout, "")

    def test_direct_opencode_and_route(self):
        executable = self.home / "bin/curl"
        executable.parent.mkdir()
        executable.write_text(f"#!{sys.executable}\n" + f'''import sys
assert "Authorization: Bearer direct-opencode-key" in sys.stdin.read()
assert "direct-opencode-key" not in " ".join(sys.argv)
assert sys.argv[-1] == "https://opencode.ai/zen/go/v1/usage"
print({json.dumps(json.dumps(OPENCODE))})
''')
        executable.chmod(0o755)
        self.key.write_text("direct-opencode-key")
        path = str(executable.parent) + os.pathsep + self.env["PATH"]
        result = self.run_helper("opencode", cpa=False, OPENCODE_API_KEY_FILE=str(self.key), PATH=path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["windows"]["monthly"]["remainingPercent"], 60)
        self.assertNotIn("direct-opencode-key", result.stdout + result.stderr)
        result = self.run_helper("opencode", cpa=False, PATH=path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("OPENCODE_API_KEY_FILE", result.stderr)
        result = subprocess.run([self.helpers["opencode"]], env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected route", result.stderr)

    def test_partial_configuration(self):
        for env in [
            {"DELEGATE_USAGE_CPA_CLAUDE_URL": self.url},
            {"DELEGATE_USAGE_CPA_CLAUDE_MANAGEMENT_KEY_FILE": str(self.key)},
        ]:
            result = self.run_helper("claude", cpa=False, **env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires both", result.stderr)
            self.assertEqual(self.requests, [])

    def test_failures_are_explicit_without_response_bodies(self):
        cases = [
            ("management HTTP", 401, None, b'private-response-body'),
            ("invalid auth-files", 200, None, b'private-response-body'),
            ("vendor HTTP 401", 200, {"status_code": 401, "body": "private-response-body"}, None),
            ("invalid api-call", 200, {"status_code": 200, "body": {}}, None),
            ("invalid vendor usage", 200, {"status_code": 200, "body": "private-response-body"}, None),
            ("invalid vendor usage", 200, {"status_code": 200, "body": '{}'}, None),
        ]
        for expected, status, envelope, raw in cases:
            with self.subTest(expected=expected):
                self.management_status, self.envelope, self.raw = status, envelope, raw
                result = self.run_helper("codex")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertNotIn("private-response-body", result.stdout + result.stderr)
                self.assertNotIn("falling back", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_key_and_transport_errors(self):
        for content in ["", "line\nbreak", "line\rbreak"]:
            self.key.write_text(content)
            result = self.run_helper("codex")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("single line", result.stderr)
        self.key.unlink()
        result = self.run_helper("codex")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot read", result.stderr)
        self.key.write_text(SECRET)
        self.server.shutdown()
        self.server.server_close()
        result = self.run_helper("codex")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("management request failed", result.stderr)


if __name__ == "__main__":
    unittest.main()

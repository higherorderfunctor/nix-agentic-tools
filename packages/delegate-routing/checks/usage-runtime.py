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


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.helpers = {}
        for vendor in ["claude", "codex"]:
            helper = self.home / f"{vendor}-usage"
            helper.write_text(f"#!{shutil.which('bash')}\nset -euETo pipefail\n" + (SCRIPTS / "usage-cpa.sh").read_text() + "\n" + (SCRIPTS / f"{vendor}-usage.sh").read_text())
            helper.chmod(0o755)
            self.helpers[vendor] = str(helper)
        self.key = self.home / "management-key"
        self.key.write_text(SECRET + "\n")
        self.files = [self.account("claude", "a"), self.account("codex", "b")]
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
                elif self.path == "/v0/management/api-call":
                    usage = CLAUDE if "anthropic.com" in body["url"] else CODEX
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

    def run_helper(self, vendor, cpa=True, **overrides):
        env = self.env.copy()
        if cpa:
            env.update(DELEGATE_USAGE_CPA_URL=self.url, DELEGATE_USAGE_CPA_MANAGEMENT_KEY_FILE=str(self.key))
        env.update(overrides)
        result = subprocess.run([self.helpers[vendor]], env=env, text=True, capture_output=True, timeout=10)
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
                decoder = json.JSONDecoder()
                output = result.stdout
                values = []
                while output.strip():
                    value, end = decoder.raw_decode(output.lstrip())
                    values.append(value)
                    output = output.lstrip()[end:]
                self.assertEqual([item["account"]["auth_index"] for item in values], expected)
                self.assertEqual(len(self.requests), 1 + len(expected))
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

    def test_management_key_never_reaches_curl_arguments_or_environment(self):
        real_curl = shutil.which("curl")
        executable = self.home / "bin/curl"
        executable.parent.mkdir()
        executable.write_text(f"#!{sys.executable}\n" + f'''import os, sys
assert {SECRET!r} not in " ".join(sys.argv)
assert {SECRET!r} not in os.environ.values()
os.execv({real_curl!r}, [{real_curl!r}] + sys.argv[1:])
''')
        executable.chmod(0o755)
        result = self.run_helper("codex", PATH=str(executable.parent) + os.pathsep + self.env["PATH"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 2)

    def test_claude_nullable_window(self):
        self.envelope = {"status_code": 200, "body": '{"five_hour": null, "seven_day": null}'}
        result = self.run_helper("claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout)["five_hour"])

    def test_direct_codex_and_no_login_fallback(self):
        self.direct_codex()
        for cpa in [False, True]:
            self.files = [dict(self.account("codex", "disabled"), disabled=True)]
            result = self.run_helper("codex", cpa=cpa)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["usedPercent"], 11)
            self.assertNotIn("account", json.loads(result.stdout))
            self.assertEqual("falling back" in result.stderr, cpa)

    def test_direct_claude_credentials_and_request(self):
        # A curl fixture keeps the original vendor request offline while checking
        # its local-token and beta headers and preserving its output projection.
        executable = self.home / "bin/curl"
        executable.parent.mkdir()
        executable.write_text(f"#!{sys.executable}\n" + f'''import sys
config = sys.stdin.read()
assert 'Bearer local-claude-token' in config
assert 'anthropic-beta: oauth-2025-04-20' in config
assert 'https://api.anthropic.com/api/oauth/usage' in config
print({json.dumps(json.dumps(CLAUDE))})
''')
        executable.chmod(0o755)
        config = self.home / "custom-claude"
        config.mkdir()
        (config / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {"accessToken": "local-claude-token"}}))
        result = self.run_helper("claude", cpa=False, PATH=str(executable.parent) + os.pathsep + self.env["PATH"], CLAUDE_CONFIG_DIR=str(config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["five_hour"], CLAUDE["five_hour"])
        self.assertNotIn("account", json.loads(result.stdout))

    def test_vendor_defaults_and_explicit_generic_override(self):
        other = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self.handler)
        self.addCleanup(other.server_close)
        threading.Thread(target=other.serve_forever, daemon=True).start()
        self.addCleanup(other.shutdown)
        other_url = f"http://127.0.0.1:{other.server_port}"
        defaults = {
            "DELEGATE_USAGE_CPA_CLAUDE_URL": self.url,
            "DELEGATE_USAGE_CPA_CLAUDE_MANAGEMENT_KEY_FILE": str(self.key),
            "DELEGATE_USAGE_CPA_CODEX_URL": other_url,
            "DELEGATE_USAGE_CPA_CODEX_MANAGEMENT_KEY_FILE": str(self.key),
        }
        # A root/personal instance and a Codex/work override, or two runtime-only
        # selections, arrive as these independent pairs from either backend.
        self.env.update(defaults)
        for vendor, expected in [("claude", self.url), ("codex", other_url)]:
            with self.subTest(vendor=vendor):
                self.requests.clear()
                result = self.run_helper(vendor, cpa=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.requests[0][2]["Host"], expected.removeprefix("http://"))
        # Explicit generic configuration overrides inherited vendor defaults.
        self.requests.clear()
        result = self.run_helper("codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests[0][2]["Host"], self.url.removeprefix("http://"))
        # A project vendor pair replaces the inherited HM pair of that name.
        self.requests.clear()
        result = self.run_helper("codex", cpa=False, DELEGATE_USAGE_CPA_CODEX_URL=self.url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests[0][2]["Host"], self.url.removeprefix("http://"))
        # A generic partial override never borrows the vendor default's half.
        result = self.run_helper("codex", cpa=False, DELEGATE_USAGE_CPA_URL=self.url)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires both", result.stderr)

    def test_partial_configuration(self):
        for env in [
            {"DELEGATE_USAGE_CPA_URL": self.url},
            {"DELEGATE_USAGE_CPA_MANAGEMENT_KEY_FILE": str(self.key)},
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

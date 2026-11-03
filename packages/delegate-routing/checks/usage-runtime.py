"""Exercise real curl transport against a local CPA management fixture."""

import copy
from datetime import datetime
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
# Endpoint shapes from the investigation; all values and identities are synthetic.
RESET = "2030-03-17T17:46:40Z"
CLAUDE = {
    "five_hour": {"utilization": 23, "resets_at": "2030-03-17T17:46:40.123456+00:00"},
    "seven_day": {"utilization": 61, "resets_at": RESET},
    "seven_day_opus": {"utilization": 12, "resets_at": RESET},
    "seven_day_sonnet": None,
    "limits": [
        {"kind": "weekly_all", "percent": 61, "severity": "warning", "resets_at": RESET, "is_active": True},
        {"kind": "weekly_scoped", "percent": 32, "resets_at": RESET,
         "scope": {"model": {"display_name": "Fable"}}, "is_active": False},
    ],
    "spend": {"used": {"amount_minor": 1250, "currency": "USD", "exponent": 2},
              "limit": {"amount_minor": 20000, "currency": "USD", "exponent": 2}},
    "promo_credits": None,
}
CODEX = {
    "plan_type": "test-plan",
    "rate_limit": {"primary_window": {"used_percent": 37, "reset_at": 1900000000, "limit_window_seconds": 604800},
                   "secondary_window": {"used_percent": 7, "reset_at": 1900000000, "limit_window_seconds": 18000}},
    "credits": {"has_credits": True, "balance": "1234.5000000000"},
    "rate_limit_reset_credits": {"available_count": 2},
}
CODEX_DIRECT = {
    "rateLimits": {
        "planType": "ignored-direct-plan",
        "primary": {"usedPercent": 11, "resetsAt": 1900000000, "windowDurationMins": 10080},
        "secondary": {"usedPercent": 8, "resetsAt": 1900000000, "windowDurationMins": 300},
        "credits": {"hasCredits": True, "balance": "1234.5000000000"},
    },
    "rateLimitResetCredits": {"availableCount": 2, "credits": [
        {"status": "available", "expiresAt": 1900000000},
        {"status": "available", "expiresAt": 1900000060},
    ]},
}
CODEX_RESETS = {"available_count": 2, "credits": [
    {"status": "available", "expires_at": "2030-03-17T17:46:40.987654Z"},
    {"status": "available", "expires_at": "2030-03-17T18:47:40+01:00"},
]}
ZAI = {"code": 200, "data": {"level": "test-level", "limits": [
    {"unit": unit, "number": number, "percentage": 29, "nextResetTime": 1900000000123}
    for unit, number in [(3, 5), (6, 1)]]}}

class UsageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.helpers = {}
        for vendor in ["claude", "codex", "zai"]:
            helper = self.home / f"{vendor}-usage"
            helper.write_text(f"#!{shutil.which('bash')}\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n" + (SCRIPTS / "usage-cpa.sh").read_text() + "\n" + (SCRIPTS / f"{vendor}-usage.sh").read_text())
            helper.chmod(0o755)
            self.helpers[vendor] = str(helper)
        self.key = self.home / "management-key"
        self.key.write_text(SECRET + "\n")
        self.files = [self.account("claude", "a"), self.account("codex", "b")]
        self.configs = {"claude": [], "openai-compatibility": []}
        self.requests = []
        self.usage = copy.deepcopy({"claude": CLAUDE, "codex": CODEX, "zai": ZAI})
        self.resets = copy.deepcopy(CODEX_RESETS)
        self.reset_failure = None
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
                    if body["url"].endswith("/rate-limit-reset-credits"):
                        if owner.reset_failure == "transport":
                            self.close_connection = True
                            return
                        if owner.reset_failure == "management":
                            self.send_error(503)
                            return
                        response = {"status_code": 503 if owner.reset_failure == "vendor" else 200,
                                    "body": "private-response-body" if owner.reset_failure == "invalid_json" else json.dumps(owner.resets)}
                        if owner.reset_failure == "malformed":
                            response = {}
                    else:
                        vendor = "zai" if "api.z.ai" in body["url"] else "claude" if "anthropic.com" in body["url"] else "codex"
                        response = owner.envelope or {"status_code": 200, "body": json.dumps(owner.usage[vendor])}
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
        self.env.update(HOME=str(self.home), TZ="America/Denver")

    @staticmethod
    def account(provider, index, **extra):
        return dict(provider=provider, account_type="oauth", auth_index=index, disabled=False, email=f"{index}@example.test", **extra)

    def run_helper(self, vendor, cpa=True, route=None, **overrides):
        env = self.env.copy()
        route = route or ("claude" if vendor == "zai" else vendor)
        if cpa:
            env.update({f"DELEGATE_USAGE_CPA_{route.upper()}_URL": self.url,
                        f"DELEGATE_USAGE_CPA_{route.upper()}_MANAGEMENT_KEY_FILE": str(self.key)})
        env.update(overrides)
        result = subprocess.run([self.helpers[vendor]] + ([route] if vendor == "zai" else []), env=env, text=True, capture_output=True, timeout=10)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        if result.returncode == 0:
            # Every successful transport must emit exactly the schema the drain rule reads.
            raw = result.stdout.strip()
            decoder = json.JSONDecoder()
            self.assertTrue(raw)
            while raw:
                value, end = decoder.raw_decode(raw)
                self.assert_schema(value, vendor)
                raw = raw[end:].lstrip()
        return result

    def assert_schema(self, value, vendor):
        self.assertEqual(set(value), {"pool", "account", "windows", "balances", "bonuses"})
        self.assertEqual(value["pool"], vendor)
        self.assertEqual(set(value["account"]), {"auth_index", "name", "plan"})
        for field in value["account"].values():
            self.assertTrue(field is None or isinstance(field, str))
        self.assertIsInstance(value["windows"], dict)
        for name, window in value["windows"].items():
            self.assertEqual(set(window), {"usedPercent", "remainingPercent", "resetsAt", "status", "windowSeconds"})
            self.assertIsInstance(window["windowSeconds"], (int, float))
            seconds = window["windowSeconds"]
            self.assertEqual(name.split(":", 1)[0], {18000: "5h", 604800: "7d"}.get(seconds, f"{seconds}s"))
            if vendor == "claude":
                self.assertEqual(seconds, 18000 if name == "5h" else 604800)
            self.assertIsInstance(window["usedPercent"], (int, float))
            self.assertEqual(window["remainingPercent"], 100 - window["usedPercent"])
            self.assertTrue(window["status"] is None or isinstance(window["status"], str))
            self.assert_utc(window["resetsAt"])
        for field, amount in [("balances", "remaining"), ("bonuses", "count")]:
            self.assertIsInstance(value[field], list)
            for entry in value[field]:
                expected = {"kind", amount, "expiresAt"} | ({"unit"} if field == "balances" else set())
                self.assertEqual(set(entry), expected)
                self.assertIsInstance(entry["kind"], str)
                self.assertIsInstance(entry[amount], (int, float))
                if field == "balances":
                    self.assertIsInstance(entry["unit"], str)
                if entry["expiresAt"] is not None:
                    self.assert_utc(entry["expiresAt"])

    def assert_utc(self, value):
        self.assertRegex(value, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")

    def direct_codex(self, usage=None):
        # The real direct helper must still initialize app-server and request the
        # rate limit, even after the CPA account list gives no matching login.
        executable = self.home / "bin/codex"
        executable.parent.mkdir(exist_ok=True)
        fixture = self.home / "codex-response.json"
        fixture.write_text(json.dumps(CODEX_DIRECT if usage is None else usage))
        executable.write_text(f"#!{sys.executable}\n" + f"fixture = {str(fixture)!r}\n" + '''import json, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get("id") == 1:
        assert message["method"] == "initialize"
        print(json.dumps({"id": 1, "result": {}}), flush=True)
    elif message.get("id") == 2:
        assert message["method"] == "account/rateLimits/read"
        print(json.dumps({"id": 2, "result": json.load(open(fixture))}), flush=True)
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
                        self.assertIn(body["url"], [expected_url] + (["https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"] if vendor == "codex" else []))
                if vendor == "claude":
                    self.assertEqual(values[0]["windows"]["5h"]["usedPercent"], 23)
                    self.assertEqual(self.requests[1][3]["header"]["anthropic-beta"], "oauth-2025-04-20")
                else:
                    self.assertEqual(values[0]["windows"]["7d"]["remainingPercent"], 63)
                    self.assertEqual(len(self.requests), 5)
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
        for vendor in ["codex", "zai"]:
            result = self.run_helper(vendor, PATH=str(binary) + os.pathsep + self.env["PATH"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("upstream-private-key", result.stdout + result.stderr)

    def test_direct_codex_and_configured_missing_login(self):
        self.direct_codex()
        result = self.run_helper("codex", cpa=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["windows"]["7d"]["usedPercent"], 11)
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
        value = json.loads(result.stdout)
        self.assertEqual(set(value["windows"]), {"5h", "7d"})
        self.assertEqual(value["account"], {"auth_index": "z1", "name": "z1", "plan": "test-level"})
        self.assertEqual(value["balances"], [])
        self.assertEqual(value["bonuses"], [])
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
        value = json.loads(result.stdout)
        self.assertEqual(value["windows"]["5h"]["windowSeconds"], 18000)
        self.assertEqual(value["windows"]["7d"]["windowSeconds"], 604800)
        self.assertEqual(value["windows"]["5h"]["remainingPercent"], 71)
        self.assertEqual(value["windows"]["5h"]["resetsAt"], RESET)
        self.assertEqual(value["windows"]["7d"]["resetsAt"], RESET)
        self.assertEqual(value["account"], {"auth_index": None, "name": None, "plan": "test-level"})
        self.assertEqual(value["balances"], [])
        self.assertEqual(value["bonuses"], [])
        result = subprocess.run([self.helpers["zai"]], env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected route", result.stderr)

    def test_zai_duration_names_follow_unit_and_number(self):
        self.configs["claude"] = [{"base-url": "https://api.z.ai/api/anthropic",
                                    "keys": [{"api-key": "duration-fixture", "auth_index": "z1"}]}]
        for unit, number, seconds, name in [(3, 1, 3600, "3600s"), (3, 5, 18000, "5h"),
                                            (6, 1, 604800, "7d"), (6, 2, 1209600, "1209600s")]:
            with self.subTest(unit=unit, number=number):
                self.usage["zai"]["data"]["limits"] = [
                    {"unit": unit, "number": number, "percentage": 29, "nextResetTime": 1900000000123}]
                result = self.run_helper("zai")
                self.assertEqual(result.returncode, 0, result.stderr)
                windows = json.loads(result.stdout)["windows"]
                self.assertEqual(set(windows), {name})
                self.assertEqual(windows[name]["windowSeconds"], seconds)

    def test_claude_windows_spend_and_optional_promo(self):
        value = json.loads(self.run_helper("claude").stdout)
        self.assertEqual(set(value["windows"]), {"5h", "7d", "7d:opus", "7d:fable"})
        self.assertEqual(value["windows"]["5h"]["resetsAt"], RESET)
        self.assertEqual(value["windows"]["7d"]["status"], "warning")
        self.assertEqual(value["windows"]["7d:opus"]["usedPercent"], 12)
        self.assertEqual(value["windows"]["7d:fable"]["usedPercent"], 32)
        self.assertEqual(value["windows"]["7d:fable"]["status"], "inactive")
        self.assertEqual(value["balances"], [{"kind": "extra_usage", "remaining": 187.5, "unit": "USD", "expiresAt": None}])
        self.assertIsNone(value["account"]["plan"])
        self.assertEqual(value["bonuses"], [])
        usage = self.usage["claude"]
        usage.update(five_hour=None, seven_day=None, seven_day_opus=None,
                     seven_day_sonnet={"utilization": 18, "resets_at": "2030-03-17T10:46:40-07:00"}, spend=None)
        usage["limits"][1]["is_active"] = True
        for promo, expected in [(None, []), ([], []), ("unknown", []), (2, []), ({"unknown": 3}, []),
                                ({"count": 4}, [{"kind": "promo_credits", "count": 4, "expiresAt": None}])]:
            with self.subTest(promo=promo):
                usage["promo_credits"] = promo
                value = json.loads(self.run_helper("claude").stdout)
                self.assertEqual(set(value["windows"]), {"7d:sonnet", "7d:fable"})
                self.assertEqual(value["windows"]["7d:sonnet"]["resetsAt"], RESET)
                self.assertEqual(value["windows"]["7d:fable"]["status"], "active")
                self.assertEqual(value["balances"], [])
                self.assertEqual(value["bonuses"], expected)

    def test_direct_claude_matches_proxy(self):
        credentials = self.home / "claude"
        credentials.mkdir()
        (credentials / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {"accessToken": "direct-fixture-token"}}))
        executable = self.home / "bin/curl"
        executable.parent.mkdir()
        executable.write_text(f"#!{sys.executable}\n" + f'''import sys
config = sys.stdin.read()
assert "Authorization: Bearer direct-fixture-token" in config
assert "--config" in sys.argv
assert "direct-fixture-token" not in " ".join(sys.argv)
print({json.dumps(json.dumps(CLAUDE))})
''')
        executable.chmod(0o755)
        direct = self.run_helper("claude", cpa=False, CLAUDE_CONFIG_DIR=str(credentials), PATH=str(executable.parent) + os.pathsep + self.env["PATH"])
        self.assertEqual(direct.returncode, 0, direct.stderr)
        self.assertNotIn("direct-fixture-token", direct.stdout + direct.stderr)
        value = json.loads(direct.stdout)
        self.assertEqual(value["account"], {"auth_index": None, "name": None, "plan": None})
        proxy = json.loads(self.run_helper("claude").stdout)
        proxy["account"] = value["account"]
        self.assertEqual(value, proxy)

    def test_codex_balances_and_expiring_resets_on_both_paths(self):
        self.direct_codex()
        for cpa in [True, False]:
            with self.subTest(cpa=cpa):
                result = self.run_helper("codex", cpa=cpa)
                self.assertEqual(result.returncode, 0, result.stderr)
                value = json.loads(result.stdout)
                self.assertEqual(set(value["windows"]), {"7d", "5h"})
                self.assertEqual(value["windows"]["5h"]["windowSeconds"], 18000)
                self.assertEqual(value["windows"]["7d"]["windowSeconds"], 604800)
                self.assertEqual(value["windows"]["5h"]["usedPercent"], 7 if cpa else 8)
                self.assertEqual(value["windows"]["7d"]["resetsAt"], RESET)
                self.assertEqual(value["account"]["plan"], "test-plan" if cpa else None)
                self.assertEqual(value["balances"], [{"kind": "credits", "remaining": 1234.5, "unit": "credits", "expiresAt": None}])
                self.assertEqual(value["bonuses"], [
                    {"kind": "rate_limit_reset", "count": 1, "expiresAt": RESET},
                    {"kind": "rate_limit_reset", "count": 1, "expiresAt": "2030-03-17T17:47:40Z"}])

    def test_codex_optional_windows_credits_and_duration_names(self):
        for cpa in [True, False]:
            for seconds, name in [(18000, "5h"), (604800, "7d"), (120, "120s")]:
                with self.subTest(cpa=cpa, seconds=seconds):
                    if cpa:
                        usage = self.usage["codex"]
                        usage["rate_limit"]["primary_window"]["limit_window_seconds"] = seconds
                        usage["rate_limit"]["secondary_window"] = None
                        usage["credits"]["has_credits"] = False
                        usage["rate_limit_reset_credits"] = None
                        self.resets = {"credits": []}
                    else:
                        usage = copy.deepcopy(CODEX_DIRECT)
                        usage["rateLimits"]["primary"]["windowDurationMins"] = seconds // 60
                        usage["rateLimits"]["secondary"] = None
                        usage["rateLimits"]["credits"]["hasCredits"] = False
                        usage["rateLimitResetCredits"] = None
                        self.direct_codex(usage)
                    value = json.loads(self.run_helper("codex", cpa=cpa).stdout)
                    self.assertEqual(set(value["windows"]), {name})
                    self.assertEqual(value["windows"][name]["windowSeconds"], seconds)
                    self.assertEqual(value["balances"], [])
                    self.assertEqual(value["bonuses"], [])
        self.usage["codex"]["rate_limit"]["primary_window"] = None
        self.assertEqual(json.loads(self.run_helper("codex").stdout)["windows"], {})
        usage["rateLimits"]["primary"] = None
        self.direct_codex(usage)
        self.assertEqual(json.loads(self.run_helper("codex", cpa=False).stdout)["windows"], {})

    def test_codex_reset_details_fail_without_failing_usage(self):
        for failure in ["transport", "management", "vendor", "malformed", "invalid_json", "invalid_credits", "invalid_expiry"]:
            with self.subTest(failure=failure):
                self.reset_failure = failure
                self.resets = {} if failure == "invalid_credits" else copy.deepcopy(CODEX_RESETS)
                if failure == "invalid_expiry":
                    self.resets["credits"][0]["expires_at"] = "invalid"
                result = self.run_helper("codex")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                value = json.loads(result.stdout)
                self.assertEqual(value["windows"]["7d"]["usedPercent"], 37)
                self.assertEqual(value["bonuses"], [{"kind": "rate_limit_reset", "count": 2, "expiresAt": None}])

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

"""Exercise real curl transport against a local CPA management fixture."""
# cspell:ignore curlrc

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
# Manager+ fixture: endpoint shapes from the pinned 1.14.10 source, synthetic values.
MANAGER_STATUS = {"service": "cpa-manager-plus", "dbPath": "/usage.sqlite",
                  "collector": {"collector": "running", "upstream": "http://127.0.0.1:8317",
                                "mode": "auto", "transport": "http"}}
PROXY_GROUP = {"base-url": "https://api.anthropic.com",
               "keys": [{"api-key": "upstream-private-key", "auth_index": "idx-one"}]}
ANALYTICS = {"generated_at_ms": 1,
             "coverage": {"scope": "time_range", "mode": "mixed", "raw_complete": False,
                          "core_aggregate_used": True, "raw_deleted_event_count": 0,
                          "fidelity_limitations": []},
             "model_stats": [{"model": "claude-fable-5-1", "calls": 27, "total_tokens": 2657502,
                              "cost": 5.0}],
             "summary": {"total_calls": 27, "total_cost": 5.0}}

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
        header = f"#!{shutil.which('bash')}\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n"
        for vendor in ["claude", "codex", "opencode", "zai"]:
            helper = self.home / f"{vendor}-usage"
            helper.write_text(header + (SCRIPTS / "usage-cpa.sh").read_text() + "\n" + (SCRIPTS / f"{vendor}-usage.sh").read_text())
            helper.chmod(0o755)
            self.helpers[vendor] = str(helper)
        proxy = self.home / "proxy-accounted-usage"
        proxy.write_text(header + (SCRIPTS / "usage-cpa.sh").read_text() + "\n" + (SCRIPTS / "proxy-accounted-usage.sh").read_text())
        proxy.chmod(0o755)
        self.helpers["proxy"] = str(proxy)
        self.key = self.home / "management-key"
        self.key.write_text(SECRET + "\n")
        self.files = [self.account("claude", "a"), self.account("codex", "b")]
        self.configs = {"claude": [], "openai-compatibility": []}
        self.requests = []
        self.usage = copy.deepcopy({"claude": CLAUDE, "codex": CODEX, "opencode": OPENCODE, "zai": ZAI})
        self.profile = {"organization": {"uuid": "synthetic-org"}}
        self.prepaid = {"promo_tranches": [], "tranches": []}
        self.claude_failure = None
        self.resets = copy.deepcopy(CODEX_RESETS)
        self.reset_failure = None
        self.management_redirect = None
        self.management_status = 200
        self.envelope = None
        self.raw = None
        self.status_body = copy.deepcopy(MANAGER_STATUS)
        self.analytics = copy.deepcopy(ANALYTICS)
        self.analytics_raw = None
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
                if owner.management_redirect:
                    self.send_response(302)
                    self.send_header("Location", owner.management_redirect)
                    self.end_headers()
                    return
                if self.path == "/status":
                    response = owner.status_body
                elif self.path == "/v0/management/monitoring/analytics":
                    response = owner.analytics
                elif self.path == "/v0/management/auth-files":
                    response = {"files": owner.files}
                elif self.path.startswith("/v8/management/config/api-keys/"):
                    response = owner.configs.get(self.path.rsplit("/", 1)[1])
                    if response is None:
                        self.send_error(404)
                        return
                elif self.path == "/v0/management/api-call":
                    if body["url"].endswith(("/profile", "/prepaid/credits")):
                        endpoint = "profile" if body["url"].endswith("/profile") else "prepaid"
                        failure = owner.claude_failure
                        if failure == endpoint + "-transport":
                            self.close_connection = True
                            return
                        if failure == endpoint + "-management":
                            self.send_error(503)
                            return
                        response = {"status_code": 503 if failure == endpoint + "-vendor" else 200,
                                    "body": "private-response-body" if failure == endpoint + "-json" else json.dumps(getattr(owner, endpoint))}
                    elif body["url"].endswith("/rate-limit-reset-credits"):
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
                        vendor = ("cloudflare" if "api.cloudflare.com" in body["url"] else "zai" if "api.z.ai" in body["url"] else "opencode" if "opencode.ai" in body["url"]
                                  else "claude" if "anthropic.com" in body["url"] else "codex")
                        response = owner.envelope or {"status_code": 200, "body": json.dumps(owner.usage[vendor])}
                else:
                    self.send_error(404)
                    return
                self.send_response(owner.management_status)
                self.end_headers()
                raw = owner.raw
                if raw is None and self.path == "/v0/management/monitoring/analytics":
                    raw = owner.analytics_raw
                self.wfile.write(raw if raw is not None else json.dumps(response).encode())

        self.handler = Handler
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.addCleanup(self.server.server_close)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("DELEGATE_USAGE_CPA_", "MANAGER_"))}
        self.env.update(HOME=str(self.home), TZ="America/Denver")
        # Never invoke the installed CLI or its login while measuring headers.
        cli = self.home / "cli/claude"
        cli.parent.mkdir()
        cli.write_text(header + "[[ \"$*\" == --version ]]\nprintf '%s\\n' '9.8.7 (Claude Code)'\n")
        cli.chmod(0o755)
        self.env["PATH"] = str(cli.parent) + os.pathsep + self.env["PATH"]

    @staticmethod
    def account(provider, index, **extra):
        return dict(provider=provider, account_type="oauth", auth_index=index, disabled=False, email=f"{index}@example.test", **extra)

    def run_helper(self, vendor, cpa=True, route=None, **overrides):
        env = self.env.copy()
        routed = vendor in ("cloudflare", "opencode", "zai")
        route = route or ("claude" if routed else vendor)
        if cpa:
            env.update({f"DELEGATE_USAGE_CPA_{route.upper()}_URL": self.url,
                        f"DELEGATE_USAGE_CPA_{route.upper()}_MANAGEMENT_KEY_FILE": str(self.key)})
        env.update(overrides)
        result = subprocess.run([self.helpers[vendor]] + ([route] if routed else []), env=env, text=True, capture_output=True, timeout=10)
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
        self.assertEqual(set(value), {"pool", "account", "windows", "balances", "bonuses"} |
                         ({"credit", "grants", "missingExtras"} if vendor == "claude" else set()))
        self.assertEqual(value["pool"], vendor)
        self.assertEqual(set(value["account"]), {"auth_index", "name", "plan"})
        for field in value["account"].values():
            self.assertTrue(field is None or isinstance(field, str))
        self.assertIsInstance(value["windows"], dict)
        for name, window in value["windows"].items():
            self.assertEqual(set(window), {"usedPercent", "remainingPercent", "resetsAt", "status", "windowSeconds"})
            self.assertIsInstance(window["windowSeconds"], (int, float))
            seconds = window["windowSeconds"]
            self.assertEqual(name.split(":", 1)[0], "daily" if vendor == "cloudflare" else {18000: "5h", 604800: "7d"}.get(seconds, "monthly" if 2419200 <= seconds <= 2678400 else f"{seconds}s"))
            if vendor == "claude":
                self.assertEqual(seconds, 18000 if name == "5h" else 604800)
            self.assertIsInstance(window["usedPercent"], (int, float))
            self.assertEqual(window["remainingPercent"], 100 - window["usedPercent"])
            self.assertTrue(window["status"] is None or isinstance(window["status"], str))
            if window["resetsAt"] is None:
                self.assertEqual(window["usedPercent"], 0)
            else:
                self.assert_utc(window["resetsAt"])
        for field, amount in [("balances", "remaining"), ("bonuses", "remaining" if vendor == "claude" else "count")]:
            self.assertIsInstance(value[field], list)
            for entry in value[field]:
                expected = {"kind", amount, "expiresAt"} | ({"unit"} if field == "balances" else set())
                if vendor == "claude":
                    expected |= {"funding", "scope"} if field == "balances" else {"clears", "funding", "givesBackWeekly", "handle", "unit", "usable"}
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

    def proxy_command(self, *extra, now="1793707200000", day="1", zone="UTC", limit="100"):
        return ["--provider", "claude", "--base-url", "https://api.anthropic.com",
                "--limit", limit, "--reset-day", day, "--time-zone", zone,
                "--pool", "anthropic-api", "--account-name", "personal-anthropic-api",
                "--now-ms", now, *extra]

    def run_proxy(self, *args, **overrides):
        env = self.env.copy()
        env.update({"MANAGER_URL": self.url, "MANAGER_KEY_FILE": str(self.key)})
        env.update(overrides)
        result = subprocess.run([self.helpers["proxy"], *args], env=env, text=True, capture_output=True, timeout=10)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        if result.returncode == 0:
            self.assert_monthly_schema(json.loads(result.stdout))
        return result

    def assert_monthly_schema(self, value):
        self.assertEqual(set(value), {"pool", "account", "windows", "balances", "bonuses"})
        self.assertEqual(set(value["account"]), {"auth_index", "name", "plan"})
        self.assertIsNone(value["account"]["plan"])
        self.assertTrue(value["account"]["auth_index"] is None or isinstance(value["account"]["auth_index"], str))
        self.assertEqual(set(value["windows"]), {"monthly"})
        window = value["windows"]["monthly"]
        self.assertEqual(set(window), {"usedPercent", "remainingPercent", "resetsAt", "status", "windowSeconds"})
        self.assertEqual(window["status"], "estimated")
        self.assert_utc(window["resetsAt"])
        for field in ["usedPercent", "remainingPercent", "windowSeconds"]:
            self.assertIsInstance(window[field], (int, float))
        # A real calendar month in any zone, DST included, is 28 days minus one
        # hour (a DST-shortened February) to 31 days plus one hour long.
        self.assertGreaterEqual(window["windowSeconds"], 28 * 86400 - 3600)
        self.assertLessEqual(window["windowSeconds"], 31 * 86400 + 3600)
        self.assertEqual(window["remainingPercent"], max(0, 100 - window["usedPercent"]))
        self.assertEqual(value["balances"], [])
        self.assertEqual(value["bonuses"], [])

    def test_proxy_reader_schema_and_requests(self):
        self.configs["claude"] = [PROXY_GROUP]
        self.requests.clear()
        result = self.run_proxy(*self.proxy_command())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(json.loads(result.stdout), {
            "pool": "anthropic-api",
            "account": {"auth_index": "idx-one", "name": "personal-anthropic-api", "plan": None},
            "windows": {"monthly": {"usedPercent": 5, "remainingPercent": 95,
                                    "resetsAt": "2026-12-01T00:00:00Z", "status": "estimated",
                                    "windowSeconds": 2592000}},
            "balances": [], "bonuses": []})
        self.assertEqual([(method, path) for method, path, headers, body in self.requests],
                         [("GET", "/status"),
                          ("GET", "/v8/management/config/api-keys/claude"),
                          ("POST", "/v0/management/monitoring/analytics")])
        for method, path, headers, body in self.requests:
            self.assertEqual(headers["Authorization"], f"Bearer {SECRET}")
        analytics_request = self.requests[-1][3]
        self.assertEqual(analytics_request["from_ms"], 1793491200000)
        self.assertEqual(analytics_request["to_ms"], 1793707200000)
        self.assertEqual(analytics_request["time_zone"], "UTC")
        self.assertEqual(analytics_request["filters"], {"auth_indices": ["idx-one"], "include_failed": True})
        self.assertEqual(analytics_request["include"], {"summary": True, "summary_profile": "compact", "model_stats": True})

    def test_proxy_window_calendar_lengths(self):
        self.configs["claude"] = [PROXY_GROUP]
        for now, day, zone, seconds, resets in [
            # A window opened on November 15 closes in December: the month boundary.
            ("1796274000000", "15", "UTC", 2592000, "2026-12-15T00:00:00Z"),
            # January spans 31 days; February 2027 spans 28.
            ("1800003600000", "1", "UTC", 2678400, "2027-02-01T00:00:00Z"),
            ("1802250000000", "1", "UTC", 2419200, "2027-03-01T00:00:00Z"),
            # Denver falls back inside the November window (30 days plus one hour)
            # and springs forward inside the March window (31 days minus one hour).
            ("1793732400000", "1", "America/Denver", 2595600, "2026-12-01T07:00:00Z"),
            ("1773165600000", "1", "America/Denver", 2674800, "2026-04-01T06:00:00Z"),
            # A Denver window from mid-February to mid-March 2027 spans spring
            # forward: a DST-shortened 28-day month, one hour less.
            ("1803150000000", "15", "America/Denver", 2415600, "2027-03-15T06:00:00Z"),
        ]:
            with self.subTest(now=now, zone=zone, day=day):
                result = self.run_proxy(*self.proxy_command(now=now, day=day, zone=zone))
                self.assertEqual(result.returncode, 0, result.stderr)
                window = json.loads(result.stdout)["windows"]["monthly"]
                self.assertEqual(window["windowSeconds"], seconds)
                self.assertEqual(window["resetsAt"], resets)

    def test_proxy_limit_percent_clamping(self):
        self.configs["claude"] = [PROXY_GROUP]
        for cost, used, remaining in [(250.0, 250, 0), (100.0, 100, 0), (0.0, 0, 100)]:
            with self.subTest(cost=cost):
                self.analytics["summary"]["total_cost"] = cost
                window = json.loads(self.run_proxy(*self.proxy_command()).stdout)["windows"]["monthly"]
                self.assertEqual(window["usedPercent"], used)
                self.assertEqual(window["remainingPercent"], remaining)
        # Exponent notation is a fine finite limit.
        self.analytics["summary"]["total_cost"] = 5.0
        window = json.loads(self.run_proxy(*self.proxy_command(limit="1e2")).stdout)["windows"]["monthly"]
        self.assertEqual(window["usedPercent"], 5)

    def test_proxy_used_percent_must_be_finite(self):
        self.configs["claude"] = [PROXY_GROUP]
        # cost / limit * 100 keeps representable magnitudes exact instead of
        # overflowing the scaled product first.
        self.analytics["summary"]["total_cost"] = 1e307
        window = json.loads(self.run_proxy(*self.proxy_command(limit="1e10")).stdout)["windows"]["monthly"]
        self.assertEqual(window["usedPercent"], 1e299)
        self.assertEqual(window["remainingPercent"], 0)
        # A percent no double can hold fails rather than printing a clamped one.
        self.analytics["summary"]["total_cost"] = 1e308
        result = self.run_proxy(*self.proxy_command(limit="1e-10"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "usage: proxy used percent is not finite\n")
        self.assertEqual(result.stdout, "")

    def test_proxy_credential_counts(self):
        other = {"base-url": "https://other.example.test", "keys": [{"auth_index": "idx-two"}]}
        twice = [PROXY_GROUP, {"base-url": "https://api.anthropic.com", "keys": [{"auth_index": "idx-two"}]}]
        for groups, count in [([], 0), ([other], 0), (twice, 2)]:
            with self.subTest(count=count):
                self.configs["claude"] = groups
                result = self.run_proxy(*self.proxy_command())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"credential discovery matched {count} credentials", result.stderr)
                self.assertEqual(result.stdout, "")
        # An absent provider collection is zero credentials, not a transport error.
        self.configs.pop("claude")
        result = self.run_proxy(*self.proxy_command())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("credential discovery matched 0 credentials", result.stderr)

    def test_proxy_auth_index_pins(self):
        self.configs["claude"] = [PROXY_GROUP, {"base-url": "https://api.anthropic.com",
                                                "keys": [{"auth_index": "idx-two"}]}]

        def analytics_filter():
            return [body for method, path, headers, body in self.requests
                    if path == "/v0/management/monitoring/analytics"][-1]["filters"]["auth_indices"]

        # A pin resolves an otherwise ambiguous credential set without discovery.
        self.requests.clear()
        result = self.run_proxy(*self.proxy_command("--auth-index", "idx-two"))
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value["account"]["auth_index"], "idx-two")
        self.assertEqual(analytics_filter(), ["idx-two"])
        self.assertEqual([path for method, path, headers, body in self.requests],
                         ["/status", "/v0/management/monitoring/analytics"])
        # Several pins cover a rotation; no single index can name the account.
        result = self.run_proxy(*self.proxy_command("--auth-index", "idx-old", "--auth-index", "idx-two"))
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertIsNone(value["account"]["auth_index"])
        self.assertEqual(analytics_filter(), ["idx-old", "idx-two"])
        # Surrounding whitespace is trimmed so the filter stays exact.
        result = self.run_proxy(*self.proxy_command("--auth-index", "  idx-two\t"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(analytics_filter(), ["idx-two"])
        # An all-whitespace pin is rejected before any request leaves.
        self.requests.clear()
        result = self.run_proxy(*self.proxy_command("--auth-index", "   "))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires a nonempty value for --auth-index", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.requests, [])

    def test_proxy_unpriced_models_fail(self):
        self.configs["claude"] = [PROXY_GROUP]
        # Manager+ prices a stat through its billing or pricing model, so a
        # display alias with a positive cost is priced with no key of its own:
        # coverage is judged from the analytics rows alone, never a price book.
        self.analytics["model_stats"].append({"model": "claude-fable-5-1-alias", "calls": 9,
                                              "total_tokens": 100, "cost": 1.5})
        result = self.run_proxy(*self.proxy_command())
        self.assertEqual(result.returncode, 0, result.stderr)
        # A row that consumed tokens and costs zero reads as unpriced; calls
        # without tokens (failed before use) cost nothing legitimately. The
        # count is reported, never model names.
        for stats, count in [
            ([{"model": "claude-mystery-5", "calls": 3, "total_tokens": 10, "cost": 0}], 1),
            ([{"model": "claude-mystery-5", "calls": 0, "total_tokens": 10, "cost": 0}], 1),
            ([{"model": "claude-failed-only", "calls": 3, "total_tokens": 0, "cost": 0}], 0),
            ([{"model": "a", "calls": 3, "total_tokens": 10, "cost": 0},
              {"model": "b", "calls": 4, "total_tokens": 20, "cost": 0}], 2),
            ([{"model": "claude-no-traffic", "calls": 0, "total_tokens": 0, "cost": 0}], 0),
        ]:
            with self.subTest(count=count):
                self.analytics = copy.deepcopy(ANALYTICS)
                self.analytics["model_stats"].extend(stats)
                result = self.run_proxy(*self.proxy_command())
                if count:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stderr, f"usage: proxy analytics contain {count} unpriced models\n")
                    self.assertNotIn("claude-mystery-5", result.stderr)
                    self.assertEqual(result.stdout, "")
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
        # The rows that judge coverage must themselves be well typed.
        for field, value in [("calls", "many"), ("calls", -3), ("total_tokens", "lots"),
                             ("total_tokens", -1), ("cost", "free"), ("cost", -1)]:
            with self.subTest(field=field, value=value):
                self.analytics = copy.deepcopy(ANALYTICS)
                self.analytics["model_stats"][0][field] = value
                result = self.run_proxy(*self.proxy_command())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid analytics response", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_proxy_model_stats_required_with_calls(self):
        self.configs["claude"] = [PROXY_GROUP]
        # model_stats may be empty only when total_calls is zero: without rows,
        # coverage cannot be judged.
        for stats in ["absent", None, []]:
            for calls, ok in [(27, False), (0, True)]:
                with self.subTest(stats=stats, calls=calls):
                    self.analytics = copy.deepcopy(ANALYTICS)
                    self.analytics["summary"]["total_calls"] = calls
                    if calls == 0:
                        self.analytics["summary"]["total_cost"] = 0
                    if stats == "absent":
                        self.analytics.pop("model_stats")
                    else:
                        self.analytics["model_stats"] = stats
                    result = self.run_proxy(*self.proxy_command())
                    if ok:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(json.loads(result.stdout)["windows"]["monthly"]["usedPercent"], 0)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(result.stderr, "usage: proxy invalid analytics response\n")
                        self.assertEqual(result.stdout, "")

    def test_proxy_cost_and_coverage_fail_closed(self):
        self.configs["claude"] = [PROXY_GROUP]
        for cost in [-5.0, float("nan"), float("inf")]:
            with self.subTest(cost=cost):
                self.analytics = copy.deepcopy(ANALYTICS)
                self.analytics["summary"]["total_cost"] = cost
                result = self.run_proxy(*self.proxy_command())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid analytics response", result.stderr)
                self.assertEqual(result.stdout, "")
        # A malformed coverage object is a bad response, not a clean one.
        for field, value in [("fidelity_limitations", "core_metrics_require_raw_events"),
                             ("fidelity_limitations", 7),
                             ("raw_deleted_event_count", "many"),
                             ("raw_deleted_event_count", -3)]:
            with self.subTest(field=field, value=value):
                self.analytics = copy.deepcopy(ANALYTICS)
                self.analytics["coverage"][field] = value
                result = self.run_proxy(*self.proxy_command())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid analytics response", result.stderr)
                self.assertEqual(result.stdout, "")
        # Exactly one JSON document may reach the projection, and no jq
        # diagnostic may leak around the fixed message.
        self.analytics_raw = (json.dumps(ANALYTICS) + "\n" + json.dumps(ANALYTICS)).encode()
        result = self.run_proxy(*self.proxy_command())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "usage: proxy invalid analytics response\n")
        self.assertEqual(result.stdout, "")
        self.analytics_raw = None

    def test_proxy_reset_instant_reports_zero(self):
        self.configs["claude"] = [PROXY_GROUP]
        self.requests.clear()
        # now is the exact window start: Manager+ rejects an empty range, and
        # nothing has been spent in the new window yet.
        result = self.run_proxy(*self.proxy_command(now="1793491200000"))
        self.assertEqual(result.returncode, 0, result.stderr)
        window = json.loads(result.stdout)["windows"]["monthly"]
        self.assertEqual(window["usedPercent"], 0)
        self.assertEqual(window["remainingPercent"], 100)
        self.assertEqual(window["windowSeconds"], 2592000)
        self.assertEqual([path for method, path, headers, body in self.requests],
                         ["/status", "/v8/management/config/api-keys/claude"])

    def test_proxy_failures_are_explicit_without_response_bodies(self):
        self.configs["claude"] = [PROXY_GROUP]
        self.status_body["collector"]["collector"] = "stopped"
        result = self.run_proxy(*self.proxy_command())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("collector is not running", result.stderr)
        self.assertEqual(result.stdout, "")
        self.status_body["collector"]["collector"] = "running"
        for field, value in [("raw_deleted_event_count", 5),
                             ("fidelity_limitations", ["core_metrics_require_raw_events"]),
                             ("fidelity_limitations", ["extended_summary_metrics_require_raw_events"])]:
            with self.subTest(field=field, value=value):
                self.analytics = copy.deepcopy(ANALYTICS)
                self.analytics["coverage"][field] = value
                result = self.run_proxy(*self.proxy_command())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("cost coverage incomplete", result.stderr)
                self.assertEqual(result.stdout, "")
        for bad in [{"summary": {}}, {"summary": {"total_cost": "5"}}, {"coverage": "degraded"}, {}]:
            with self.subTest(bad=bad):
                self.analytics = bad
                result = self.run_proxy(*self.proxy_command())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid analytics response", result.stderr)
                self.assertEqual(result.stdout, "")
        self.analytics = copy.deepcopy(ANALYTICS)
        # A body that is not JSON fails on the first route it reaches; the body
        # itself never surfaces.
        self.raw = b"private-response-body"
        result = self.run_proxy(*self.proxy_command())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid status response", result.stderr)
        self.assertNotIn("private-response-body", result.stdout + result.stderr)
        self.raw = None
        self.management_status = 500
        result = self.run_proxy(*self.proxy_command())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("management HTTP 500", result.stderr)
        self.assertNotIn("private-response-body", result.stderr)
        self.management_status = 200
        self.key.write_text("line\nbreak")
        result = self.run_proxy(*self.proxy_command())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("single line", result.stderr)

    def test_proxy_argument_and_environment_errors(self):
        self.configs["claude"] = [PROXY_GROUP]
        base = ["--limit", "100", "--reset-day", "1",
                "--pool", "anthropic-api", "--account-name", "a"]
        for env, args, expected in [
            ({"MANAGER_URL": ""}, self.proxy_command(), "requires MANAGER_URL"),
            ({"MANAGER_KEY_FILE": ""}, self.proxy_command(), "requires MANAGER_URL"),
            ({}, self.proxy_command(limit="0"), "finite positive number"),
            ({}, self.proxy_command(limit="zero"), "finite positive number"),
            # Only finite values are limits, whatever jq's tonumber tolerates.
            ({}, self.proxy_command(limit="Infinity"), "finite positive number"),
            ({}, self.proxy_command(limit="inf"), "finite positive number"),
            ({}, self.proxy_command(limit="NaN"), "finite positive number"),
            ({}, self.proxy_command(limit="nan"), "finite positive number"),
            ({}, self.proxy_command(limit="1e999"), "finite positive number"),
            ({}, self.proxy_command(day="0"), "from 1 through 28"),
            ({}, self.proxy_command(day="29"), "from 1 through 28"),
            ({}, self.proxy_command(now="yesterday"), "epoch milliseconds"),
            ({}, base, "credential discovery requires --provider"),
            ({}, base[2:], "requires --limit"),
            ({}, base[:2] + base[4:], "requires --reset-day"),
            ({}, base[:4] + base[6:], "requires --pool"),
            ({}, base[:6], "requires --account-name"),
            # The limit is USD only; --unit no longer exists.
            ({}, ["--unit", "USD", *self.proxy_command()], "unknown argument --unit"),
            ({}, self.proxy_command("--provider", "claude", "--bogus-flag"), "unknown argument"),
        ]:
            with self.subTest(expected=expected, args=args):
                result = self.run_proxy(*args, **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertEqual(result.stdout, "")
        # A missing key file prints only the fixed message, never a shell
        # redirection diagnostic before it.
        result = self.run_proxy(*self.proxy_command(), MANAGER_KEY_FILE=str(self.home / "absent"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "usage: proxy cannot read management key file\n")
        self.assertEqual(result.stdout, "")
        # Argument and environment errors fail before any request leaves the process.
        self.assertEqual(self.requests, [])
        # The zone name itself is validated by the window arithmetic.
        result = self.run_proxy(*self.proxy_command(zone="Mars/Olympus_Mons"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid time zone", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_proxy_key_never_reaches_tool_arguments_or_environment(self):
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
        self.configs["claude"] = [PROXY_GROUP]
        result = self.run_proxy(*self.proxy_command(), PATH=str(binary) + os.pathsep + self.env["PATH"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("upstream-private-key", result.stdout + result.stderr)

    def test_proxy_real_clock_window(self):
        self.configs["claude"] = [PROXY_GROUP]
        result = self.run_proxy(*self.proxy_command()[:-2])
        self.assertEqual(result.returncode, 0, result.stderr)
        window = json.loads(result.stdout)["windows"]["monthly"]
        self.assertGreaterEqual(window["windowSeconds"], 28 * 86400)
        self.assertLessEqual(window["windowSeconds"], 31 * 86400 + 3600)

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
                        expected_url = "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1" if vendor == "claude" else "https://chatgpt.com/backend-api/wham/usage"
                        self.assertIn(body["url"], [expected_url] + (["https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"] if vendor == "codex" else ["https://api.anthropic.com/api/oauth/profile", "https://api.anthropic.com/api/oauth/organizations/synthetic-org/prepaid/credits"]))
                if vendor == "claude":
                    self.assertEqual(values[0]["windows"]["5h"]["usedPercent"], 23)
                    self.assertEqual(len(self.requests), 4)
                    self.assertTrue(all(request[3]["header"]["User-Agent"] == "claude-cli/9.8.7 (external, cli)" for request in self.requests[1:]))
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

    def test_zai_unstarted_window_has_no_reset(self):
        self.configs["claude"] = [{"base-url": "https://api.z.ai/api/anthropic",
                                    "keys": [{"api-key": "unstarted-fixture", "auth_index": "z1"}]}]
        self.usage["zai"]["data"]["limits"] = [
            {"unit": 3, "number": 5, "percentage": 0},
            {"unit": 6, "number": 1, "percentage": 18, "nextResetTime": 1900000000123}]
        result = self.run_helper("zai")
        self.assertEqual(result.returncode, 0, result.stderr)
        windows = json.loads(result.stdout)["windows"]
        self.assertEqual(windows["5h"], {"usedPercent": 0, "remainingPercent": 100, "resetsAt": None,
                                         "status": None, "windowSeconds": 18000})
        self.assertEqual(windows["7d"]["resetsAt"], RESET)
        self.usage["zai"]["data"]["limits"][0]["percentage"] = 4
        result = self.run_helper("zai")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid vendor usage response", result.stderr)

    def test_claude_windows_spend_and_optional_promo(self):
        value = json.loads(self.run_helper("claude").stdout)
        self.assertEqual(set(value["windows"]), {"5h", "7d", "7d:opus", "7d:fable"})
        self.assertEqual(value["windows"]["5h"]["resetsAt"], RESET)
        self.assertEqual(value["windows"]["7d"]["status"], "warning")
        self.assertEqual(value["windows"]["7d:opus"]["usedPercent"], 12)
        self.assertEqual(value["windows"]["7d:fable"]["usedPercent"], 32)
        self.assertEqual(value["windows"]["7d:fable"]["status"], "inactive")
        self.assertEqual(value["balances"], [])
        self.assertEqual(value["credit"], {"cap": CLAUDE["spend"]["limit"], "spent": CLAUDE["spend"]["used"],
                                           "periodStart": None, "periodEnd": None, "usable": None})
        self.assertIsNone(value["account"]["plan"])
        self.assertEqual(value["bonuses"], [])
        usage = self.usage["claude"]
        usage.update(five_hour=None, seven_day=None, seven_day_opus=None,
                     seven_day_sonnet={"utilization": 18, "resets_at": "2030-03-17T10:46:40-07:00"}, spend=None)
        usage["limits"][1]["is_active"] = True
        for promo, expected in [(None, []), ([], []), ("unknown", []), (2, []), ({"unknown": 3}, []),
                                ({"count": 4}, [])]:
            with self.subTest(promo=promo):
                usage["promo_credits"] = promo
                value = json.loads(self.run_helper("claude").stdout)
                self.assertEqual(set(value["windows"]), {"7d:sonnet", "7d:fable"})
                self.assertEqual(value["windows"]["7d:sonnet"]["resetsAt"], RESET)
                self.assertEqual(value["windows"]["7d:fable"]["status"], "active")
                self.assertEqual(value["balances"], [])
                self.assertEqual(value["bonuses"], expected)

    def test_claude_grant_facts_do_not_invent_effects(self):
        # Rejects type/name-derived effects, lost opaque handles and false-as-null.
        grant = {"id": "opaque/handle", "type": "full", "resets_left": 2, "resets_total": 3,
                 "clears": ["five_hour", "seven_day", "unrecognized_meter"],
                 "ends_at": RESET, "starts_at": None, "paused": False,
                 "usable_now": True, "gives_back_weekly": False, "use_requires_limit": True}
        self.usage["claude"]["cedar_ember"] = {"eligible": True, "grants": [grant],
                                                "weekly_resets_at": RESET}
        value = json.loads(self.run_helper("claude").stdout)
        self.assertEqual(value["bonuses"], [{"kind": "rate_limit_reset", "handle": "opaque/handle",
                                          "remaining": 2, "unit": "resets", "funding": "promotional",
                                          "clears": ["five_hour", "seven_day", "unrecognized_meter"],
                                          "givesBackWeekly": False, "usable": True, "expiresAt": RESET}])
        self.assertEqual(value["grants"]["weekly_resets_at"], RESET)
        self.assertEqual(value["grants"]["grants"][0]["resets_total"], 3)
        self.assertEqual(value["missingExtras"], [])
        grant.update(gives_back_weekly=True, clears=["seven_day_overage_included"], ends_at=None)
        value = json.loads(self.run_helper("claude").stdout)
        self.assertEqual(value["bonuses"][0]["clears"], ["seven_day_overage_included"])
        self.assertTrue(value["bonuses"][0]["givesBackWeekly"])
        self.assertIsNone(value["bonuses"][0]["expiresAt"])
        self.assertNotIn("scope", value["bonuses"][0])
        for field, setting, expected in [("eligible", False, False), ("eligible", None, None),
                                         ("paused", True, False), ("paused", None, None),
                                         ("usable_now", False, False), ("usable_now", None, None)]:
            with self.subTest(field=field, setting=setting):
                status = self.usage["claude"]["cedar_ember"]
                status["eligible"] = True
                grant.update(paused=False, usable_now=True)
                (status if field == "eligible" else grant)[field] = setting
                value = json.loads(self.run_helper("claude").stdout)
                self.assertIs(value["bonuses"][0]["usable"], expected)

    def test_claude_wallet_is_independent_of_cap_spend_and_period(self):
        # Rejects cap-minus-spend as wallet and unknown cap as unlimited.
        self.prepaid = {"promo_tranches": [{"currency": "USD", "remaining_amount_minor_units": 2345,
                                            "expires_at": RESET}],
                        "tranches": [{"currency": "USD", "remaining_amount_minor_units": 7600,
                                      "expires_at": None}]}
        for spend in [None, {}, "invalid", CLAUDE["spend"], {"limit": CLAUDE["spend"]["limit"]}]:
            with self.subTest(spend=spend):
                self.usage["claude"]["spend"] = spend
                value = json.loads(self.run_helper("claude").stdout)
                self.assertEqual(value["balances"], [
                    {"kind": "usage_credit", "funding": "promotional", "remaining": 23.45,
                     "unit": "USD", "expiresAt": RESET, "scope": None},
                    {"kind": "usage_credit", "funding": "purchased", "remaining": 76,
                     "unit": "USD", "expiresAt": None, "scope": None}])
                self.assertIsNone(value["credit"]["usable"])
                self.assertIsNone(value["credit"]["periodStart"])
                self.assertIsNone(value["credit"]["periodEnd"])
                self.assertEqual(value["windows"]["7d"]["remainingPercent"], 39)

    def test_claude_optional_failures_keep_allowance_and_other_inventory(self):
        # Rejects optional transport/shape failures erasing the main windows.
        self.usage["claude"]["cedar_ember"] = {"eligible": True, "grants": [
            {"id": "grant", "resets_left": 1, "clears": ["five_hour"], "paused": False,
             "usable_now": True, "ends_at": None}]}
        for endpoint in ["profile", "prepaid"]:
            for failure in ["json", "management", "transport", "vendor"]:
                with self.subTest(endpoint=endpoint, failure=failure):
                    self.claude_failure = endpoint + "-" + failure
                    result = self.run_helper("claude")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn("private-response-body", result.stdout + result.stderr)
                    value = json.loads(result.stdout)
                    self.assertEqual(value["windows"]["7d"]["remainingPercent"], 39)
                    self.assertEqual(value["bonuses"][0]["remaining"], 1)
                    self.assertEqual(value["balances"], [])
                    self.assertIn("claude-prepaid-organization-unknown" if endpoint == "profile"
                                  else "claude-prepaid-unavailable", value["missingExtras"])
        self.claude_failure = None
        for invalid in [{}, {"promo_tranches": [], "tranches": [{}]}]:
            self.prepaid = invalid
            value = json.loads(self.run_helper("claude").stdout)
            self.assertEqual(value["bonuses"][0]["remaining"], 1)
            self.assertEqual(value["missingExtras"], ["claude-prepaid-unavailable"])
        self.prepaid = {"promo_tranches": [], "tranches": []}
        for grants in [None, "invalid", [{"id": "bad"}]]:
            self.usage["claude"]["cedar_ember"]["grants"] = grants
            value = json.loads(self.run_helper("claude").stdout)
            self.assertEqual(value["bonuses"], [])
            self.assertEqual(value["windows"]["7d"]["remainingPercent"], 39)
            self.assertEqual(value["missingExtras"], ["claude-grants-unavailable"])

        for discovery in [None, "invalid", []]:
            self.usage["claude"]["cedar_ember"] = discovery
            value = json.loads(self.run_helper("claude").stdout)
            self.assertEqual(value["windows"]["7d"]["remainingPercent"], 39)
            self.assertEqual(value["missingExtras"], ["claude-grants-unavailable"])

    def test_claude_vendor_status_is_safe_and_main_failure_stops_extras(self):
        # Reports numeric upstream status without leaking the body or fetching extras.
        for status in [401, 429, 503]:
            with self.subTest(status=status):
                self.requests.clear()
                self.envelope = {"status_code": status, "body": "private-response-body"}
                result = self.run_helper("claude")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"vendor HTTP {status}", result.stderr)
                self.assertNotIn("private-response-body", result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(len(self.requests), 2)

    def test_claude_envelope_types_and_body_transport(self):
        # Reject malformed envelopes and preserve opaque body text through transport.
        for envelope in [{"status_code": "200", "body": "private-response-body"},
                         {"status_code": 200, "body": {"private-response-body": True}},
                         {"status_code": None, "body": "private-response-body"}]:
            with self.subTest(envelope=envelope):
                self.envelope = envelope
                result = self.run_helper("claude")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("claude usage request failed", result.stderr)
                self.assertNotIn("private-response-body", result.stderr)
                self.assertEqual(result.stdout, "")
        usage = copy.deepcopy(CLAUDE)
        usage["cedar_ember"] = {"grants": [], "note": "tab\tline\nsnowman \u2603 $(false)"}
        self.envelope = {"status_code": 200, "body": json.dumps(usage, indent=2, ensure_ascii=False)}
        result = self.run_helper("claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["grants"], usage["cedar_ember"])

    def test_claude_projector_observation_is_explicit(self):
        # Usage ignores optional inventory, and an unknown mode cannot select usage.
        for observation in ["usage", "unknown"]:
            result = subprocess.run(
                ["bash", "-c", 'set -euETo pipefail; shopt -s inherit_errexit 2>/dev/null || :; '
                 'source "$1"; usage_project claude null null "{}" "$2"',
                 "projector-test", str(SCRIPTS / "usage-cpa.sh"), observation],
                input=json.dumps(CLAUDE), text=True, capture_output=True)
            if observation == "usage":
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["balances"], [])
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_claude_empty_inventory_is_observed_and_invalid_lot_is_unavailable(self):
        # Distinguishes zero observations from rejected data without erasing windows.
        self.usage["claude"]["cedar_ember"] = {"grants": []}
        value = json.loads(self.run_helper("claude").stdout)
        self.assertEqual(value["missingExtras"], [])
        self.assertEqual(value["bonuses"], [])
        self.assertEqual(value["balances"], [])
        for field, invalid in [("currency", "EUR"), ("remaining_amount_minor_units", -1),
                               ("remaining_amount_minor_units", "1"), ("expires_at", "invalid")]:
            with self.subTest(field=field, invalid=invalid):
                lot = {"currency": "USD", "remaining_amount_minor_units": 1, "expires_at": None}
                lot[field] = invalid
                self.prepaid = {"promo_tranches": [lot], "tranches": []}
                value = json.loads(self.run_helper("claude").stdout)
                self.assertEqual(value["balances"], [])
                self.assertEqual(value["missingExtras"], ["claude-prepaid-unavailable"])
                self.assertEqual(value["windows"]["7d"]["remainingPercent"], 39)

    def test_direct_claude_matches_proxy(self):
        # Rejects divergent projections and a direct-only loss of optional data.
        self.usage["claude"]["cedar_ember"] = {"eligible": True, "grants": [
            {"id": "direct-grant", "resets_left": 2, "clears": ["seven_day"],
             "paused": False, "usable_now": True, "gives_back_weekly": False, "ends_at": RESET}]}
        self.prepaid = {"promo_tranches": [{"currency": "USD", "remaining_amount_minor_units": 1234,
                                           "expires_at": RESET}], "tranches": []}
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
assert "User-Agent: claude-cli/9.8.7 (external, cli)" in config
assert "reset_rate_limits" not in config
if "/profile" in config:
    print({json.dumps(json.dumps({"organization": {"uuid": "synthetic-org"}}))})
elif "/prepaid/credits" in config:
    print({json.dumps(json.dumps(self.prepaid))})
else:
    assert "cedar_ember=1&skip_spend=1" in config
    print({json.dumps(json.dumps(self.usage["claude"]))})
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
        self.assertEqual(value["balances"][0]["remaining"], 12.34)
        self.assertEqual(value["bonuses"][0]["remaining"], 2)
        executable.write_text(executable.read_text().replace(
            'elif "/prepaid/credits" in config:', 'elif "/prepaid/credits" in config:\n    sys.exit(22)'))
        direct = self.run_helper("claude", cpa=False, CLAUDE_CONFIG_DIR=str(credentials),
                                 PATH=str(executable.parent) + os.pathsep + self.env["PATH"])
        self.assertEqual(direct.returncode, 0, direct.stderr)
        value = json.loads(direct.stdout)
        self.assertEqual(value["balances"], [])
        self.assertEqual(value["bonuses"][0]["remaining"], 2)
        self.assertEqual(value["missingExtras"], ["claude-prepaid-unavailable"])

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
        # A Codex body with no window at all is a shape regression, not an empty pool.
        self.usage["codex"]["rate_limit"]["primary_window"] = None
        result = self.run_helper("codex")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid vendor usage response", result.stderr)
        usage["rateLimits"]["primary"] = None
        self.direct_codex(usage)
        result = self.run_helper("codex", cpa=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid codex usage response", result.stderr)

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
                    "5h": {"status": "ok", "usedPercent": 12.5, "remainingPercent": 87.5, "resetsAt": RESET, "windowSeconds": 18000},
                    "7d": {"status": "rate-limited", "usedPercent": 100, "remainingPercent": 0, "resetsAt": RESET, "windowSeconds": 604800},
                    "monthly": {"status": "ok", "usedPercent": 40, "remainingPercent": 60, "resetsAt": RESET, "windowSeconds": 2419200}})
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
                         {"status_code": 200, "body": json.dumps({"usage": dict(OPENCODE["usage"], weekly={"status": 1, "percent": 1, "resetsAt": "2030-03-17T17:46:40Z"})})},
                         {"status_code": 200, "body": json.dumps({"usage": dict(OPENCODE["usage"], weekly={"status": "ok", "percent": 1e999, "resetsAt": "2030-03-17T17:46:40Z"})}).replace("Infinity", "1e999")},
                         {"status_code": 200, "body": "private-response-body"}]:
            with self.subTest(envelope=envelope["body"][:40]):
                self.envelope = envelope
                result = self.run_helper("opencode")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("vendor HTTP 403" if envelope["status_code"] == 403 else "invalid vendor usage", result.stderr)
                self.assertNotIn("private-response-body", result.stdout + result.stderr)
                self.assertEqual(result.stdout, "")

    def test_opencode_durations_and_calendar_months(self):
        self.configs["claude"] = [{"base-url": "https://opencode.ai/inference/go/anthropic",
                                    "keys": [{"api-key": "duration-fixture", "auth_index": "g1"}]}]
        usage = self.usage["opencode"]["usage"]
        for reset, days in [("2030-03-01T00:00:00Z", 28), ("2032-03-01T00:00:00Z", 29),
                            ("2030-05-01T00:00:00Z", 30), ("2030-02-01T00:00:00Z", 31),
                            ("2030-01-01T00:00:00Z", 31), ("2030-03-31T00:00:00Z", 31),
                            ("2030-03-01T01:00:00+01:00", 28)]:
            with self.subTest(reset=reset):
                usage["monthly"]["resetsAt"] = reset
                result = self.run_helper("opencode")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["windows"]["monthly"]["windowSeconds"], days * 86400)
        # Vendor durations and statuses take precedence over fallback names and values.
        for seconds, name in [(120, "120s"), (18000, "5h"), (604800, "7d"), (2592000, "monthly")]:
            with self.subTest(seconds=seconds):
                for window in usage.values():
                    window.update(windowSeconds=seconds, status="paused")
                result = self.run_helper("opencode")
                self.assertEqual(result.returncode, 0, result.stderr)
                windows = json.loads(result.stdout)["windows"]
                self.assertEqual(set(windows), {name})
                self.assertEqual(windows[name]["windowSeconds"], seconds)
                self.assertEqual(windows[name]["status"], "paused")

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
        executable.write_text(f"#!{sys.executable}\nprint('private-response-body')\n")
        result = self.run_helper("opencode", cpa=False, OPENCODE_API_KEY_FILE=str(self.key), PATH=path)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "opencode-usage: invalid OpenCode Go usage response\n")
        result = self.run_helper("opencode", cpa=False, PATH=path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("OPENCODE_API_KEY_FILE", result.stderr)
        result = subprocess.run([self.helpers["opencode"]], env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected route", result.stderr)

    def test_direct_transports_ignore_curlrc(self):
        # A user curlrc that turns on verbose and adds a local URL would print the
        # request headers; -q must keep curl from reading it. The refused proxy
        # keeps the real vendor URLs offline.
        (self.home / ".curlrc").write_text(f"verbose\nurl = \"{self.url}/curlrc-probe\"\n")
        (self.home / ".claude").mkdir()
        (self.home / ".claude/.credentials.json").write_text(json.dumps({"claudeAiOauth": {"accessToken": "direct-private-key"}}))
        self.key.write_text("direct-private-key")
        offline = {"https_proxy": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1", "CURL_HOME": str(self.home)}
        for vendor, extra in [("claude", {}), ("opencode", {"OPENCODE_API_KEY_FILE": str(self.key)}),
                              ("zai", {"ZAI_API_KEY_FILE": str(self.key)})]:
            with self.subTest(vendor=vendor):
                self.requests.clear()
                result = self.run_helper(vendor, cpa=False, **offline, **extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("direct-private-key", result.stdout + result.stderr)
                self.assertEqual(self.requests, [])

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

"""CI-only contract tests: a local CPA server records real management requests."""

from contextlib import redirect_stderr, redirect_stdout
import copy
import datetime as dt
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import threading
import unittest

SOURCE, EXECUTABLE = sys.argv[1:3]
reader = runpy.run_path(SOURCE)
ACCOUNT = "0123456789abcdef0123456789abcdef"
KEY = "management-secret-canary"
UPSTREAM_KEY = "upstream-secret-canary"
INDEX = "fixture-index"
QUERY = "query WorkersAINeurons($account:String!,$date:Date!){viewer{accounts(filter:{accountTag:$account}){accountTag aiInferenceAdaptiveGroups(limit:1,filter:{date_geq:$date,date_leq:$date}){sum{totalNeurons} count}}}}"
SURFACES = ("claude", "codex", "openai-compatibility", "passthrough")


def group(key=UPSTREAM_KEY, index=INDEX, base="https://api.cloudflare.com/client/v4"):
    return {"base-url": base, "keys": [{"api-key": key, "auth_index": index}], "name": "cloudflare"}


def analytics(neurons=25):
    return {"data": {"viewer": {"accounts": [{"accountTag": ACCOUNT, "aiInferenceAdaptiveGroups": [{"count": 1, "sum": {"totalNeurons": neurons}}]}]}}}


class Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"])
        cls.directory = Path(cls.temporary.name)
        cls.account_file = cls.directory / "account"
        cls.key_file = cls.directory / "management"
        cls.account_file.write_text(ACCOUNT + "\n")
        cls.key_file.write_text(KEY + "\n")
        owner = cls

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

            def respond(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                owner.requests.append((self.command, self.path, dict(self.headers), raw))
                status, payload = owner.responses.get(self.path, (500, {"errors": KEY}))
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                if status == 302:
                    self.send_header("Location", owner.url + "/redirect-target")
                self.end_headers()
                self.wfile.write(payload if isinstance(payload, bytes) else json.dumps(payload).encode())

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"
        cls.thread = threading.Thread(target=cls.server.serve_forever)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.temporary.cleanup()

    def setUp(self):
        self.env = {
            "CLOUDFLARE_ACCOUNT_ID_FILE": str(self.account_file),
            "CLOUDFLARE_DAILY_NEURONS_LIMIT": "100",
            "DELEGATE_USAGE_CPA_CLAUDE_MANAGEMENT_KEY_FILE": str(self.key_file),
            "DELEGATE_USAGE_CPA_CLAUDE_URL": self.url,
        }
        self.now = dt.datetime(2026, 11, 10, 23, 59, 59, tzinfo=dt.UTC)
        type(self).requests = []
        type(self).responses = {
            "/v8/management/config/api-keys/" + surface: (200, []) for surface in SURFACES
        }
        self.config("openai-compatibility", [group()])
        self.body(analytics())

    def config(self, surface, value, status=200):
        self.responses["/v8/management/config/api-keys/" + surface] = (status, value)

    def body(self, body, upstream=200, management=200):
        self.responses["/v0/management/api-call"] = (
            management, {"status_code": upstream, "body": json.dumps(body)}
        )

    def invoke(self, success=True, argv=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            result = reader["main"](
                ["claude"] if argv is None else argv, self.env, lambda: self.now
            )
        output, error = stdout.getvalue(), stderr.getvalue()
        for secret in (ACCOUNT, KEY, UPSTREAM_KEY):
            self.assertNotIn(secret, output + error)
        if success:
            self.assertEqual(result, 0, error)
            self.assertEqual(error, "")
            return json.loads(output)
        self.assertEqual(result, 1)
        self.assertEqual(output, "")
        self.assertTrue(error.startswith("cloudflare-usage: "))
        self.assertEqual(len(error.splitlines()), 1)

    def test_success_wire_and_schema(self):
        self.assertEqual(self.invoke(), {
            "account": {"auth_index": INDEX, "name": INDEX, "plan": None},
            "balances": [], "bonuses": [], "pool": "cloudflare",
            "windows": {"daily": {"remainingPercent": 75, "resetsAt": "2026-11-11T00:00:00Z", "status": None, "usedPercent": 25, "windowSeconds": 86400}},
        })
        self.assertEqual([(r[0], r[1]) for r in self.requests], [
            *(('GET', '/v8/management/config/api-keys/' + s) for s in SURFACES),
            ('POST', '/v0/management/api-call'),
        ])
        for method, path, headers, raw in self.requests:
            self.assertEqual(headers["Authorization"], "Bearer " + KEY)
            self.assertEqual(headers["Content-Type"], "application/json")
            if method == "GET":
                self.assertEqual(raw, b"")
        payload = json.loads(self.requests[-1][3])
        self.assertEqual(payload, {
            "auth_index": INDEX,
            "data": json.dumps({"query": QUERY, "variables": {"account": ACCOUNT, "date": "2026-11-10"}}),
            "header": {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json"},
            "method": "POST", "url": "https://api.cloudflare.com/client/v4/graphql",
        })

    def test_empty_groups_and_overage(self):
        body = analytics()
        body["data"]["viewer"]["accounts"][0]["aiInferenceAdaptiveGroups"] = []
        self.body(body)
        self.assertEqual(self.invoke()["windows"]["daily"]["usedPercent"], 0)
        self.body(analytics(150))
        self.assertEqual(self.invoke()["windows"]["daily"]["remainingPercent"], 0)
        self.assertEqual(self.invoke()["windows"]["daily"]["usedPercent"], 150)

    def test_utc_rollovers(self):
        for timestamp, date, reset in (
            ("2026-11-10T23:59:59+00:00", "2026-11-10", "2026-11-11T00:00:00Z"),
            ("2026-11-30T23:59:59+00:00", "2026-11-30", "2026-12-01T00:00:00Z"),
            ("2026-12-31T23:59:59+00:00", "2026-12-31", "2027-01-01T00:00:00Z"),
            ("2028-02-29T00:00:00+00:00", "2028-02-29", "2028-03-01T00:00:00Z"),
            ("2026-12-31T19:00:00-07:00", "2027-01-01", "2027-01-02T00:00:00Z"),
        ):
            with self.subTest(timestamp=timestamp):
                self.now = dt.datetime.fromisoformat(timestamp)
                self.assertEqual(self.invoke()["windows"]["daily"]["resetsAt"], reset)
                payload = json.loads(self.requests[-1][3])
                self.assertEqual(json.loads(payload["data"])["variables"]["date"], date)

    def test_bad_analytics(self):
        original = analytics()
        bad = [{}, None, {"data": None}, {"errors": [KEY]}, dict(original, errors=[KEY])]
        for accounts in (None, [], [{}, {}], [{}]):
            bad.append({"data": {"viewer": {"accounts": accounts}}})
        for field, value in (
            ("accountTag", "f" * 32),
            ("aiInferenceAdaptiveGroups", None),
            ("aiInferenceAdaptiveGroups", [{}, {}]),
            ("aiInferenceAdaptiveGroups", [{}]),
        ):
            body = copy.deepcopy(original)
            body["data"]["viewer"]["accounts"][0][field] = value
            bad.append(body)
        for value in (-1, None, True, "1", float("nan"), float("inf"), -float("inf")):
            bad.append(analytics(value))
        missing_groups = copy.deepcopy(original)
        del missing_groups["data"]["viewer"]["accounts"][0]["aiInferenceAdaptiveGroups"]
        bad.append(missing_groups)
        for body in bad:
            with self.subTest(body=body):
                self.body(body)
                self.invoke(False)

    def test_discovery_all_families_and_duplicates(self):
        for surface in SURFACES:
            with self.subTest(surface=surface):
                for item in SURFACES:
                    self.config(item, [])
                self.config(surface, [group()])
                self.invoke()
        self.config("claude", [group(index="other-index")])
        self.config("openai-compatibility", [group()])
        self.invoke()  # Same credential in several groups is one candidate.

    def test_discovery_unrelated_provider_with_spaces(self):
        unrelated = dict(group(base="https://other.example"), name="Other Provider")
        for surface in ("openai-compatibility", "passthrough"):
            with self.subTest(surface=surface):
                self.config(surface, [group(), unrelated])
                self.assertEqual(self.invoke()["account"]["auth_index"], INDEX)
                self.config(surface, [])

    def test_discovery_matching(self):
        for base in ("https://api.cloudflare.com", "https://api.cloudflare.com/client/v4/", "https://api.cloudflare.com/client/v4/accounts/path"):
            self.config("openai-compatibility", [group(base=base)])
            self.invoke()
        for base in ("http://api.cloudflare.com", "https://api.cloudflare.com.evil/client/v4", "https://evil/api.cloudflare.com/client/v4", "https://api.cloudflare.com/client/v40", "https://api.cloudflare.com/other", "https://user@api.cloudflare.com", "https://api.cloudflare.com:444", "https://api.cloudflare.com?key=secret"):
            with self.subTest(base=base):
                self.config("openai-compatibility", [group(base=base)])
                self.invoke(False)
        for groups in ([], {}, None, [None], [group(key="")], [group(index="")], [group(index=None)], [group(), group(key="another-secret")], [{"name": "cloudflare", "base-url": "https://api.cloudflare.com"}]):
            with self.subTest(groups=groups):
                self.config("openai-compatibility", groups)
                self.invoke(False)
        malformed = group()
        del malformed["name"]
        self.config("openai-compatibility", [malformed])
        self.invoke(False)

    def test_discovery_http_and_override(self):
        self.config("passthrough", {"errors": KEY}, 404)
        self.invoke()
        for surface in SURFACES:
            for status in (401, 403, 429, 500):
                self.config(surface, {"errors": KEY}, status)
                self.invoke(False)
                self.config(surface, [] if surface != "openai-compatibility" else [group()])
        self.config("claude", {"errors": KEY}, 404)
        self.invoke(False)
        self.env["CLOUDFLARE_AUTH_INDEX"] = INDEX
        self.requests.clear()
        self.invoke()
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.requests[0][0], "POST")

    def test_management_redirect_not_followed(self):
        # The target answers like a healthy api-call, so a reader that follows
        # the redirect (and forwards the management key) would succeed here.
        self.responses["/redirect-target"] = self.responses["/v0/management/api-call"]
        self.responses["/v0/management/api-call"] = (302, {})
        self.invoke(False)
        self.assertNotIn("/redirect-target", [r[1] for r in self.requests])

    def test_transport_envelope_failures(self):
        for status in (302, 400, 401, 429, 500):
            self.body({"errors": KEY}, management=status)
            self.invoke(False)
            self.body({"errors": UPSTREAM_KEY}, upstream=status)
            self.invoke(False)
        for envelope in (None, {}, {"status_code": "200", "body": "{}"}, {"status_code": 200, "body": {}}, {"status_code": 200, "body": KEY}, b"not-json"):
            self.responses["/v0/management/api-call"] = (200, envelope)
            self.invoke(False)
        self.config("claude", b"not-json")
        self.invoke(False)

    def test_runtime_inputs(self):
        baseline = self.env.copy()
        for argv in ([], ["other"], ["claude", "extra"], [KEY]):
            self.invoke(False, argv)
        for field, values in {
            "CLOUDFLARE_ACCOUNT_ID_FILE": ("", str(self.directory), str(self.directory / "missing")),
            "CLOUDFLARE_AUTH_INDEX": ("", "\n" + KEY),
            "CLOUDFLARE_DAILY_NEURONS_LIMIT": ("", "0", "-1", "nan", "inf", "1e999", "1e-999", KEY),
            "DELEGATE_USAGE_CPA_CLAUDE_MANAGEMENT_KEY_FILE": ("", str(self.directory / "missing"), str(self.directory)),
            "DELEGATE_USAGE_CPA_CLAUDE_URL": ("", KEY, "http://user:secret@localhost", "http://localhost#secret", "http://localhost:bad", "http://localhost/\n" + KEY),
        }.items():
            for value in values:
                self.env = dict(baseline, **{field: value})
                self.invoke(False)
        self.env = {k: v for k, v in baseline.items() if not k.startswith("DELEGATE_")}
        self.invoke(False)
        self.env = dict(baseline)
        self.invoke(False, ["codex"])
        self.env.update({k.replace("CLAUDE", "CODEX"): v for k, v in baseline.items() if k.startswith("DELEGATE_")})
        self.invoke(True, ["codex"])
        for path, bad in ((self.account_file, "bad/account"), (self.key_file, KEY + "\nsecond-line")):
            original = path.read_text()
            try:
                path.write_text(bad)
                self.invoke(False)
            finally:
                path.write_text(original)

    def test_packaged_executable(self):
        # Run the public wrapper too: import-only tests cannot catch a bad entrypoint.
        env = dict(self.env, CLOUDFLARE_AUTH_INDEX=INDEX)
        result = subprocess.run([EXECUTABLE, "claude"], env=env, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["pool"], "cloudflare")
        self.assertEqual(result.stderr, "")
        for secret in (ACCOUNT, KEY, UPSTREAM_KEY):
            self.assertNotIn(secret, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)

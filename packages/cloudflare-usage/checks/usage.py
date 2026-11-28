"""Cloudflare contracts on the shared CPA fixture, using the public executable."""

from datetime import date, datetime, timedelta, timezone
import json
from pathlib import Path
import runpy
import shutil
import sys
import unittest

HARNESS, SCRIPTS, EXECUTABLE, SOURCE = sys.argv[1:5]
sys.argv = [sys.argv[0], SCRIPTS]
shared = runpy.run_path(HARNESS)
ACCOUNT = "0123456789abcdef0123456789abcdef"
API_CALL = "/v0/management/api-call"
SECOND_KEY = "second-private-key"
UNRELATED_KEY = "unrelated-private-key"
UPSTREAM_KEY = "upstream-private-key"
# Wire expectation for CPA, not evidence of acceptance by the live endpoint.
QUERY = (
    "query WorkersAINeurons($account:String!,$date:Date!){viewer{"
    "accounts(filter:{accountTag:$account}){accountTag "
    "aiInferenceAdaptiveGroups(limit:1,filter:{date_geq:$date,date_leq:$date})"
    "{sum{totalNeurons} count}}}}"
)


def analytics(*, account=ACCOUNT, neurons=25, errors=None):
    groups = [] if neurons is None else [{"sum": {"totalNeurons": neurons}}]
    body = {"data": {"viewer": {"accounts": [
        {"accountTag": account, "aiInferenceAdaptiveGroups": groups},
    ]}}}
    if errors is not None:
        body["errors"] = errors
    return body


class CloudflareTests(shared["UsageTests"]):
    def setUp(self):
        super().setUp()
        self.helpers["cloudflare"] = EXECUTABLE
        account_file = self.home / "account"
        account_file.write_text(ACCOUNT + "\n")
        self.env = {k: v for k, v in self.env.items() if not k.startswith("CLOUDFLARE_")}
        self.env.update(CLOUDFLARE_ACCOUNT_ID_FILE=str(account_file), CLOUDFLARE_DAILY_NEURONS_LIMIT="200")
        self.group = {"name": "cloudflare", "base-url": f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/ai/run/model",
                      "keys": [{"api-key": UPSTREAM_KEY, "auth_index": "cf-one"}]}
        self.configs = {"passthrough": [self.group], "openai-compatibility": [
            {"name": "jev", "base-url": "https://jev.example.test/v1",
             "keys": [{"api-key": UNRELATED_KEY, "auth_index": "jev-one"}]}]}
        self.usage["cloudflare"] = analytics()

    def cloudflare(self, **env):
        result = self.run_helper("cloudflare", **env)
        for secret in [ACCOUNT, SECOND_KEY, UNRELATED_KEY, UPSTREAM_KEY]:
            self.assertNotIn(secret, result.stdout + result.stderr)
        return result

    def assert_rejected(self, expected, **env):
        result = self.cloudflare(**env)
        self.assertEqual(result.stdout, "")
        self.assertIn(expected, result.stderr)

    def test_cloudflare_daily_query_and_window_bypass_ambient_proxy(self):
        before = datetime.now(timezone.utc).date()
        result = self.cloudflare(HTTP_PROXY="http://127.0.0.1:1", http_proxy="http://127.0.0.1:1", NO_PROXY="", no_proxy="")
        self.assertEqual(result.returncode, 0, result.stderr)
        # The unrelated Jev credential must not make the passthrough selection ambiguous.
        posts = [entry for entry in self.requests if entry[0] == "POST"]
        self.assertEqual([entry[1] for entry in posts], [API_CALL])
        request = posts[0][3]
        self.assertEqual(request["auth_index"], "cf-one")
        self.assertEqual(request["method"], "POST")
        self.assertEqual(request["url"], "https://api.cloudflare.com/client/v4/graphql")
        self.assertEqual(request["header"], {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json"})
        data = json.loads(request["data"])
        self.assertEqual(data["query"], QUERY)
        day = date.fromisoformat(data["variables"]["date"])
        self.assertIn(day, [before, datetime.now(timezone.utc).date()])
        self.assertEqual(data["variables"], {"account": ACCOUNT, "date": day.isoformat()})
        usage = json.loads(result.stdout)
        self.assertEqual(usage["account"], {"auth_index": "cf-one", "name": "cf-one", "plan": None})
        self.assertEqual(usage["balances"], [])
        self.assertEqual(usage["bonuses"], [])
        self.assertEqual(set(usage["windows"]), {"daily"})
        window = usage["windows"]["daily"]
        # 25 neurons on a limit of 200 catches treating the raw count as a percentage.
        self.assertEqual(window["usedPercent"], 12.5)
        self.assertEqual(window["windowSeconds"], 86400)
        self.assertIsNone(window["status"])
        self.assertEqual(window["resetsAt"], f"{day + timedelta(days=1):%Y-%m-%d}T00:00:00Z")
        # Passthrough discovery uses a Cloudflare-only management GET.
        for method, _, headers, _ in self.requests:
            if method == "GET":
                self.assertEqual(headers["Authorization"], "Bearer " + shared["SECRET"])

    def test_cloudflare_discovery_rejects_distinct_passthrough_keys(self):
        other = dict(self.group, keys=[{"api-key": SECOND_KEY, "auth_index": "cf-two"}])
        self.configs["passthrough"].append(other)
        self.assert_rejected("cloudflare requires exactly one distinct key with an auth index on api.cloudflare.com/client/v4")
        self.assertNotIn(API_CALL, [r[1] for r in self.requests])

    def test_cloudflare_pinned_codex_route_skips_discovery(self):
        self.configs["passthrough"] = []
        result = self.cloudflare(route="codex", CLOUDFLARE_AUTH_INDEX="cf-override")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r[1] for r in self.requests], [API_CALL])
        self.assertEqual(self.requests[0][3]["auth_index"], "cf-override")

    def test_cloudflare_empty_groups_report_zero_usage(self):
        self.usage["cloudflare"] = analytics(neurons=None)
        result = self.cloudflare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["windows"]["daily"]["usedPercent"], 0)

    def test_cloudflare_rejects_invalid_analytics(self):
        for regression, inputs in [
            ("accept data from a different account", {"account": "different-account"}),
            ("accept negative neurons", {"neurons": -1}),
            ("accept partial data with GraphQL errors", {"errors": [{"message": UPSTREAM_KEY}]}),
        ]:
            with self.subTest(regression=regression):
                self.usage["cloudflare"] = analytics(**inputs)
                self.assert_rejected("invalid vendor usage response")

    def test_cloudflare_refuses_redirect_without_following_it(self):
        self.management_redirect = self.url + "/redirect-target"
        self.assert_rejected("management HTTP 302", CLOUDFLARE_AUTH_INDEX="cf-override")
        self.assertEqual([r[1] for r in self.requests], [API_CALL])

    def test_cloudflare_treats_discovery_401_as_error_not_empty_collection(self):
        self.configs["claude"] = []
        self.management_status = 401
        self.assert_rejected("management HTTP 401")
        self.assertEqual([r[1] for r in self.requests], ["/v8/management/config/api-keys/claude"])

    def test_cloudflare_rejects_non_json_graphql_body_after_http_success(self):
        self.envelope = {"status_code": 200, "body": UPSTREAM_KEY}
        self.assert_rejected("invalid vendor usage response", CLOUDFLARE_AUTH_INDEX="cf-override")

    def test_cloudflare_no_secrets_in_argv(self):
        binary = self.home / "bin"
        binary.mkdir()
        tools = ["curl", "jq", "python3"]
        calls = self.home / "probed-tools"
        for tool in tools:
            real = shutil.which(tool)
            executable = binary / tool
            executable.write_text(f"#!{sys.executable}\n" + f'''import os, sys
assert all({ACCOUNT!r} not in arg for arg in sys.argv), "account ID in arguments"
for secret in {[ACCOUNT, UPSTREAM_KEY, shared["SECRET"]]!r}:
    assert all(secret not in value for value in os.environ.values()), "secret in environment"
with open({str(calls)!r}, "a") as calls:
    print({tool!r}, file=calls)
os.execv({real!r}, [{real!r}] + sys.argv[1:])
''')
            executable.chmod(0o755)
        # Packaged writeShellApplication prepends its inputs to PATH. A composed
        # source helper lets the same transport run through the argv probes.
        helper = self.home / "cloudflare-source"
        source = Path(SOURCE)
        helper.write_text(f"#!{shutil.which('bash')}\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n"
                          + (Path(SCRIPTS) / "usage-cpa.sh").read_text() + "\n" + source.read_text())
        helper.chmod(0o755)
        self.helpers["cloudflare"] = str(helper)
        result = self.cloudflare(PATH=str(binary) + ":" + self.env["PATH"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(calls.read_text().splitlines()), set(tools))


if __name__ == "__main__":
    suite = unittest.TestSuite(CloudflareTests(name) for name in dir(CloudflareTests) if name.startswith("test_cloudflare_"))
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())

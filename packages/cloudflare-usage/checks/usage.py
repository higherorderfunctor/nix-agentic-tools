"""Cloudflare contracts on the shared CPA fixture, using the public executable."""

import copy
from datetime import datetime, timezone
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
UPSTREAM_KEY = "upstream-private-key"
QUERY = "query WorkersAINeurons($account:String!,$date:Date!){viewer{accounts(filter:{accountTag:$account}){accountTag aiInferenceAdaptiveGroups(limit:1,filter:{date_geq:$date,date_leq:$date}){sum{totalNeurons} count}}}}"


class CloudflareTests(shared["UsageTests"]):
    def setUp(self):
        super().setUp()
        self.helpers["cloudflare"] = EXECUTABLE
        account_file = self.home / "account"
        account_file.write_text(ACCOUNT + "\n")
        self.env = {k: v for k, v in self.env.items() if not k.startswith("CLOUDFLARE_")}
        self.env.update(CLOUDFLARE_ACCOUNT_ID_FILE=str(account_file), CLOUDFLARE_DAILY_NEURONS_LIMIT="100")
        self.group = {"name": "cloudflare", "base-url": f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/ai/run/model",
                      "keys": [{"api-key": UPSTREAM_KEY, "auth_index": "cf-one"}]}
        self.configs = {"passthrough": [self.group], "openai-compatibility": [
            {"name": "jev", "base-url": "https://jev.example.test/v1",
             "keys": [{"api-key": "jev-private-key", "auth_index": "jev-one"}]}]}
        self.usage["cloudflare"] = {"data": {"viewer": {"accounts": [
            {"accountTag": ACCOUNT, "aiInferenceAdaptiveGroups": [{"sum": {"totalNeurons": 25}}]}]}}}

    def cloudflare(self, **env):
        result = self.run_helper("cloudflare", **env)
        for secret in [ACCOUNT, UPSTREAM_KEY, "jev-private-key"]:
            self.assertNotIn(secret, result.stdout + result.stderr)
        return result

    def test_cloudflare_success(self):
        before = datetime.now(timezone.utc).date()
        result = self.cloudflare(HTTP_PROXY="http://127.0.0.1:1", http_proxy="http://127.0.0.1:1", NO_PROXY="", no_proxy="")
        self.assertEqual(result.returncode, 0, result.stderr)
        request = self.requests[-1][3]
        self.assertEqual(request["auth_index"], "cf-one")
        self.assertEqual(request["method"], "POST")
        self.assertEqual(request["url"], "https://api.cloudflare.com/client/v4/graphql")
        self.assertEqual(request["header"]["Authorization"], "Bearer $TOKEN$")
        data = json.loads(request["data"])
        self.assertEqual(data["query"], QUERY)
        self.assertEqual(data["variables"]["account"], ACCOUNT)
        self.assertIn(data["variables"]["date"], [before.isoformat(), datetime.now(timezone.utc).date().isoformat()])
        window = json.loads(result.stdout)["windows"]["daily"]
        self.assertEqual(window["usedPercent"], 25)
        self.assertEqual(window["remainingPercent"], 75)
        reset = datetime.fromisoformat(window["resetsAt"].replace("Z", "+00:00"))
        self.assertEqual(reset.timestamp(), datetime.fromisoformat(data["variables"]["date"]).replace(tzinfo=timezone.utc).timestamp() + 86400)
        for _, _, headers, _ in self.requests:
            self.assertEqual(headers["Authorization"], "Bearer " + shared["SECRET"])

    def test_cloudflare_discovery_boundary(self):
        other = copy.deepcopy(self.group)
        other["keys"][0]["api-key"] = "second-private-key"
        self.configs["passthrough"].append(other)
        self.assertNotEqual(self.cloudflare().returncode, 0)
        self.configs["passthrough"] = []
        self.assertNotEqual(self.cloudflare().returncode, 0)
        self.requests.clear()
        result = self.cloudflare(route="codex", CLOUDFLARE_AUTH_INDEX="cf-override")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r[1] for r in self.requests], ["/v0/management/api-call"])
        self.assertEqual(self.requests[0][3]["auth_index"], "cf-override")

    def test_cloudflare_empty_and_errors(self):
        account = self.usage["cloudflare"]["data"]["viewer"]["accounts"][0]
        account["aiInferenceAdaptiveGroups"] = []
        self.assertEqual(json.loads(self.cloudflare().stdout)["windows"]["daily"]["usedPercent"], 0)
        account["accountTag"] = "different-account"
        self.assertNotEqual(self.cloudflare().returncode, 0)
        account["accountTag"] = ACCOUNT
        self.usage["cloudflare"]["errors"] = [{"message": UPSTREAM_KEY}]
        self.assertNotEqual(self.cloudflare().returncode, 0)

    def test_cloudflare_redirect_and_http_failure(self):
        self.management_redirect = self.url + "/redirect-target"
        self.assertNotEqual(self.cloudflare().returncode, 0)
        self.assertEqual(len(self.requests), 1)
        self.management_redirect = None
        self.management_status = 401
        self.assertNotEqual(self.cloudflare().returncode, 0)
        self.management_status = 200
        self.envelope = {"status_code": 503, "body": UPSTREAM_KEY}
        self.assertNotEqual(self.cloudflare().returncode, 0)
        self.envelope = {"status_code": 200, "body": "invalid-json"}
        self.assertNotEqual(self.cloudflare().returncode, 0)

    def test_cloudflare_no_secrets_in_argv(self):
        binary = self.home / "bin"
        binary.mkdir()
        for tool in ["curl", "jq", "python3"]:
            executable = binary / tool
            executable.write_text(f"#!{sys.executable}\n" + f'''import os, sys
for secret in {[ACCOUNT, UPSTREAM_KEY, shared["SECRET"]]!r}:
    assert secret not in " ".join(sys.argv)
    assert secret not in os.environ.values()
os.execv({shutil.which(tool)!r}, [{shutil.which(tool)!r}] + sys.argv[1:])
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


if __name__ == "__main__":
    suite = unittest.TestSuite(CloudflareTests(name) for name in dir(CloudflareTests) if name.startswith("test_cloudflare_"))
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())

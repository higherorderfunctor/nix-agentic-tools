# pyright: strict
# cspell:ignore replys
"""Exercise the suite's comparisons with a working Reader and one deliberate fault at a time."""

from collections.abc import Callable, Iterable, Mapping, Sequence
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime
from io import StringIO
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from pydantic import ValidationError

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from credential_usage.transport import DirectHttp, HttpRequest, HttpResponse
from run import main as run_cases
from standalone import installed_differences, main as run_installed
from suite import Case, IncompletePair, Pair, differences


DIRECTORY = HERE / "synthetic" / "cases"
SYNTHETIC = Pair.read(DIRECTORY)
ENTRY = "synthetic.cli:main"
PRIVATE_BODY = '{"training-only-account":9123,"note":"private account detail"}'
MASKED_BODY = '+      "[private]": "[private]",\n+      "[private]": "[private]"\n'
NOTE_ONLY = {"note": "public note"}
ECHO = {
    "method": "POST", "url": "https://reader.example/echo",
    "headers": {"Accept": "application/json", "Authorization": "Bearer [credential:login]"},
}

BROKEN_RESULT = """unreadable-credential/direct: result
--- expected
+++ observed
@@ -1,3 +1,3 @@
 {
-  "failed": "usage: deliberately wrong"
+  "failed": "usage: observation unavailable"
 }
"""

WRONG_PLAN = """success/direct: result
--- expected
+++ observed
@@ -1,42 +1,42 @@
 {
   "account": {
     "auth_index": null,
     "name": null,
-    "plan": "standard"
+    "plan": "wrong plan"
   },
   "accountedSpend": null,
   "balances": [],
   "binding": {
     "endpoint": "https://reader.example/",
     "transport": "direct"
   },
   "bonuses": [],
   "observedAt": "2026-11-01T00:00:02Z",
   "pool": "sample",
   "schemaVersion": 1,
   "slotStates": {
     "accountedSpend": {
       "state": "unsupported"
     },
     "credits": {
       "state": "observed"
     },
     "grants": {
       "state": "unsupported"
     },
     "resetInventory": {
       "state": "unsupported"
     }
   },
   "windows": {
     "1h": {
       "enforced": true,
       "remainingPercent": 77,
       "resetsAt": null,
       "state": "observed",
       "status": null,
       "usedPercent": 23,
       "windowSeconds": 3600
     }
   }
 }
"""

DROPPED_HEADER = """success/direct: trace
--- expected
+++ observed
@@ -1,19 +1,18 @@
 [
   {
     "body": null,
     "headers": {
-      "Accept": "application/json",
       "Authorization": "Bearer [credential:login]"
     },
     "method": "GET",
     "url": "https://reader.example/allowance"
   },
   {
     "body": null,
     "headers": {
       "Authorization": "Bearer [credential:login]"
     },
     "method": "GET",
     "url": "https://reader.example/credits"
   }
 ]
"""

EMPTY_WINDOWS = """success/direct: result
--- expected
+++ observed
@@ -1,42 +1,32 @@
 {
   "account": {
     "auth_index": null,
     "name": null,
     "plan": "standard"
   },
   "accountedSpend": null,
   "balances": [],
   "binding": {
     "endpoint": "https://reader.example/",
     "transport": "direct"
   },
   "bonuses": [],
   "observedAt": "2026-11-01T00:00:02Z",
   "pool": "sample",
   "schemaVersion": 1,
   "slotStates": {
     "accountedSpend": {
       "state": "unsupported"
     },
     "credits": {
       "state": "observed"
     },
     "grants": {
       "state": "unsupported"
     },
     "resetInventory": {
       "state": "unsupported"
     }
   },
-  "windows": {
-    "1h": {
-      "enforced": true,
-      "remainingPercent": 77,
-      "resetsAt": null,
-      "state": "observed",
-      "status": null,
-      "usedPercent": 23,
-      "windowSeconds": 3600
-    }
-  }
+  "windows": {}
 }
"""



def write_pair(directory: Path, data: object) -> None:
    """Write the synthetic pair into the directory, with `data` as its input document."""
    (directory / "input.json").write_text(json.dumps(data))
    (directory / "expected.json").write_bytes((DIRECTORY / "expected.json").read_bytes())


def failed_labels(pair: Pair, case: Case, entry: str) -> list[str]:
    """Return what each failed comparison is named, without the objects printed after it."""
    return [difference.label for difference in differences(pair.inputs, case, entry)]


class GoldenCases(unittest.TestCase):
    """Each scenario and transport gets a separate test ID so a mutation kill identifies its case."""


def golden_test(pair: Pair, case: Case, entry: str) -> Callable[[GoldenCases], None]:
    """Bind the case before discovery so unittest and pytest collect the same tests."""
    def test_reader_matches_expected_requests_and_result(self: GoldenCases) -> None:
        """69, 71–72. Comparing only the last request or one result field can hide an incorrect Reader."""
        failures = differences(pair.inputs, case, entry)
        if failures:
            self.fail("\n".join(map(str, failures)))
    return test_reader_matches_expected_requests_and_result


def collect_golden_cases() -> None:
    """Use the owner's selected pair and entry, or the synthetic pair during the suite's own check."""
    directory = os.environ.get("READER_PAIR")
    if directory is None:
        pair, entry = SYNTHETIC, ENTRY
    else:
        pair, entry = Pair.read(Path(directory)), os.environ["READER_ENTRY"]
    for name, case in pair.cases.items():
        setattr(GoldenCases, f"test_reader_matches_expected_requests_and_result__{name.replace('/', '__')}", golden_test(pair, case, entry))


collect_golden_cases()


class SuiteTests(unittest.TestCase):
    """The suite must reject incorrect Readers and malformed fixture pairs."""

    def test_suite_rejects_each_broken_decision_naming_the_case(self) -> None:
        """71–72. Fail the named comparison for a dropped header, wrong field, missing or extra request."""
        from synthetic import cli

        case = SYNTHETIC.cases["success/direct"]
        real_request = DirectHttp.request

        def dropped_header(client: DirectHttp, request: HttpRequest) -> HttpResponse:
            return real_request(client, request.model_copy(update={"headers": {}}))

        def short_sequence(client: DirectHttp, request: HttpRequest) -> HttpResponse:
            if request.url.path == "/credits":
                return HttpResponse(status_code=200, body="[]")
            return real_request(client, request)

        def extra_request(client: DirectHttp, request: HttpRequest) -> HttpResponse:
            result = real_request(client, request)
            if request.url.path == "/credits":
                real_request(client, request)
            return result

        for fault, labels in (
            (patch.object(DirectHttp, "request", dropped_header), ["trace"]),
            (patch.object(cli.subprocess, "check_output", return_value="wrong plan"), ["result"]),
            (patch.object(DirectHttp, "request", short_sequence), ["missing request", "trace", "result"]),
            (patch.object(DirectHttp, "request", extra_request), ["extra request", "trace", "result"]),
        ):
            with self.subTest(labels=labels), fault:
                self.assertEqual(failed_labels(SYNTHETIC, case, ENTRY), [f"success/direct: {label}" for label in labels])

        def print_offset(document: str) -> None:
            print(document.replace("2026-11-01T00:00:02Z", "2026-11-01T01:00:02+01:00"))

        with self.subTest(fault="offset instant"), patch.object(cli, "print", print_offset, create=True):
            self.assertEqual(failed_labels(SYNTHETIC, case, ENTRY), ["success/direct: result"])

        with TemporaryDirectory() as tmp, patch.object(sys, "path", [tmp, *sys.path]):
            for stream in ("stdout", "stderr"):
                module = f"reader_writes_{stream}"
                (Path(tmp) / f"{module}.py").write_text(
                    f"import sys\nfrom synthetic.cli import main\nprint('loading', file=sys.{stream})\n"
                )
                out, err = StringIO(), StringIO()
                with self.subTest(stream=stream), redirect_stdout(out), redirect_stderr(err):
                    status = run_cases([str(DIRECTORY), f"{module}:main", "success/direct"])
                    self.assertEqual(status, 1)
                    self.assertEqual(out.getvalue(), "")
                    self.assertIn("success/direct: import output", err.getvalue())
                    self.assertNotIn("loading", err.getvalue())

            for module, source, extra_labels in (
                ("noisy_import_exit", "print('loading')\nraise SystemExit(0)", ["import output"]),
                ("silent_import_exit", "raise SystemExit(0)", []),
                ("reader_exit", "import sys\nfrom pathlib import Path\ndef main(env, clock):\n"
                 "    print(Path(env['CREDENTIAL_FILE']).read_text())\n    sys.exit(0)", ["leak"]),
            ):
                (Path(tmp) / f"{module}.py").write_text(source)
                entry = f"{module}:main"
                expected = [f"{case.name}: {label}" for label in (*extra_labels, "missing request", "trace", "result")]
                with self.subTest(module=module, caller="differences"):
                    self.assertEqual(failed_labels(SYNTHETIC, case, entry), expected)
                out, err = StringIO(), StringIO()
                with self.subTest(module=module, caller="run"), redirect_stdout(out), redirect_stderr(err):
                    self.assertEqual(run_cases([str(DIRECTORY), entry, case.name]), 1)
                    self.assertEqual(out.getvalue(), "")
                    self.assertEqual([line for line in err.getvalue().splitlines() if line.startswith(f"{case.name}: ")], expected)

    def test_failure_prints_the_case_and_the_whole_objects(self) -> None:
        """71–72, 74. A label alone, or a diff of one field, leaves a reader to find where a Reader differs."""
        with TemporaryDirectory() as tmp:
            broken = Path(tmp)
            expected = json.loads((DIRECTORY / "expected.json").read_bytes())
            expected["unreadable-credential"]["direct"] = {"result": {"failed": "usage: deliberately wrong"}}
            (broken / "input.json").write_bytes((DIRECTORY / "input.json").read_bytes())
            (broken / "expected.json").write_text(json.dumps(expected))
            out, err = StringIO(), StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                status = run_cases([str(broken), ENTRY, "unreadable-credential/direct"])
            self.assertEqual(status, 1)
            self.assertEqual(out.getvalue(), "")
            self.assertEqual(err.getvalue(), BROKEN_RESULT)

        from synthetic import cli

        case = SYNTHETIC.cases["success/direct"]
        real_request = DirectHttp.request

        def dropped_header(client: DirectHttp, request: HttpRequest) -> HttpResponse:
            return real_request(client, request.model_copy(update={"headers": {}}))

        def empty_windows(document: str) -> None:
            print(json.dumps(json.loads(document) | {"windows": {}}))

        for fault, report in (
            (patch.object(cli.subprocess, "check_output", return_value="wrong plan"), WRONG_PLAN),
            (patch.object(DirectHttp, "request", dropped_header), DROPPED_HEADER),
            (patch.object(cli, "print", empty_windows, create=True), EMPTY_WINDOWS),
        ):
            out, err = StringIO(), StringIO()
            with self.subTest(report=report.splitlines()[0]), fault, redirect_stdout(out), redirect_stderr(err):
                self.assertEqual(run_cases([str(DIRECTORY), ENTRY, case.name]), 1)
                self.assertEqual(out.getvalue(), "")
                self.assertEqual(err.getvalue(), report)

    def test_pair_builds_each_case_from_its_full_case(self) -> None:
        """69, 71–72. Merging arrays by position, or keeping a full case's requests when a case lists none, hides a wrong Reader."""
        optional = SYNTHETIC.cases["optional-failure/cpa"]
        self.assertEqual(
            optional.scenario.model_dump(),
            {"env": {"CREDENTIAL_FILE": "${credentials:login}", "TRANSPORT": "cpa"}, "replies": ["proxy-allowance", "proxy-failed"], "credentials": {}},
        )
        self.assertEqual(
            [(request.method, request.url, request.body) for request in optional.expected.requests],
            [
                ("POST", "https://proxy.example/v0/management/api-call", {
                    "method": "GET", "url": "https://reader.example/allowance", "auth_index": "sample",
                    "header": {"Accept": "application/json", "Authorization": "Bearer $TOKEN$"},
                }),
                ("POST", "https://proxy.example/v0/management/api-call", {
                    "method": "GET", "url": "https://reader.example/credits", "auth_index": "sample",
                    "header": {"Authorization": "Bearer $TOKEN$"},
                }),
            ],
        )
        self.assertEqual(optional.expected.result["slotStates"], {
            "accountedSpend": {"state": "unsupported"},
            "credits": {"state": "unknown", "reason": "prepaid-unavailable"},
            "grants": {"state": "unsupported"},
            "resetInventory": {"state": "unsupported"},
        })
        unreadable = SYNTHETIC.cases["unreadable-credential/direct"]
        self.assertEqual(unreadable.scenario.model_dump(), {
            "env": {"CREDENTIAL_FILE": "${credentials:login}.missing", "TRANSPORT": "direct"}, "replies": [], "credentials": {},
        })
        self.assertEqual(unreadable.expected.model_dump(), {"requests": [], "result": {"failed": "usage: observation unavailable"}})

    def test_pair_refuses_the_shapes_it_has_no_path_for(self) -> None:
        """69, 73. A full case in the old shape, a chain, two different parents and a misspelled or mistyped difference
        must not load: a case built two ways cannot back a recorded kill."""
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for name, change, message in (
                ("unreadable-credential", {"extends": "optional-failure"}, "extends optional-failure, which is not a full case"),
                ("unreadable-credential", {"extends": "absent"}, "extends absent, which is not a full case"),
                ("optional-failure", {"replys": ["allowance"]}, "optional-failure/cpa: replys: Extra inputs are not permitted"),
                ("optional-failure", {"direct": {"replies": "allowance"}}, "optional-failure/direct: replies: Input should be a valid list"),
            ):
                data = json.loads((DIRECTORY / "input.json").read_bytes())
                data["scenarios"][name] |= change
                hoped = json.loads((DIRECTORY / "expected.json").read_bytes())
                if "extends" in change:
                    hoped[name]["extends"] = change["extends"]
                (directory / "input.json").write_text(json.dumps(data))
                (directory / "expected.json").write_text(json.dumps(hoped))
                with self.subTest(change=change), self.assertRaisesRegex(IncompletePair, message):
                    Pair.read(directory)

            data = json.loads((DIRECTORY / "input.json").read_bytes())
            del data["scenarios"]["success"]["extends"]
            (directory / "input.json").write_text(json.dumps(data))
            (directory / "expected.json").write_bytes((DIRECTORY / "expected.json").read_bytes())
            with self.subTest(shape="a full case without extends"), self.assertRaises(ValidationError):
                Pair.read(directory)

            (directory / "input.json").write_bytes((DIRECTORY / "input.json").read_bytes())
            hoped = json.loads((DIRECTORY / "expected.json").read_bytes())
            hoped["unreadable-credential"]["extends"] = "success"
            (directory / "expected.json").write_text(json.dumps(hoped))
            with self.subTest(shape="two different parents"), self.assertRaisesRegex(IncompletePair, "extends differs"):
                Pair.read(directory)

    def test_a_full_case_written_once_builds_both_transports(self) -> None:
        """69, 71–72. Dropping a field written once, or letting it replace a transport's own field, changes what a Reader is sent."""
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            data = json.loads((DIRECTORY / "input.json").read_bytes())
            data["scenarios"]["primary-failure"] = {
                "extends": None,
                "env": {"CREDENTIAL_FILE": "${credentials:login}"},
                "replies": ["failed"],
                "direct": {"env": {"TRANSPORT": "direct"}},
                "cpa": {"env": {"TRANSPORT": "cpa"}, "replies": ["proxy-failed"]},
            }
            hoped = json.loads((DIRECTORY / "expected.json").read_bytes())
            hoped["primary-failure"] = {
                "extends": None,
                "result": {"failed": "usage: observation unavailable"},
                "direct": {"requests": [{
                    "method": "GET", "url": "https://reader.example/allowance",
                    "headers": {"Accept": "application/json", "Authorization": "Bearer [credential:login]"}, "body": None,
                }]},
                "cpa": {"requests": [{
                    "method": "POST", "url": "https://proxy.example/v0/management/api-call",
                    "headers": {"Content-Type": "application/json", "Authorization": "Bearer [credential:login]"},
                    "body": {"method": "GET", "url": "https://reader.example/allowance", "auth_index": "sample",
                             "header": {"Accept": "application/json", "Authorization": "Bearer $TOKEN$"}},
                }]},
            }
            (directory / "input.json").write_text(json.dumps(data))
            (directory / "expected.json").write_text(json.dumps(hoped))
            built = Pair.read(directory).cases
            for transport, replies, call in (
                ("direct", ["failed"], "GET https://reader.example/allowance"),
                ("cpa", ["proxy-failed"], "POST https://proxy.example/v0/management/api-call"),
            ):
                with self.subTest(transport=transport):
                    case = built[f"primary-failure/{transport}"]
                    self.assertEqual(case.scenario.model_dump(), {
                        "env": {"CREDENTIAL_FILE": "${credentials:login}", "TRANSPORT": transport}, "replies": replies, "credentials": {},
                    })
                    self.assertEqual(case.expected.result, {"failed": "usage: observation unavailable"})
                    self.assertEqual([f"{request.method} {request.url}" for request in case.expected.requests], [call])

    def assert_synthetic_case_ids(self, case_ids: Iterable[str]) -> None:
        """Check the full synthetic grid even if a transport disappears from both fixture files."""
        self.assertEqual(set(case_ids), {
            "optional-failure/cpa", "optional-failure/direct",
            "primary-failure/cpa", "primary-failure/direct",
            "success/cpa", "success/direct",
            "unreadable-credential/cpa", "unreadable-credential/direct",
        })

    def test_suite_refuses_a_pair_that_skips_a_declared_transport(self) -> None:
        """69. Reject a missing CPA case and a case for an undeclared transport before selection."""
        self.assert_synthetic_case_ids(SYNTHETIC.cases)
        with self.assertRaises(AssertionError):
            self.assert_synthetic_case_ids(name for name in SYNTHETIC.cases if not name.endswith("/cpa"))
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "expected.json").write_bytes((DIRECTORY / "expected.json").read_bytes())
            for missing in (True, False):
                data = json.loads((DIRECTORY / "input.json").read_bytes())
                if missing:
                    del data["scenarios"]["success"]["cpa"]
                else:
                    data["transports"] = ["direct"]
                (directory / "input.json").write_text(json.dumps(data))
                with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, "success/cpa: " if missing else "transport coverage"):
                    Pair.read(directory)

    def test_supplied_credentials_and_failed_bodies_stay_out_of_output(self) -> None:
        """Rubric 6, behavior 72. Flag leaks even when the public JSON or failure line still matches."""
        from synthetic import cli

        command = cli.main
        for name in (
            "optional-failure/cpa", "primary-failure/cpa", "optional-failure/direct", "primary-failure/direct",
        ):
            case = SYNTHETIC.cases[name]
            private_body = (
                ('{"message":"private nested upstream detail"}', "private nested upstream detail")
                if name.endswith("/cpa") else ("private upstream detail",)
            )
            for leaked in ("sample-private-value", *private_body):
                for stream in ("stdout", "stderr"):
                    def leaking_entry(env: Mapping[str, str], clock: Callable[[], datetime]) -> int:
                        status = command(env, clock)
                        if stream == "stdout":
                            print(leaked)
                        else:
                            os.write(2, leaked.encode())
                        return status

                    with self.subTest(case=name, stream=stream, private=leaked == "sample-private-value"), patch.object(cli, "main", leaking_entry):
                        reports = differences(SYNTHETIC.inputs, case, ENTRY)
                        self.assertIn(f"{name}: leak", [report.label for report in reports])
                        self.assertNotIn(leaked, "\n".join(map(str, reports)))


class RunnerTests(unittest.TestCase):
    """Each runner's own comparison keeps every private member out of what it prints and diffs what a Reader printed."""

    def private_pair(self, directory: Path, replies: Mapping[str, str], requests: Mapping[str, Sequence[Mapping[str, object]]]) -> Pair:
        """Write the synthetic pair with each named reply's body replaced and the requests of `primary-failure` on each named transport replaced; return the pair."""
        data = json.loads((DIRECTORY / "input.json").read_bytes())
        hoped = json.loads((DIRECTORY / "expected.json").read_bytes())
        for name, body in replies.items():
            data["replies"][name]["body"] = body
        for transport, sent in requests.items():
            hoped["primary-failure"][transport]["requests"] = sent
        data["scenarios"]["primary-failure"]["cpa"]["env"]["PROXY"] = "https://proxy.example"
        (directory / "input.json").write_text(json.dumps(data))
        (directory / "expected.json").write_text(json.dumps(hoped))
        return Pair.read(directory)

    def echoing_reader(self, directory: Path, body: object) -> str:
        """Write a Reader that sends `body` to the echo endpoint and fails with the expected public line; return its entry."""
        (directory / "echoing_reader.py").write_text(
            "import json\nimport sys\nfrom pathlib import Path\nimport urllib3\n\n\n"
            "def main(env, clock):\n"
            '    token = json.loads(Path(env["CREDENTIAL_FILE"]).read_text())["token"]\n'
            f'    urllib3.request("POST", "https://reader.example/echo", body=json.dumps({body!r}),'
            ' headers={"Accept": "application/json", "Authorization": "Bearer " + token})\n'
            "    print('usage: observation unavailable', file=sys.stderr)\n    return 1\n"
        )
        return "echoing_reader:main"

    def installed_command(self, directory: Path, body: object | None, failure: str) -> str:
        """Write an installed command that sends `body` to the proxy when given and fails with `failure`; return its path."""
        source = [
            f"#!{sys.executable}", "import json", "import os", "import pathlib", "import sys", "import urllib3", "",
            'if "PROXY" not in os.environ:', "    raise SystemExit(1)",
        ]
        if body is not None:
            source += [
                'token = json.loads(pathlib.Path(os.environ["CREDENTIAL_FILE"]).read_text())["token"]',
                "urllib3.request(",
                '    "POST", os.environ["PROXY"] + "/v0/management/api-call",',
                f"    body=json.dumps({body!r}).encode(),",
                '    headers={"Content-Type": "application/json", "Authorization": "Bearer " + token},',
                ")",
            ]
        command = directory / "command"
        command.write_text("\n".join([*source, f"print({failure!r}, file=sys.stderr)", "raise SystemExit(1)", ""]))
        command.chmod(0o700)
        return str(command)

    def assert_trace_report(self, pair: Pair, entry: str, report: str) -> None:
        """Run the imported comparison and compare its whole report with `report`."""
        sent = differences(pair.inputs, pair.cases["primary-failure/direct"], entry)
        self.assertEqual("\n".join(map(str, sent)) + "\n", report)

    def assert_installed_report(self, pair: Pair, case: str, command: str, report: str) -> None:
        """Run the installed comparison for one case and compare its whole report with `report`."""
        sent = installed_differences(pair.inputs, pair.cases[case], command)
        self.assertEqual("\n".join(map(str, sent)) + "\n", report)

    def assert_no_private_member(self, report: str, body: str) -> None:
        """Fail when the report spells a key or a scalar value of the JSON object."""
        for member in (json.dumps(part) for key, value in json.loads(body).items() for part in (key, value)):
            self.assertNotIn(member, report)

    def test_imported_runner_masks_a_private_reply_sent_back_as_a_request(self) -> None:
        """Rubric 6, behaviors 55, 72. Masking strings alone prints the keys and numbers of a private JSON body a Reader echoes."""
        with TemporaryDirectory() as tmp, patch.object(sys, "path", [tmp, *sys.path]):
            directory = Path(tmp)
            data = json.loads((DIRECTORY / "input.json").read_bytes())
            data["replies"]["failed"]["body"] = PRIVATE_BODY
            write_pair(directory, data)
            (directory / "echoing_reader.py").write_text(
                "import sys\nimport urllib3\n\n\ndef main(env, clock):\n"
                f'    urllib3.request("POST", "https://reader.example/echo", body={PRIVATE_BODY!r})\n'
                "    sys.exit(1)\n"
            )
            out, err = StringIO(), StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                status = run_cases([tmp, "echoing_reader:main", "primary-failure/direct"])
            self.assertEqual((status, out.getvalue()), (1, ""))
            self.assertIn("primary-failure/direct: trace\n", err.getvalue())
            self.assertIn(MASKED_BODY, err.getvalue())
            self.assert_no_private_member(err.getvalue(), PRIVATE_BODY)

    def test_installed_runner_masks_a_private_reply_sent_back_as_a_request(self) -> None:
        """Rubric 6, behaviors 55, 72. The installed runner reads the body from a socket, so it masks there too."""
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            data = json.loads((DIRECTORY / "input.json").read_bytes())
            data["replies"]["proxy-failed"]["body"] = json.dumps({"status_code": 503, "body": PRIVATE_BODY})
            data["scenarios"]["primary-failure"]["cpa"]["env"]["PROXY"] = "https://proxy.example"
            write_pair(directory, data)
            command = directory / "echoing-command"
            command.write_text(
                f"#!{sys.executable}\nimport json\nimport os\nimport pathlib\nimport urllib.request\n\n"
                'if "PROXY" not in os.environ:\n    raise SystemExit(1)\n'
                'token = json.loads(pathlib.Path(os.environ["CREDENTIAL_FILE"]).read_text())["token"]\n'
                "urllib.request.urlopen(urllib.request.Request(\n"
                '    os.environ["PROXY"] + "/v0/management/api-call",\n'
                f"    data={PRIVATE_BODY!r}.encode(),\n"
                '    headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},\n'
                "))\n"
            )
            command.chmod(0o700)
            out, err = StringIO(), StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                status = run_installed([tmp, str(command)])
            self.assertEqual((status, out.getvalue()), (1, ""))
            self.assertIn("primary-failure/cpa: trace\n", err.getvalue())
            self.assertIn(MASKED_BODY, err.getvalue())
            self.assert_no_private_member(err.getvalue(), PRIVATE_BODY)
            self.assertNotIn("sample-private-value", err.getvalue())

    def test_imported_runner_masks_a_private_number_and_boolean_inside_a_request_body(self) -> None:
        """Rubric 6, D1–D2. A number and a boolean are private members; the public member beside them stays visible."""
        with TemporaryDirectory() as tmp, patch.object(sys, "path", [tmp, *sys.path]):
            directory = Path(tmp)
            pair = self.private_pair(directory, {"failed": '{"ceiling": 9123, "waived": true}'}, {"direct": [ECHO | {"body": NOTE_ONLY}]})
            entry = self.echoing_reader(directory, {"note": "public note", "limit": 9123, "enabled": True})
            self.assert_trace_report(
                pair, entry,
                """primary-failure/direct: trace
--- expected
+++ observed
@@ -1,13 +1,15 @@
 [
   {
     "body": {
+      "enabled": "[private]",
+      "limit": "[private]",
       "note": "public note"
     },
     "headers": {
       "Accept": "application/json",
       "Authorization": "Bearer [credential:login]"
     },
     "method": "POST",
     "url": "https://reader.example/echo"
   }
 ]
""",
            )

    def test_imported_runner_masks_a_private_key(self) -> None:
        """Rubric 6, D1. A key of a private reply is private as a key, and as a token inside a string the Reader writes."""
        with TemporaryDirectory() as tmp, patch.object(sys, "path", [tmp, *sys.path]):
            directory = Path(tmp)
            pair = self.private_pair(directory, {"failed": '{"training-only-account": "hidden"}'}, {"direct": [ECHO | {"body": NOTE_ONLY}]})
            entry = self.echoing_reader(directory, {"note": "public note", "training-only-account": "renamed value", "reason": "training-only-account rejected"})
            self.assert_trace_report(
                pair, entry,
                """primary-failure/direct: trace
--- expected
+++ observed
@@ -1,13 +1,15 @@
 [
   {
     "body": {
-      "note": "public note"
+      "[private]": "renamed value",
+      "note": "public note",
+      "reason": "[private] rejected"
     },
     "headers": {
       "Accept": "application/json",
       "Authorization": "Bearer [credential:login]"
     },
     "method": "POST",
     "url": "https://reader.example/echo"
   }
 ]
""",
            )

    def test_imported_runner_masks_a_nested_subtree_of_a_private_object(self) -> None:
        """Rubric 6, D1–D2. A nested private subtree shown alone loses its key and number, not the public member beside it."""
        with TemporaryDirectory() as tmp, patch.object(sys, "path", [tmp, *sys.path]):
            directory = Path(tmp)
            pair = self.private_pair(directory, {"failed": '{"account": {"ceiling": 9123}}'}, {"direct": [ECHO | {"body": NOTE_ONLY}]})
            entry = self.echoing_reader(directory, {"note": "public note", "ceiling": 9123})
            self.assert_trace_report(
                pair, entry,
                """primary-failure/direct: trace
--- expected
+++ observed
@@ -1,13 +1,14 @@
 [
   {
     "body": {
+      "[private]": "[private]",
       "note": "public note"
     },
     "headers": {
       "Accept": "application/json",
       "Authorization": "Bearer [credential:login]"
     },
     "method": "POST",
     "url": "https://reader.example/echo"
   }
 ]
""",
            )

    def test_imported_runner_shows_a_public_member_beside_a_private_one(self) -> None:
        """Rubric 6, D2. A private single-member object beside a public method does not hide the method that differs."""
        with TemporaryDirectory() as tmp, patch.object(sys, "path", [tmp, *sys.path]):
            directory = Path(tmp)
            pair = self.private_pair(directory, {"failed": '{"state": 0}'}, {"direct": [ECHO | {"body": {"method": "POST", "state": 0}}]})
            entry = self.echoing_reader(directory, {"method": "GET", "state": 0})
            self.assert_trace_report(
                pair, entry,
                """primary-failure/direct: trace
--- expected
+++ observed
@@ -1,14 +1,14 @@
 [
   {
     "body": {
       "[private]": "[private]",
-      "method": "POST"
+      "method": "GET"
     },
     "headers": {
       "Accept": "application/json",
       "Authorization": "Bearer [credential:login]"
     },
     "method": "POST",
     "url": "https://reader.example/echo"
   }
 ]
""",
            )

    def test_imported_runner_names_the_withheld_members_that_differ(self) -> None:
        """Rubric 6, D3. Two values that differ only in a withheld member must not print an empty diff."""
        with TemporaryDirectory() as tmp, patch.object(sys, "path", [tmp, *sys.path]):
            directory = Path(tmp)
            pair = self.private_pair(directory, {"failed": '{"state": 0, "ceiling": 1}'}, {"direct": [ECHO | {"body": {"method": "GET", "state": 0}}]})
            entry = self.echoing_reader(directory, {"method": "GET", "state": 1})
            self.assert_trace_report(
                pair, entry,
                """primary-failure/direct: trace
expected and observed differ only in withheld members at: $[0].body.[private]
""",
            )

    def test_imported_runner_names_a_withheld_string_whose_text_changed(self) -> None:
        """Rubric 6, D3. A string that differs only in masked words must name its path, not print a bare marker."""
        with TemporaryDirectory() as tmp, patch.object(sys, "path", [tmp, *sys.path]):
            directory = Path(tmp)
            pair = self.private_pair(directory, {"failed": '{"from": "alpha", "to": "beta"}'}, {"direct": [ECHO | {"body": {"note": "usage: alpha denied"}}]})
            entry = self.echoing_reader(directory, {"note": "usage: beta denied"})
            self.assert_trace_report(
                pair, entry,
                """primary-failure/direct: trace
expected and observed differ only in withheld members at: $[0].body.note
""",
            )

    def test_installed_runner_masks_a_private_number_inside_a_failure_line(self) -> None:
        """Rubric 6, D1. A private number does not appear as a token inside a free-text failure line."""
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            pair = self.private_pair(directory, {"proxy-failed": '{"status_code": 503, "body": "{\\"limit\\": 9123}"}'}, {"cpa": []})
            command = self.installed_command(directory, None, "usage: ceiling 9123 is not allowed")
            self.assert_installed_report(
                pair, "primary-failure/cpa", command,
                """primary-failure/cpa: missing request
primary-failure/cpa: result
--- expected
+++ observed
@@ -1,3 +1,3 @@
 {
-  "failed": "usage: observation unavailable"
+  "failed": "usage: ceiling [private] is not allowed"
 }
""",
            )

    def test_installed_runner_masks_a_respelled_private_number_inside_a_failure_line(self) -> None:
        """Rubric 6, D1. A private number written as a decimal or an exponent is still that number."""
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            pair = self.private_pair(directory, {"proxy-failed": '{"status_code": 503, "body": "{\\"limit\\": 9123}"}'}, {"cpa": []})
            command = self.installed_command(directory, None, "usage: ceiling 9.123e3 (9123.0) is not allowed")
            self.assert_installed_report(
                pair, "primary-failure/cpa", command,
                """primary-failure/cpa: missing request
primary-failure/cpa: result
--- expected
+++ observed
@@ -1,3 +1,3 @@
 {
-  "failed": "usage: observation unavailable"
+  "failed": "usage: ceiling [private] ([private]) is not allowed"
 }
""",
            )

    def test_imported_runner_flags_an_escaped_private_string_on_a_stream(self) -> None:
        """Rubric 6. A private string printed with its quotes escaped is still a leak."""
        with TemporaryDirectory() as tmp, patch.object(sys, "path", [tmp, *sys.path]):
            directory = Path(tmp)
            pair = self.private_pair(directory, {"failed": '{"detail": "quota \\"exceeded\\""}'}, {"direct": [ECHO | {"body": NOTE_ONLY}]})
            (directory / "printing_reader.py").write_text(
                r"""import sys
import urllib3


def main(env, clock):
    urllib3.request("POST", "https://reader.example/echo", body="{}")
    print(r'detail: quota \"exceeded\"', file=sys.stdout)
    sys.exit(1)
"""
            )
            sent = differences(pair.inputs, pair.cases["primary-failure/direct"], "printing_reader:main")
            self.assertEqual([error.label for error in sent][:1], ["primary-failure/direct: leak"])

    def test_installed_runner_masks_private_json_echoed_as_a_respelled_string(self) -> None:
        """Rubric 6, D1. Private JSON carried in a string is masked whatever its whitespace and key order."""
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            proxy_call = {
                "method": "POST", "url": "https://proxy.example/v0/management/api-call",
                "headers": {"Content-Type": "application/json", "Authorization": "Bearer [credential:login]"}, "body": NOTE_ONLY,
            }
            pair = self.private_pair(
                directory, {"proxy-failed": '{"status_code": 503, "body": "{\\"ceiling\\": 9123, \\"waived\\": true}"}'}, {"cpa": [proxy_call]},
            )
            command = self.installed_command(directory, {"note": "public note", "limits": '{  "waived": true,   "ceiling": 9123 }'}, "usage: observation unavailable")
            self.assert_installed_report(
                pair, "primary-failure/cpa", command,
                """primary-failure/cpa: trace
--- expected
+++ observed
@@ -1,13 +1,17 @@
 [
   {
     "[private]": {
+      "limits" (JSON text): {
+        "[private]": "[private]",
+        "[private]": "[private]"
+      },
       "note": "public note"
     },
     "headers": {
       "Authorization": "Bearer [credential:login]",
       "Content-Type": "application/json"
     },
     "method": "POST",
     "url": "https://proxy.example/v0/management/api-call"
   }
 ]
""",
            )

    def test_installed_runner_diffs_a_result_stamped_outside_the_run(self) -> None:
        """71–72, 74. An instant outside the run is no accepted result, yet the fields the Reader printed belong in the diff."""
        with TemporaryDirectory() as tmp:
            command = Path(tmp) / "late-command"
            command.write_text(
                f"#!{sys.executable}\nimport json\nprint(json.dumps({{\n"
                '    "schemaVersion": 1, "account": {"auth_index": None, "name": None, "plan": "standard"}, "pool": "sample",\n'
                '    "observedAt": "2042-01-01T00:00:00Z", "accountedSpend": None, "balances": [], "bonuses": [],\n'
                '    "windows": {"1h": {"state": "observed", "enforced": True, "remainingPercent": 77, "resetsAt": None, "status": None,\n'
                '                        "usedPercent": 23, "windowSeconds": 3600}},\n'
                '    "slotStates": {"accountedSpend": {"state": "unsupported"}, "credits": {"state": "observed"},\n'
                '                   "grants": {"state": "unsupported"}, "resetInventory": {"state": "unsupported"}},\n'
                '    "binding": {"endpoint": "https://proxy.example/", "transport": "cpa"},\n'
                "}))\n"
            )
            command.chmod(0o700)
            out, err = StringIO(), StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                status = run_installed([str(DIRECTORY), str(command)])
            self.assertEqual((status, out.getvalue()), (1, ""))
            self.assertIn("success/cpa: result\n", err.getvalue())
            self.assertIn('+  "observedAt": "2042-01-01T00:00:00Z",\n', err.getvalue())
            self.assertNotIn("+null", err.getvalue())


if __name__ == "__main__":
    unittest.main()

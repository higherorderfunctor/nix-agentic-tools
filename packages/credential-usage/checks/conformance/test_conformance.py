# pyright: strict
# cspell:ignore replys
"""Exercise the suite's comparisons with a working Reader and one deliberate fault at a time."""

from collections.abc import Callable, Iterable, Mapping
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
from suite import Case, IncompletePair, Pair, differences


DIRECTORY = HERE / "synthetic" / "cases"
SYNTHETIC = Pair.read(DIRECTORY)
ENTRY = "synthetic.cli:main"

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


def drop_header(request: Callable[[DirectHttp, HttpRequest], HttpResponse]) -> Callable[[DirectHttp, HttpRequest], HttpResponse]:
    """Wrap the real synthetic transport with a missing-header fault."""
    def without_headers(client: DirectHttp, message: HttpRequest) -> HttpResponse:
        return request(client, message.model_copy(update={"headers": {}}))
    return without_headers


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
            (patch.object(DirectHttp, "request", drop_header(DirectHttp.request)), ["trace"]),
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
        case = SYNTHETIC.cases["success/direct"]
        out, err = StringIO(), StringIO()
        with patch.object(DirectHttp, "request", drop_header(DirectHttp.request)), redirect_stdout(out), redirect_stderr(err):
            status = run_cases([str(DIRECTORY), ENTRY, case.name])
        self.assertEqual(status, 1)
        self.assertEqual(out.getvalue(), "")
        self.assertEqual(err.getvalue(), DROPPED_HEADER)

    def test_pair_builds_each_case_from_its_full_case(self) -> None:
        """69, 71–72. Merging arrays by position, or keeping a full case's requests when a case lists none, hides a wrong Reader."""
        optional = SYNTHETIC.cases["optional-failure/cpa"]
        self.assertEqual(
            optional.scenario.model_dump(),
            {"env": {"CREDENTIAL_FILE": "${credentials:login}", "TRANSPORT": "cpa"}, "replies": ["proxy-allowance", "proxy-failed"], "credentials": {}},
        )
        self.assertEqual(optional.expected.requests, SYNTHETIC.cases["success/cpa"].expected.requests)
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
                **{
                    transport: {"requests": [request.model_dump() for request in SYNTHETIC.cases[f"primary-failure/{transport}"].expected.requests]}
                    for transport in ("direct", "cpa")
                },
            }
            (directory / "input.json").write_text(json.dumps(data))
            (directory / "expected.json").write_text(json.dumps(hoped))
            self.assertEqual(Pair.read(directory).cases, SYNTHETIC.cases)

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


if __name__ == "__main__":
    unittest.main()

# pyright: strict
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

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from credential_usage.transport import DirectHttp, HttpRequest, HttpResponse
from run import main as run_cases
from suite import Case, Pair, differences


DIRECTORY = HERE / "synthetic" / "cases"
SYNTHETIC = Pair.read(DIRECTORY)
ENTRY = "synthetic.cli:main"


class GoldenCases(unittest.TestCase):
    """Each scenario and transport gets a separate test ID so a mutation kill identifies its case."""


def golden_test(pair: Pair, case: Case, entry: str) -> Callable[[GoldenCases], None]:
    """Bind the case before discovery so unittest and pytest collect the same tests."""
    def test_reader_matches_expected_requests_and_result(self: GoldenCases) -> None:
        """69, 71–72. Comparing only the last request or one result field can hide an incorrect Reader."""
        self.assertEqual(differences(pair.inputs, case, entry), [])
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
    """The suite must reject incorrect Readers and incomplete fixture pairs."""

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
                self.assertEqual(differences(SYNTHETIC.inputs, case, ENTRY), [f"success/direct: {label}" for label in labels])

        def print_offset(document: str) -> None:
            print(document.replace("2026-11-01T00:00:02Z", "2026-11-01T01:00:02+01:00"))

        with self.subTest(fault="offset instant"), patch.object(cli, "print", print_offset, create=True):
            self.assertEqual(differences(SYNTHETIC.inputs, case, ENTRY), ["success/direct: result"])

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
                    self.assertEqual(differences(SYNTHETIC.inputs, case, entry), expected)
                out, err = StringIO(), StringIO()
                with self.subTest(module=module, caller="run"), redirect_stdout(out), redirect_stderr(err):
                    self.assertEqual(run_cases([str(DIRECTORY), entry, case.name]), 1)
                    self.assertEqual(out.getvalue(), "")
                    self.assertEqual(err.getvalue().splitlines(), expected)

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
                with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, "transport coverage"):
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
                        errors = differences(SYNTHETIC.inputs, case, ENTRY)
                        self.assertIn(f"{name}: leak", errors)
                        self.assertNotIn(leaked, "\n".join(errors))


if __name__ == "__main__":
    unittest.main()

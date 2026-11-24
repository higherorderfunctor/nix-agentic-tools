# pyright: strict
"""Exercise the suite's comparisons with a working Reader and one deliberate fault at a time."""

from collections.abc import Callable, Mapping
from datetime import datetime
from importlib import import_module
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from typing import cast
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from credential_usage.transport import DirectHttp, HttpRequest, HttpResponse
from suite import Case, Entry, Pair, differences
from synthetic import cli


DIRECTORY = HERE / "synthetic" / "cases"
SYNTHETIC = Pair.read(DIRECTORY)


class GoldenCases(unittest.TestCase):
    """Each scenario and transport gets a separate test ID so a mutation kill identifies its case."""


def golden_test(pair: Pair, case: Case, entry: Entry) -> Callable[[GoldenCases], None]:
    """Bind the case before discovery so unittest and pytest collect the same tests."""
    def test_synthetic_fill_passes_each_declared_transport(self: GoldenCases) -> None:
        """69–72. Comparing only the last request or one result field can hide an incorrect Reader."""
        self.assertEqual(differences(pair.inputs, case, entry), [])
    return test_synthetic_fill_passes_each_declared_transport


def collect_golden_cases() -> None:
    """Use the owner's selected pair and entry, or the synthetic pair during the suite's own check."""
    directory = os.environ.get("READER_PAIR")
    if directory is None:
        pair, entry = SYNTHETIC, cli.main
    else:
        module, name = os.environ["READER_ENTRY"].split(":")
        pair, entry = Pair.read(Path(directory)), cast(Entry, getattr(import_module(module), name))
    for name, case in pair.cases.items():
        setattr(GoldenCases, f"test_synthetic_fill_passes_each_declared_transport__{name.replace('/', '__')}", golden_test(pair, case, entry))


collect_golden_cases()


class SuiteTests(unittest.TestCase):
    """The suite must reject incorrect Readers and incomplete fixture pairs."""

    def test_suite_rejects_each_broken_decision_naming_the_case(self) -> None:
        """71–72. Fail the named comparison for a dropped header, wrong field, missing or extra request."""
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
                self.assertEqual(differences(SYNTHETIC.inputs, case, cli.main), [f"success/direct: {label}" for label in labels])

    def test_suite_refuses_a_pair_that_skips_a_declared_transport(self) -> None:
        """69. Reject a missing CPA case and a case for an undeclared transport before selection."""
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
        for name in ("optional-failure/direct", "primary-failure/direct"):
            case = SYNTHETIC.cases[name]
            for leaked in ("sample-private-value", "private upstream detail"):
                for stream in ("stdout", "stderr"):
                    def leaking_entry(env: Mapping[str, str], clock: Callable[[], datetime]) -> int:
                        status = cli.main(env, clock)
                        if stream == "stdout":
                            print(leaked)
                        else:
                            os.write(2, leaked.encode())
                        return status

                    with self.subTest(case=name, stream=stream, private=leaked == "sample-private-value"):
                        errors = differences(SYNTHETIC.inputs, case, leaking_entry)
                        self.assertIn(f"{name}: leak", errors)
                        self.assertNotIn(leaked, "\n".join(errors))


if __name__ == "__main__":
    unittest.main()

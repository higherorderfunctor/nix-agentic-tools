"""Compare offline CPA request traces and direct HTTP calls to their expected wire contracts."""

import json
from pathlib import Path
import sys
import unittest
from typing import NamedTuple
from unittest.mock import ANY, patch

from pydantic import BaseModel, HttpUrl, JsonValue, SecretStr
from urllib3.response import HTTPResponse

HERE = Path(__file__).resolve().parent
CASES = HERE / "cases" / "binding"
scripts = sys.argv.pop(1) if len(sys.argv) > 1 else HERE.parents[2] / "scripts"
sys.path[:0] = [str(HERE), str(scripts)]

from mock import RecordingTransport
from usage.cpa import CpaInstance, UnknownBinding
from usage.transport import DirectHttp, HttpPolicy, HttpRequest, RequestFailure


class Case(NamedTuple):
    """Choose a credential and replay the ordered management replies for this case."""

    provider: str | None
    discover_keys: bool
    pin: str | None
    replies: list[str]
    request: str = "usage"


class Fixture(BaseModel):
    """The shared fixture supplies an instance, vendor request and named CPA responses."""

    instance: HttpUrl
    direct: dict[str, str]
    discovery_base: HttpUrl
    requests: dict[str, HttpRequest]
    surfaces: tuple[str, ...]
    replies: dict[str, tuple[int, JsonValue]]
    cases: dict[str, Case]


fixture = Fixture.model_validate_json((CASES / "input.json").read_bytes())
expected = json.loads((CASES / "expected.json").read_bytes())


class TransportTests(unittest.TestCase):
    def test_cpa_binds_one_credential(self) -> None:
        """Compare each complete request and outcome, including refused and failed calls."""
        requests = {
            key: expected["request_defaults"] | value
            for key, value in expected["requests"].items()
        }
        self.assertEqual(set(fixture.cases), set(expected["cases"]))
        for name, case in fixture.cases.items():
            with self.subTest(behavior=name):
                mock = RecordingTransport(fixture.replies[key] for key in case.replies)
                instance = CpaInstance(fixture.instance, mock)
                try:
                    binding = instance.bind(
                        discovery_base=fixture.discovery_base,
                        provider=case.provider,
                        surfaces=fixture.surfaces if case.discover_keys else None,
                        pin=case.pin,
                    )
                    outcome = (
                        binding.value
                        if isinstance(binding, UnknownBinding)
                        else binding.request(fixture.requests[case.request]).model_dump()
                    )
                except RequestFailure as error:
                    outcome = str(error)
                calls, result = expected["cases"][name]
                self.assertEqual(mock.requests, [requests[key] for key in calls])
                self.assertEqual(
                    outcome, expected["success"] if result == "success" else result
                )

    def test_direct_http_binds_the_token_and_owns_network_retries(self) -> None:
        """Check the direct authorization, network policy and refusal to cross origins."""
        request = fixture.requests["usage"]
        policy = HttpPolicy(timeout=3, retries=2)
        client = DirectHttp(request.url, SecretStr("local-only"), policy)
        reply = HTTPResponse(status=201, body=b"usage")
        with patch("urllib3.request", return_value=reply) as send:
            result = client.request(request)
            self.assertEqual(result.model_dump(), {"status_code": 201, "body": "usage"})
            with self.assertRaisesRegex(RequestFailure, "origin mismatch"):
                client.request(fixture.requests["elsewhere"])
            send.assert_called_once_with(
                "POST",
                "https://vendor.test/usage",
                headers={"Accept": "text/plain", "Authorization": "Bearer local-only"},
                body="query",
                timeout=3,
                redirect=False,
                retries=ANY,
            )
            self.assertEqual(send.call_args.kwargs["retries"].total, 2)
            send.return_value = HTTPResponse(status=503, body=b"local-only")
            with self.assertRaisesRegex(RequestFailure, "^HTTP 503$"):
                client.request(request)
            name = "private network exception"
            send.side_effect = OSError(fixture.direct[name])
            with self.assertRaises(RequestFailure) as failure:
                client.request(request)
            self.assertEqual(str(failure.exception), expected["direct"][name])


if __name__ == "__main__":
    unittest.main()

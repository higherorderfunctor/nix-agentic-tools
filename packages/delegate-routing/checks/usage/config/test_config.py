"""Check the catalog builds' installed manifests and exercise capture retention on their CPA routes."""

from collections import Counter
import json
from datetime import datetime
from pathlib import Path
import re
import sys

sys.path.insert(0, sys.argv[1])
from usage.config import CaptureFailure, CredentialReader, UsageManifest
from cliproxyapi.usage.transport import UnknownBinding
from credential_usage.runner import MissingReader, ReaderSuccess
from credential_usage.transport import RequestFailure


def packaged_manifest(skill: Path) -> str:
    """Follow the same skill-to-wrapper-to-manifest chain as the installed helper."""
    wrapper = re.search(r"`(/nix/store/[^` ]+/bin/delegate-routing-plan) --role", skill.read_text())
    assert wrapper
    manifest = re.search(r"--manifest (/nix/store/[^\s]+)", Path(wrapper[1]).read_text())
    assert manifest
    return Path(manifest[1]).read_text()


def check_collection(raw: str, expected_routes: list[dict[str, object]]) -> None:
    """A wrong pin must discard all allowance, retain every route and preserve the sibling capture."""
    manifest = UsageManifest.model_validate_json(raw)
    cases = Path(__file__).with_name("attribution")
    inputs, expected = (json.loads((cases / f"{part}.json").read_text()) for part in ("input", "expected"))
    for name, first in inputs["first"].items():
        calls: list[tuple[str, str, str | None, int]] = []

        def read(instance: str, credential: str, reader: CredentialReader):
            calls.append((instance, credential, reader.pin, reader.transport.retries))
            if first is None:
                if credential == "second":
                    return UnknownBinding.AMBIGUOUS
                raise RequestFailure("private diagnostic")
            identity = first if credential == "first" else inputs["second"]
            stdout = json.dumps({**inputs["capture"], **identity})
            return ReaderSuccess(datetime.fromisoformat(inputs["finished"][credential]), stdout)

        results = manifest.pacing.collect(read)
        # Multiple offers for a credential must not trigger extra reader calls.
        assert calls == [("test", "first", "account-17", 3), ("test", "second", None, 0)], (name, calls)
        routes = [result.route.model_dump() for result in results]
        assert routes == expected_routes, (name, routes)
        first_capture, first_repeat, second_capture, second_repeat, missing = [result.outcome for result in results]
        assert first_repeat is first_capture and second_repeat is second_capture, (name, "offers did not share their capture")
        assert missing is MissingReader.NO_COMMAND, (name, missing)
        if first is None:
            assert first_capture is CaptureFailure.REQUEST, (name, "first", first_capture)
            assert second_capture is UnknownBinding.AMBIGUOUS, (name, "second", second_capture)
        else:
            for credential, outcome, want in (
                ("first", first_capture, expected[name]),
                ("second", second_capture, expected["unpinned sibling"]),
            ):
                actual = [outcome.observed_at, outcome.reason, {k: v.window.remainingPercent for k, v in outcome.windows.items()}]
                assert actual == want, (name, credential, actual, want)


if __name__ == "__main__":
    expected = json.loads(Path(__file__).with_name("expected.json").read_text())
    runtimes: Counter[str] = Counter()
    for skill in sys.argv[2:]:
        raw = packaged_manifest(Path(skill))
        shipped = json.loads(raw)
        runtime = shipped["runtime"]
        runtimes[runtime] += 1
        assert shipped["pacing"] == expected[runtime], skill
        assert "synthetic-private-upstream-" not in raw and "/run/secrets/upstream" not in raw, skill
        if runtime == "claude":
            check_collection(raw, expected[runtime]["routes"])
    # Each runtime has a manual and a module skill in both HM and devenv.
    assert runtimes == {"claude": 4, "codex": 4}, runtimes
    print(f"PASS {len(sys.argv) - 2} packaged credential manifests and capture retention")

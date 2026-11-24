"""Check the catalog builds' installed manifests and exercise capture retention on their CPA routes."""

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
    for name, first_stdout in inputs["first"].items():
        calls: list[tuple[str, str, str | None, int]] = []

        def read(instance: str, credential: str, reader: CredentialReader):
            calls.append((instance, credential, reader.pin, reader.transport.retries))
            if first_stdout is None:
                if credential == "second":
                    return UnknownBinding.AMBIGUOUS
                raise RequestFailure("private diagnostic")
            stdout = first_stdout if credential == "first" else inputs["second"]
            return ReaderSuccess(datetime.fromisoformat(inputs["finished"][credential]), stdout)

        results = manifest.pacing.collect(read)
        assert calls == [("test", "first", "account-17", 3), ("test", "second", None, 0)]
        first, _, second, _, missing = [result.outcome for result in results]
        assert results[1].outcome is first and results[3].outcome is second and missing is MissingReader.NO_COMMAND
        if first_stdout is None:
            assert first is CaptureFailure.REQUEST and second is UnknownBinding.AMBIGUOUS
        else:
            for outcome, want in ((first, expected[name]), (second, expected["unpinned sibling"])):
                actual = [outcome.observed_at, outcome.reason, {k: v.window.remainingPercent for k, v in outcome.windows.items()}]
                assert actual == want, (name, actual, want)
        assert [result.route.model_dump() for result in results] == expected_routes


if __name__ == "__main__":
    assert len(sys.argv) > 2, "the catalog check must supply its packaged skills"
    expected = json.loads(Path(__file__).with_name("expected.json").read_text())
    for skill in sys.argv[2:]:
        raw = packaged_manifest(Path(skill))
        shipped = json.loads(raw)
        runtime = shipped["runtime"]
        assert shipped["pacing"] == expected[runtime], skill
        assert "synthetic-private-upstream-" not in raw and "/run/secrets/upstream" not in raw, skill
        if runtime == "claude":
            check_collection(raw, expected[runtime]["routes"])
    print(f"PASS {len(sys.argv) - 2} packaged credential manifests and capture retention")

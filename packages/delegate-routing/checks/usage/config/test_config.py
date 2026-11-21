"""Check the catalog builds' installed manifests and exercise capture retention on their CPA routes."""

import json
from datetime import UTC, datetime
from pathlib import Path
import re
import sys

sys.path.insert(0, sys.argv[1])
from usage.config import CaptureFailure, CredentialReader, UsageManifest
from usage.cpa import UnknownBinding
from usage.runner import MissingReader, ReaderSuccess
from usage.transport import RequestFailure


def packaged_manifest(skill: Path) -> str:
    """Follow the same skill-to-wrapper-to-manifest chain as the installed helper."""
    wrapper = re.search(r"`(/nix/store/[^` ]+/bin/delegate-routing-plan) --role", skill.read_text())
    assert wrapper
    manifest = re.search(r"--manifest (/nix/store/[^\s]+)", Path(wrapper[1]).read_text())
    assert manifest
    return Path(manifest[1]).read_text()


def check_collection(raw: str, expected_routes: list[dict[str, object]]) -> None:
    """Missing, ambiguous and failed Readers keep their own routes and do not affect siblings."""
    manifest = UsageManifest.model_validate_json(raw)
    success = ReaderSuccess(datetime(2026, 11, 20, tzinfo=UTC), "fixture output")
    for first_result in (success, CaptureFailure.REQUEST):
        calls: list[tuple[str, str, str | None, int]] = []

        def read(instance: str, credential: str, reader: CredentialReader):
            calls.append((instance, credential, reader.pin, reader.transport.retries))
            if credential == "second":
                return UnknownBinding.AMBIGUOUS
            if first_result is CaptureFailure.REQUEST:
                raise RequestFailure("private diagnostic")
            return success

        results = manifest.pacing.collect(read)
        assert calls == [("test", "first", "account-17", 3), ("test", "second", None, 0)]
        assert [result.outcome for result in results] == [
            first_result, first_result, UnknownBinding.AMBIGUOUS, UnknownBinding.AMBIGUOUS, MissingReader.NO_COMMAND
        ]
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

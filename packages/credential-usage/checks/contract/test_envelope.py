"""Check the published Reader example and three envelope rules against literal outcomes."""

import json
import os
from pathlib import Path
import re
import unittest
from typing import Any

from pydantic import ValidationError

from credential_usage.envelope import Envelope

DOC = Path(os.environ.get("USAGE_DOC", Path(__file__).resolve().parents[2] / "docs/credential-usage.md"))


def documented_example() -> dict[str, Any]:
    """Read the single JSON example in the public usage envelope section."""
    section = DOC.read_text().split("## The usage envelope\n", 1)[1].split("\n## ", 1)[0]
    [example] = re.findall(r"^```json\n(.*?)\n```$", section, re.M | re.S)
    return json.loads(example)


class TestEnvelope(unittest.TestCase):
    """Change named fields of the published example to isolate one envelope rule."""

    def setUp(self) -> None:
        """Start each rule from a fresh copy of the published example."""
        self.document = documented_example()

    def read(self) -> dict[str, Any]:
        """Return the changed example as the envelope publishes it, or raise."""
        return json.loads(Envelope.model_validate_json(json.dumps(self.document)).model_dump_json())

    def refused(self) -> None:
        """Assert that the envelope rejects the changed example."""
        with self.assertRaises(ValidationError):
            self.read()

    def test_documented_example_validates(self) -> None:
        """The published example decodes and writes back unchanged."""
        self.assertEqual(self.read(), self.document)

    def test_version_mismatch_is_a_safe_failure(self) -> None:
        """Refuse a schema version this consumer cannot read, and a document that names none."""
        self.document["schemaVersion"] = 2
        self.refused()
        del self.document["schemaVersion"]
        self.refused()

    def test_entry_requires_an_observed_slot(self) -> None:
        """Refuse spend under an unsupported slot, and an observed slot that reports none."""
        spend = {"cost": 0, "currency": "USD", "source": "meter"}
        self.document["accountedSpend"] = spend
        self.refused()
        self.document["slotStates"]["accountedSpend"] = {"state": "observed"}
        self.assertEqual(self.read()["accountedSpend"], spend)
        self.document["accountedSpend"] = None
        self.refused()

    def test_missing_slot_state_is_invalid(self) -> None:
        """An omitted slot state proves nothing, so it is invalid even with no entry under it."""
        for slot in self.document["slotStates"]:
            with self.subTest(slot=slot):
                self.document = documented_example()
                del self.document["slotStates"][slot]
                self.refused()


if __name__ == "__main__":
    unittest.main()

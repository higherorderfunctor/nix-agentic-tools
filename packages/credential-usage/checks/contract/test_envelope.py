"""Check the published Reader example and three envelope rules, each isolated by one change to that example."""

import json
import os
from pathlib import Path
import re
import unittest

from pydantic import ValidationError

from credential_usage.envelope import Envelope

DOC = Path(os.environ.get("USAGE_DOC", Path(__file__).resolve().parents[2] / "docs/credential-usage.md"))
SECTION = DOC.read_text().split("## The usage envelope\n", 1)[1].split("\n## ", 1)[0]
[EXAMPLE] = re.findall(r"^```json\n(.*?)\n```$", SECTION, re.M | re.S)
BASE = json.loads(EXAMPLE)
SPEND = {"cost": 0, "currency": "USD", "source": "meter"}
SPEND_OBSERVED = BASE["slotStates"] | {"accountedSpend": {"state": "observed"}}


class TestEnvelope(unittest.TestCase):
    def test_documented_example_validates(self) -> None:
        Envelope.model_validate_json(EXAMPLE)

    def test_version_mismatch_is_a_safe_failure(self) -> None:
        absent = {key: value for key, value in BASE.items() if key != "schemaVersion"}
        self.assertRaises(ValidationError, Envelope.model_validate, BASE | {"schemaVersion": 2})
        self.assertRaises(ValidationError, Envelope.model_validate, absent)

    def test_entry_requires_an_observed_slot(self) -> None:
        self.assertRaises(ValidationError, Envelope.model_validate, BASE | {"accountedSpend": SPEND})
        self.assertRaises(ValidationError, Envelope.model_validate, BASE | {"slotStates": SPEND_OBSERVED})
        Envelope.model_validate(BASE | {"accountedSpend": SPEND, "slotStates": SPEND_OBSERVED})

    def test_missing_slot_state_is_invalid(self) -> None:
        for slot in BASE["slotStates"]:
            states = {name: state for name, state in BASE["slotStates"].items() if name != slot}
            with self.subTest(slot=slot):
                self.assertRaises(ValidationError, Envelope.model_validate, BASE | {"slotStates": states})


if __name__ == "__main__":
    unittest.main()

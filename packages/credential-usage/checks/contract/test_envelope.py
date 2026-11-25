"""Check the published Reader example and its boundary cases against literal outcomes."""

from collections.abc import Callable
import json
import os
from pathlib import Path
import re
import unittest

from pydantic import BaseModel, ConfigDict, JsonValue, TypeAdapter, ValidationError

from credential_usage.envelope import Envelope


CASES = Path(__file__).parent / "cases"
DOC = Path(os.environ.get("USAGE_DOC", Path(__file__).resolve().parents[2] / "docs/credential-usage.md"))
Object = dict[str, JsonValue]


class Case(BaseModel):
    """Change named fields in the public example to isolate one boundary decision."""

    model_config = ConfigDict(extra="forbid", strict=True)
    changes: Object = {}
    omit: list[str] = []
    raw: str | None = None
    suffix: str = ""

    def document(self, example: str) -> str:
        """Start each case from the same example, including stream and malformed inputs."""
        if self.raw is not None:
            return self.raw
        if not self.changes and not self.omit:
            return example + self.suffix
        result = json.loads(example)
        for path in [*self.changes, *self.omit]:
            *parents, field = path.split(".")
            parent = result
            for name in parents:
                parent = parent[name]
            if path in self.changes:
                parent[field] = self.changes[path]
            else:
                del parent[field]
        return json.dumps(result) + self.suffix


class Expected(BaseModel):
    """Supply independent public values for the successful cases."""

    model_config = ConfigDict(extra="forbid", strict=True)
    withDurationZero: Object
    withZero: Object
    withoutZero: Object
    recorded: str
    offsetFraction: str


def documented_example() -> str:
    """Read the single JSON example in the public usage envelope section."""
    section = DOC.read_text().split("## The usage envelope\n", 1)[1].split("\n## ", 1)[0]
    [example] = re.findall(r"^```json\n(.*?)\n```$", section, re.M | re.S)
    return example


class TestEnvelope(unittest.TestCase):
    """Run each named decision on literal changes to the documented envelope."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the published example and both case files once for this suite."""
        cls.example = documented_example()
        cls.cases = TypeAdapter(dict[str, dict[str, Case]]).validate_json((CASES / "input.json").read_bytes())
        cls.expected = Expected.model_validate_json((CASES / "expected.json").read_bytes())

    def check_cases(
        self, group: str, accepted: dict[str, JsonValue] | None = None,
        read: Callable[[Envelope], JsonValue] = lambda model: model.model_dump(mode="json"),
    ) -> None:
        """Unlisted successes fail so a refused case cannot silently become an observation."""
        accepted = accepted or {}
        self.assertLessEqual(accepted.keys(), self.cases[group].keys())
        for name, case in self.cases[group].items():
            with self.subTest(case=name):
                document = case.document(self.example)
                if name in accepted:
                    self.assertEqual(read(Envelope.model_validate_json(document)), accepted[name])
                else:
                    with self.assertRaises(ValidationError):
                        Envelope.model_validate_json(document)

    def test_requires_one_json_document(self) -> None:
        """1–2. Reject malformed JSON and trailing accounts instead of returning a first result."""
        self.check_cases("document")
        with self.subTest(case="truncated"), self.assertRaises(ValidationError):
            Envelope.model_validate_json(self.example.rstrip().removesuffix("}"))

    def test_requires_supported_schema_version(self) -> None:
        """3, 5. Decode the published example and refuse missing or unsupported versions."""
        self.check_cases("version", {"documented": 1}, lambda envelope: envelope.schemaVersion)

    def test_requires_all_slot_states(self) -> None:
        """6. Refuse a missing slot even if its inventory is empty."""
        self.check_cases("declarations")

    def test_inventory_requires_observed_slots(self) -> None:
        """8–11. Keep observed zero spend. Refuse entries without an observed slot, and unknown reason codes."""
        self.check_cases(
            "slot-states", {"observed-inventory": ["observed", 0]},
            lambda env: [env.slotStates.accountedSpend.state, env.accountedSpend.cost if env.accountedSpend else None],
        )

    def test_requires_allowance_windows(self) -> None:
        """13. Refuse wallet-only success when the allowance result is absent."""
        self.check_cases("allowance")

    def test_requires_finite_complementary_percentages(self) -> None:
        """15–16, 22. Refuse coercions, infinities and inconsistent or out-of-range shares."""
        self.check_cases("percent")

    def test_requires_positive_window_duration(self) -> None:
        """17. Reject zero and negative durations before computing a pace."""
        self.check_cases("duration")

    def test_invalid_windows_keep_only_a_proven_zero(self) -> None:
        """18–24. Keep zero for invalid timing and reject it for conflicts or invalid utilization."""
        self.check_cases(
            "invalid",
            {
                "invalid-duration-with-zero": self.expected.withDurationZero,
                "unproven": self.expected.withoutZero, "zero": self.expected.withZero,
            },
            lambda envelope: envelope.windows["7d"].model_dump(mode="json"),
        )

    def test_requires_recorded_capture_time(self) -> None:
        """29–30. Require the recorded capture time and keep it when replayed."""
        self.check_cases(
            "capture", {"recorded": self.expected.recorded},
            lambda envelope: envelope.model_dump(mode="json")["observedAt"],
        )

    def test_normalizes_offsets_and_preserves_fractions(self) -> None:
        """31. Apply the offset and truncate UTC fractions to microseconds."""
        self.check_cases(
            "instant", {"offset-fraction": self.expected.offsetFraction},
            lambda envelope: envelope.model_dump(mode="json")["observedAt"],
        )


if __name__ == "__main__":
    unittest.main()

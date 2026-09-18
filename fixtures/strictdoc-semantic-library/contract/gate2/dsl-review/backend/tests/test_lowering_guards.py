"""What the stub refuses while lowering, and what it deliberately accepts.

``backend/fixtures/lowering-guards`` holds models that are lowered rather than
evaluated. Six must be refused and two must be accepted, and every one of them
is a fault a candidate cannot cause: the model itself is wrong. A fault this
directory pins used to reach a backend instead, where it reported a record uid
for a defect that lives in the model.

The two accepted models are positive controls. Without them a harness that
could not lower anything would report six refusals and read as green.

Each message is asserted by a fragment rather than in full, because a Nix error
carries a stack trace around it. The fragments name the field and the element,
which is the part an author has to read.
"""

import json
import pathlib
import shutil
import subprocess
import unittest

TESTS_DIRECTORY = pathlib.Path(__file__).resolve().parent
BACKEND_DIRECTORY = TESTS_DIRECTORY.parent
GUARDS_DIRECTORY = BACKEND_DIRECTORY / "fixtures/lowering-guards"

# Lowering one model evaluates the stub, the native grammar dsl it imports and
# every keyword check over the result, so the timeout is generous rather than
# tight; a hung evaluation should still fail the run rather than hang it.
LOWERING_TIMEOUT_SECONDS = 300

# Each refused model, and the fragment its message must carry.
REFUSED = {
    "field-value-boolean-value": (
        "field value: FLAG admits native strings only"
    ),
    "field-value-integer-value": (
        "field value: TITLE admits native strings only"
    ),
    "field-value-names-another-elements-field": (
        '["open"] is not a declared choice of STATE on NOTE'
    ),
    "field-value-owner-subject-field-the-owner-lacks": (
        "the field STATE is not declared on NOTE"
    ),
    "native-single-choice-field": (
        "a singleChoice field has no semantic type"
    ),
    "native-relation-of-an-unknown-kind": 'invalid keyword direction: "sibling"',
    "native-tag-field": "a tag field has no semantic type",
}

ACCEPTED = (
    "field-value-target-subject-another-elements-field",
    "file-relation-declaration",
)


@unittest.skipUnless(
    shutil.which("nix-instantiate"),
    "nix-instantiate is not on PATH, so no lowering can be produced",
)
class LoweringGuards(unittest.TestCase):
    """Lowers each guard model and reads its outcome."""

    def lower(self, name):
        """Return the completed nix-instantiate run for one guard model."""
        path = GUARDS_DIRECTORY / (name + ".nix")
        self.assertTrue(path.is_file(), "no such guard model: %s" % path)
        return subprocess.run(
            ["nix-instantiate", "--eval", "--strict", "--json", str(path)],
            capture_output=True,
            text=True,
            timeout=LOWERING_TIMEOUT_SECONDS,
            check=False,
        )

    def test_every_listed_model_is_present_and_every_model_is_listed(self):
        """A model nobody lowers, or a listing naming nothing, both fail here."""
        present = sorted(path.stem for path in GUARDS_DIRECTORY.glob("*.nix"))
        self.assertEqual(present, sorted(set(REFUSED) | set(ACCEPTED)))

    def test_each_refused_model_is_refused_by_its_own_message(self):
        for name, fragment in sorted(REFUSED.items()):
            with self.subTest(model=name):
                completed = self.lower(name)
                self.assertNotEqual(
                    completed.returncode,
                    0,
                    "%s lowered, and it must be refused.\n%s"
                    % (name, completed.stdout),
                )
                self.assertIn(fragment, completed.stderr)

    def test_each_accepted_model_lowers(self):
        for name in ACCEPTED:
            with self.subTest(model=name):
                completed = self.lower(name)
                self.assertEqual(
                    completed.returncode,
                    0,
                    "%s does not lower.\n%s" % (name, completed.stderr),
                )

    def test_a_target_subject_reads_a_field_its_own_element_lacks(self):
        """The asymmetry the contract keeps (contract.md:288-293).

        NOTE declares no STATE, and the leaf reads the TARGET's STATE over
        NOTE's H occurrences. The element is not fixed, so the name resolves
        against the model and lowering says nothing about which record will
        carry it.
        """
        lowered = self.lowered("field-value-target-subject-another-elements-field")
        rules = lowered["bundle"]["rules"]
        self.assertEqual(len(rules), 1)
        self.assertEqual(
            rules[0]["check"],
            {
                "absentSatisfies": False,
                "field": "STATE",
                "kind": "field-value",
                "subject": "target",
                "values": ["open"],
            },
        )

    def test_a_file_relation_reaches_the_grammar_and_no_declaration(self):
        """It is a native relation and not a semantic one.

        The grammar keeps both relations, because that is what a .sgra says.
        The declarations name the H relation alone, so no selector, reference
        or check can reach the File one.
        """
        lowered = self.lowered("file-relation-declaration")
        self.assertEqual(
            lowered["grammar"][0]["relations"],
            [{"parent": {"role": "H", "reverseRole": "H_back"}}, {"file": {}}],
        )
        self.assertEqual(
            [
                declaration["name"]
                for declaration in lowered["bundle"]["declarations"]
                if declaration["kind"] == "relation"
            ],
            ["H"],
        )

    def lowered(self, name):
        """Return one accepted guard model's lowering, decoded."""
        completed = self.lower(name)
        self.assertEqual(
            completed.returncode, 0, "%s does not lower.\n%s" % (name, completed.stderr)
        )
        return json.loads(completed.stdout)


if __name__ == "__main__":
    unittest.main()

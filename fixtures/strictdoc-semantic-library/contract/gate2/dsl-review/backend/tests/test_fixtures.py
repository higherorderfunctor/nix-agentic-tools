"""Conformance harness for the semantic evaluator.

Every directory under ``backend/fixtures`` that holds a ``results.json`` is one
fixture. The harness evaluates it and compares the produced envelope against the
recorded one on normative fields only (contract.md:575-583), reporting each
fixture in its own subtest so one run names every mismatch.

Three conventions the contract does not state are implemented here because the
nested fixture tree needs them, and all three are recorded as open questions:

* Inputs resolve per file by nearest ancestor, from the fixture directory up to
  the packet directory, replacing rather than merging. contract.md:565-573
  describes one packet and says nothing about a nested tree, yet 42 of the 88
  fixtures ship no ``invocation.json`` of their own and inherit the packet
  binding, and six more inherit one from their model family.
* The bundle resolves the same way, with the packet bundle as the fallback.
  contract.md:565-573 describes one packet and says nothing about a tree
  carrying more than one model, so a family that authors its own model ships
  its own bundle beside it and every fixture that does not inherits the
  packet's.
* The prose ``reason`` inside evidence is not compared. contract.md:575-577
  makes the whole evidence object normative while contract.md:639 calls reason
  free text, and the corpus settles the conflict: the two exit-3 provider
  fixtures agree on every normative field and disagree on reason alone, so no
  single evaluator can satisfy both under whole-object comparison. Substituting
  a marker on both sides still requires reason to be present and nonempty.
"""

import contextlib
import difflib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

TESTS_DIRECTORY = pathlib.Path(__file__).resolve().parent
BACKEND_DIRECTORY = TESTS_DIRECTORY.parent
FIXTURES_DIRECTORY = BACKEND_DIRECTORY / "fixtures"
PACKET_DIRECTORY = BACKEND_DIRECTORY.parent

# The packet bundle, which the front-end test evaluates directly. Per-fixture
# evaluation resolves a bundle by nearest ancestor instead, so this path is the
# fallback every fixture outside an own-model family lands on.
BUNDLE_PATH = PACKET_DIRECTORY / "bundle.json"

if str(BACKEND_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIRECTORY))

from sdoc_semantics import evaluate  # noqa: E402  (needs the path entry above)

# Files that resolve by nearest ancestor. baseline.json is listed because the
# packet binding reads it with a relative path, so which copy the provider sees
# follows from which directory supplied the invocation configuration.
# bundle.json is listed because a family that authors its own model ships its
# own bundle, and every fixture that does not inherits the packet's.
RESOLVED_INPUT_NAMES = (
    "bundle.json",
    "candidate.json",
    "invocation.json",
    "baseline.json",
)

# The finding fields conformance compares (contract.md:575-577). message is
# absent on purpose: it is free text and comparison ignores it.
COMPARED_FINDING_KEYS = (
    "uid",
    "occurrence",
    "occurrenceIndex",
    "predicatePath",
    "kind",
    "status",
    "code",
    "evidence",
)

# The rule entry fields (contract.md:570-575).
COMPARED_ENTRY_KEYS = ("rule", "status", "causes", "findings")

# Stand-ins that keep a missing key visibly different from a null value and a
# present prose reason visibly different from an absent one.
ABSENT = "<absent>"
FREE_TEXT = "<free text>"

DIFF_LINE_LIMIT = 200


def type_name(value):
    """Name a decoded JSON value's type in the contract's vocabulary."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def brief(value, limit=120):
    """Render a value compactly for a one-line difference note."""
    try:
        text = json.dumps(value, sort_keys=True)
    except (TypeError, ValueError):
        text = repr(value)
    if len(text) > limit:
        text = text[: limit - 3] + "..."
    return text


def pointer_token(key):
    """Escape one JSON Pointer reference token (RFC 6901)."""
    return str(key).replace("~", "~0").replace("/", "~1")


def canonical_text(value):
    """Indent and key-sort a value so a textual diff shows shape, not order."""
    return json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False)


def read_json(path):
    """Decode one JSON file."""
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def discover(root):
    """Return every fixture directory under root, in stable path order.

    A directory is a fixture when it holds results.json. A family directory
    holds a case.md and no results.json, so it is only a container: the harness
    never treats one as a fixture and never reads a case.md.
    """
    root = pathlib.Path(root)
    found = [expectation.parent for expectation in root.rglob("results.json")]
    return sorted(found, key=lambda directory: directory.relative_to(root).parts)


def ancestor_chain(fixture_directory, packet_directory):
    """List the directories an input may come from, nearest first."""
    fixture_directory = pathlib.Path(fixture_directory).resolve()
    packet_directory = pathlib.Path(packet_directory).resolve()
    chain = [fixture_directory]
    current = fixture_directory
    while current != packet_directory and current != current.parent:
        current = current.parent
        chain.append(current)
    return chain


def resolve_inputs(fixture_directory, packet_directory):
    """Map each input file name to the nearest ancestor copy, or None.

    Resolution is per file and replaces rather than merges, which is what lets
    missing-before-or-baseline-acquisition-cannot-evaluate assert the
    missing-binding execution error of contract.md:525 with its empty inputs
    object while still inheriting the packet candidate shape elsewhere.
    """
    chain = ancestor_chain(fixture_directory, packet_directory)
    resolved = {}
    for name in RESOLVED_INPUT_NAMES:
        resolved[name] = next(
            (directory / name for directory in chain if (directory / name).is_file()),
            None,
        )
    return resolved


@contextlib.contextmanager
def provider_residue_removed(working_directory):
    """Drop files a provider wrote into the fixture tree during one evaluation.

    One fixture's provider writes a marker file into its own working directory
    to distinguish a first invocation from a later one, so a second run of the
    suite would otherwise read the marker left by the first and see a different
    snapshot. Only entries that appear during the evaluation are removed, only
    inside the fixtures tree, so no authored fixture file is ever touched.
    """
    watched = None
    if working_directory is not None:
        candidate = pathlib.Path(working_directory).resolve()
        if candidate.is_dir() and candidate.is_relative_to(FIXTURES_DIRECTORY):
            watched = candidate
    before = set(watched.iterdir()) if watched is not None else set()
    try:
        yield
    finally:
        if watched is not None:
            for entry in watched.iterdir():
                if entry in before:
                    continue
                if entry.is_dir() and not entry.is_symlink():
                    shutil.rmtree(entry, ignore_errors=True)
                else:
                    with contextlib.suppress(OSError):
                        entry.unlink()


def normative_evidence(evidence):
    """Keep evidence whole except for its prose reason (contract.md:639).

    Substituting a marker for a nonempty string keeps the presence and the type
    of reason under comparison while leaving its wording free, which is the only
    reading under which the corpus is satisfiable at all: the two exit-3
    provider fixtures differ in reason and in nothing else.
    """
    if not isinstance(evidence, dict) or "reason" not in evidence:
        return evidence
    reason = evidence["reason"]
    usable = isinstance(reason, str) and reason.strip() != ""
    return {**evidence, "reason": FREE_TEXT if usable else reason}


def normative_finding(finding):
    """Reduce one finding to the fields conformance compares."""
    if not isinstance(finding, dict):
        return finding
    kept = {key: finding.get(key, ABSENT) for key in COMPARED_FINDING_KEYS}
    kept["evidence"] = normative_evidence(kept["evidence"])
    return kept


def normative_findings(findings):
    """Reduce a findings array, preserving its order (contract.md:579-583)."""
    if not isinstance(findings, list):
        return findings
    return [normative_finding(finding) for finding in findings]


def normative_entry(entry):
    """Reduce one rule entry to rule, status, causes and findings."""
    if not isinstance(entry, dict):
        return entry
    kept = {key: entry.get(key, ABSENT) for key in COMPARED_ENTRY_KEYS}
    kept["findings"] = normative_findings(kept["findings"])
    return kept


def normative(envelope):
    """Reduce an envelope to its normative content.

    status, causes and the listed finding fields are normative by
    contract.md:575-577. baseline and evaluation are compared because the
    contract fixes both values (contract.md:567-570) even though it never names
    the compared envelope fields. expected is excluded because the two sides are
    required to disagree on it (contract.md:566-567).
    """
    if not isinstance(envelope, dict):
        return {"envelope": f"expected an object, found {type_name(envelope)}"}
    entries = envelope.get("results", ABSENT)
    return {
        "evaluation": envelope.get("evaluation", ABSENT),
        "baseline": envelope.get("baseline", ABSENT),
        "status": envelope.get("status", ABSENT),
        "findings": normative_findings(envelope.get("findings", ABSENT)),
        "results": (
            [normative_entry(entry) for entry in entries]
            if isinstance(entries, list)
            else entries
        ),
    }


def first_difference(expected, actual, pointer=""):
    """Return (JSON Pointer, note) for the first divergence, or None.

    Object member order is insignificant and array order is significant
    (contract.md:578-579), so members are visited in sorted key order and array
    items by index.
    """
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return (pointer, f"expected an object, found {type_name(actual)}")
        for key in sorted(set(expected) | set(actual)):
            child = f"{pointer}/{pointer_token(key)}"
            if key not in actual:
                return (child, f"expected {brief(expected[key])}, but the key is absent")
            if key not in expected:
                return (child, f"unexpected key holding {brief(actual[key])}")
            found = first_difference(expected[key], actual[key], child)
            if found is not None:
                return found
        return None
    if isinstance(expected, list):
        if not isinstance(actual, list):
            return (pointer, f"expected an array, found {type_name(actual)}")
        if len(expected) != len(actual):
            return (
                pointer,
                f"expected {len(expected)} items, found {len(actual)}",
            )
        for index, (one, other) in enumerate(zip(expected, actual)):
            found = first_difference(one, other, f"{pointer}/{index}")
            if found is not None:
                return found
        return None
    if type_name(expected) != type_name(actual) or expected != actual:
        return (pointer, f"expected {brief(expected)}, found {brief(actual)}")
    return None


def describe_difference(expected, actual):
    """Describe how two normative envelopes differ, or None when they agree.

    The message names the first divergence by JSON Pointer into the envelope and
    then shows a unified diff of both sides normalized and indented, so the
    reader sees the shape rather than a wall of repr output.
    """
    found = first_difference(expected, actual)
    if found is None:
        return None
    pointer, note = found
    lines = [
        f"First divergence at {pointer or '/'}: {note}",
        "",
        "Unified diff of the normative envelopes (expected, then produced):",
    ]
    # The arguments to difflib.unified_diff, in order: the two lists of lines,
    # the two labels, two unused timestamps, three lines of context, and an
    # empty line ending because splitlines already removed the newlines.
    diff = list(
        difflib.unified_diff(
            canonical_text(expected).splitlines(),
            canonical_text(actual).splitlines(),
            "expected",
            "produced",
            "",
            "",
            3,
            "",
        )
    )
    if len(diff) > DIFF_LINE_LIMIT:
        omitted = len(diff) - DIFF_LINE_LIMIT
        diff = diff[:DIFF_LINE_LIMIT] + [f"... {omitted} further diff lines omitted"]
    lines.extend(diff)
    return "\n".join(lines)


def evaluate_fixture(resolved, evaluation):
    """Evaluate one resolved fixture and return the produced envelope.

    The provider working directory follows from the invocation path the
    evaluator is given, which is the directory that supplied the resolved
    invocation configuration (contract.md:515-517). That is the fixture
    directory for the 40 fixtures shipping one, the family directory for the six
    that inherit one from their model family, and the packet directory for the
    other 42, which is what makes the packet binding's relative baseline.json
    resolve for all three.
    """
    invocation_path = resolved["invocation.json"]
    with provider_residue_removed(
        invocation_path.parent if invocation_path is not None else None
    ):
        return evaluate(
            bundle_path=str(resolved["bundle.json"]),
            candidate_path=str(resolved["candidate.json"]),
            invocation_path=str(invocation_path) if invocation_path is not None else None,
            evaluation=evaluation,
        )


class FixtureConformance(unittest.TestCase):
    """Compares the evaluator against the recorded corpus."""

    def test_each_fixture_matches_its_recorded_envelope(self):
        fixtures = discover(FIXTURES_DIRECTORY)
        self.assertTrue(
            fixtures,
            f"No fixture directory holds a results.json under {FIXTURES_DIRECTORY}.",
        )
        for fixture_directory in fixtures:
            name = str(fixture_directory.relative_to(FIXTURES_DIRECTORY))
            with self.subTest(fixture=name):
                recorded = read_json(fixture_directory / "results.json")
                resolved = resolve_inputs(fixture_directory, PACKET_DIRECTORY)
                self.assertIsNotNone(
                    resolved["candidate.json"],
                    f"{name} resolves no candidate.json from itself or any ancestor.",
                )
                self.assertIsNotNone(
                    resolved["bundle.json"],
                    f"{name} resolves no bundle.json from itself or any ancestor.",
                )
                produced = evaluate_fixture(resolved, recorded.get("evaluation"))
                difference = describe_difference(
                    normative(recorded), normative(produced)
                )
                if difference is not None:
                    self.fail(f"{name} does not conform.\n{difference}")

    def test_command_line_writes_an_envelope_for_the_packet(self):
        """Prove the front end and its output file work, not just the library."""
        recorded = read_json(PACKET_DIRECTORY / "results.json")
        environment = dict(os.environ)
        environment["PYTHONPATH"] = os.pathsep.join(
            [str(BACKEND_DIRECTORY), environment.get("PYTHONPATH", "")]
        ).rstrip(os.pathsep)
        with tempfile.TemporaryDirectory() as output_directory:
            output_path = pathlib.Path(output_directory) / "envelope.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "sdoc_semantics",
                    "evaluate",
                    "--bundle",
                    str(BUNDLE_PATH),
                    "--candidate",
                    str(PACKET_DIRECTORY / "candidate.json"),
                    "--invocation",
                    str(PACKET_DIRECTORY / "invocation.json"),
                    "--out",
                    str(output_path),
                    "--evaluation",
                    recorded["evaluation"],
                ],
                cwd=str(BACKEND_DIRECTORY),
                env=environment,
                capture_output=True,
                text=True,
                timeout=120,
                check=False,
            )
            self.assertEqual(
                completed.returncode,
                0,
                "The packet envelope is satisfied, so the front end must exit 0.\n"
                f"stdout: {completed.stdout}\nstderr: {completed.stderr}",
            )
            self.assertTrue(
                output_path.is_file(),
                f"The front end wrote no file at --out.\nstderr: {completed.stderr}",
            )
            produced = read_json(output_path)
        difference = describe_difference(normative(recorded), normative(produced))
        if difference is not None:
            self.fail(f"The packet envelope does not conform.\n{difference}")

    def test_the_evaluator_marks_its_envelope_as_an_actual_response(self):
        """expected is true in every recorded file and false in a response.

        contract.md:566-567 requires exactly this asymmetry, which is why
        expected is excluded from the per-fixture comparison. Asserting it once
        here keeps the requirement tested rather than merely skipped.
        """
        for fixture_directory in discover(FIXTURES_DIRECTORY):
            name = str(fixture_directory.relative_to(FIXTURES_DIRECTORY))
            recorded = read_json(fixture_directory / "results.json")
            self.assertIs(
                recorded.get("expected"),
                True,
                f"{name} is a handwritten expectation, so expected must be true.",
            )
        resolved = resolve_inputs(PACKET_DIRECTORY, PACKET_DIRECTORY)
        produced = evaluate_fixture(resolved, "harness-expected-flag-probe")
        self.assertIs(
            produced.get("expected"),
            False,
            "An evaluator response must carry expected false.",
        )


if __name__ == "__main__":
    unittest.main()

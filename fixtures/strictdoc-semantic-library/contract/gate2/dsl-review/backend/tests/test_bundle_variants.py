"""Bundle-level and provider-level conformance the fixture corpus cannot hold.

A fixture holds a candidate, invocation bindings and a baseline snapshot, and
the bundle it is evaluated against is authored once per model family, so a
fixture can vary the inputs to one settled bundle and nothing else. The
contract also constrains the bundle itself — duplicate rule identities
(contract.md:860-861), the external input list (contract.md:496-531), the
declaration ids a view's policy names (contract.md:853-856), and the
prerequisite set a leaf earns (contract.md:733-748) — and it constrains what a
provider may return (contract.md:494-495).

Each test here copies the packet configuration into a temporary directory,
applies one mutation, and evaluates. Every class carries its own positive
control, which proves the copying and the temporary provider bindings are
sound, so a refusal from a mutated copy is the mutation and not the plumbing.
"""

import copy
import json
import pathlib
import sys
import tempfile
import unittest

TESTS_DIRECTORY = pathlib.Path(__file__).resolve().parent
BACKEND_DIRECTORY = TESTS_DIRECTORY.parent
PACKET_DIRECTORY = BACKEND_DIRECTORY.parent

if str(BACKEND_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIRECTORY))

from sdoc_semantics import evaluate  # noqa: E402  (needs the path entry above)
from sdoc_semantics import loading  # noqa: E402

BASELINE_INPUT = "model:reference/input:baseline"
SECOND_INPUT = "model:reference/input:second"
PRESERVE_RULE = "model:reference/check:baseline-preserved"
TARGET_TYPE_RULE = "model:reference/element:FOO/relation:parent:H/check:H.target-type"
REFERENCE_RULE = "model:reference/element:FOO/relation:parent:R/check:R.all"
ENDPOINT_PATH_RULE = "model:reference/element:BAR/check:endpoint-path"
LOWER_COUNT_RULE = "model:reference/element:BAR/check:one-Q"

# An occurrences rule whose owner element is BAR, which declares UID alone. It
# is the only way to name a field the owner of an occurrence does not declare.
LOWER_ENDPOINT_RULE = (
    "model:reference/element:BAR/relation:parent:P/check:P.target-type"
)
FOREST_RULE = "model:reference/check:H-forest"

# A records rule on FOO that nothing lists as a prerequisite, so its check may
# be replaced with a field-value leaf without disturbing the dependency graph.
RECORD_RULE = "model:reference/element:FOO/check:one-H-parent"

# The one FOO record carrying FLAG true; every other carries false.
CLOSED_RECORD = "F2"

# The packet baseline identity, which the packet binding's snapshot carries.
PACKET_IDENTITY = "baseline-I0-open"

# A second complete snapshot, for the two-input bundle. It protects nothing, so
# it cannot change any rule's verdict (contract.md:526-528).
SECOND_SNAPSHOT = {
    "model": "reference",
    "identity": "second-snapshot-protects-nothing",
    "complete": True,
    "records": [],
}


def read_json(path):
    """Decode one JSON file."""
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def write_json(directory, name, value):
    """Write one JSON file into a temporary directory and return its path."""
    path = pathlib.Path(directory) / name
    path.write_text(json.dumps(value, indent=2), encoding="utf-8")
    return path


def rule_named(bundle, rule_id):
    """The one rule of a decoded bundle document carrying an id."""
    for rule in bundle["bundle"]["rules"]:
        if rule["id"] == rule_id:
            return rule
    raise AssertionError("the packet bundle declares no rule " + rule_id)


def visibility_view(bundle):
    """The one origin-sensitive visibility view of a decoded bundle."""
    for view in bundle["bundle"]["views"]:
        if view["config"]["contract"] == "origin-sensitive-visibility/v1":
            return view
    raise AssertionError("the packet bundle declares no visibility view")


def entry_named(envelope, rule_id):
    """The one result entry for a rule id."""
    for entry in envelope["results"]:
        if entry["rule"] == rule_id:
            return entry
    raise AssertionError("the envelope carries no entry for " + rule_id)


class BundleVariants(unittest.TestCase):
    """Evaluates mutated copies of the packet bundle."""

    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.directory = pathlib.Path(self.workspace.name)
        self.bundle = read_json(PACKET_DIRECTORY / "bundle.json")
        self.invocation = read_json(PACKET_DIRECTORY / "invocation.json")
        self.write("baseline.json", read_json(PACKET_DIRECTORY / "baseline.json"))

    def write(self, name, value):
        """Write one JSON file into the temporary directory."""
        return write_json(self.directory, name, value)

    def run_bundle(self, evaluation):
        """Evaluate the current mutated bundle against the packet candidate."""
        bundle_path = self.write("bundle.json", self.bundle)
        invocation_path = self.write("invocation.json", self.invocation)
        return evaluate(
            bundle_path=str(bundle_path),
            candidate_path=str(PACKET_DIRECTORY / "candidate.json"),
            invocation_path=str(invocation_path),
            evaluation=evaluation,
        )

    def refuse_bundle(self, evaluation):
        """Evaluate and return the configuration error message."""
        with self.assertRaises(loading.ConfigurationError) as caught:
            self.run_bundle(evaluation)
        return str(caught.exception)

    # -- positive control ---------------------------------------------------

    def test_the_unchanged_copy_still_conforms(self):
        """The copy and its bindings reproduce the packet envelope."""
        envelope = self.run_bundle("unchanged-copy-control")
        self.assertEqual(envelope["status"], "satisfied")
        self.assertEqual(envelope["baseline"], PACKET_IDENTITY)
        self.assertEqual(
            len(envelope["results"]), len(self.bundle["bundle"]["rules"])
        )

    # -- duplicate rule identities (contract.md:860-861) --------------------

    def test_identical_duplicate_rule_definitions_merge_origins(self):
        """One id defined twice identically is one rule carrying both origins.

        contract.md:860-861 merges origins and throws only on a conflicting
        identity, and contract.md:570-573 requires exactly one result entry per
        bundle rule, so the duplicate must never reach scheduling as a second
        rule and must never abort the run.
        """
        twin = copy.deepcopy(rule_named(self.bundle, TARGET_TYPE_RULE))
        twin["origins"] = ["contribution:extra"]
        self.bundle["bundle"]["rules"].append(twin)
        envelope = self.run_bundle("duplicate-rule-identity-merges")
        self.assertEqual(envelope["status"], "satisfied")
        entries = [
            entry["rule"]
            for entry in envelope["results"]
            if entry["rule"] == TARGET_TYPE_RULE
        ]
        self.assertEqual(entries, [TARGET_TYPE_RULE])
        merged = loading.load_bundle(str(self.directory / "bundle.json"))
        kept = [
            rule for rule in merged["index"]["rules"] if rule["id"] == TARGET_TYPE_RULE
        ]
        self.assertEqual(len(kept), 1)
        self.assertIn("contribution:extra", kept[0]["origins"])

    def test_a_conflicting_duplicate_rule_identity_throws(self):
        """A second definition that differs is refused (contract.md:861)."""
        twin = copy.deepcopy(rule_named(self.bundle, TARGET_TYPE_RULE))
        twin["requires"] = [FOREST_RULE]
        self.bundle["bundle"]["rules"].append(twin)
        self.assertIn("conflicts on", self.refuse_bundle("conflicting-duplicate"))

    # -- more than one external input (contract.md:500-531) -----------------

    def test_a_bundle_may_declare_more_than_one_external_input(self):
        """Two declared inputs are both bound, and both are captured.

        contract.md:519 binds each external input id and contract.md:502-508
        keys the bindings by input id, both plural. The envelope's single
        `baseline` field constrains what is reported, not how many inputs the
        bundle may declare, and the reported identity is the one a preserve
        leaf names (contract.md:245, contract.md:569-570).
        """
        declaration = copy.deepcopy(self.bundle["bundle"]["inputs"][0])
        declaration["id"] = SECOND_INPUT
        declaration["name"] = "second"
        self.bundle["bundle"]["inputs"].append(declaration)
        self.write("second.json", SECOND_SNAPSHOT)
        self.invocation["inputs"][SECOND_INPUT] = {
            "command": ["cat", "second.json"],
            "timeoutSeconds": 10,
        }
        envelope = self.run_bundle("two-external-inputs")
        self.assertEqual(envelope["status"], "satisfied")
        self.assertEqual(envelope["baseline"], PACKET_IDENTITY)
        self.assertEqual(envelope["findings"], [])

    # -- a required input no rule consumes (contract.md:496-498) -----------

    def test_a_required_input_no_rule_consumes_is_still_captured(self):
        """Dropping the consuming rule must not skip the capture.

        contract.md:519 binds each declared input and contract.md:496-498
        requires a successful capture for `required: true`, so the identity
        still reaches the envelope (contract.md:569-570) with no rule reading
        the snapshot.
        """
        self.bundle["bundle"]["rules"] = [
            rule
            for rule in self.bundle["bundle"]["rules"]
            if rule["id"] != PRESERVE_RULE
        ]
        envelope = self.run_bundle("unconsumed-required-input-captured")
        self.assertEqual(envelope["baseline"], PACKET_IDENTITY)
        self.assertEqual(envelope["status"], "satisfied")
        self.assertEqual(envelope["findings"], [])

    def test_a_required_input_no_rule_consumes_reports_a_failed_capture(self):
        """A missing binding is an execution error even with no reader.

        contract.md:525 makes a missing command binding an execution error,
        and contract.md:496-498 requires the capture to succeed. No rule
        declares the input, so no rule can carry that error
        (contract.md:523-525) and it belongs at envelope level instead
        (contract.md:661-663, contract.md:817). Left unreported the envelope
        would stay satisfied and the candidate would be accepted
        (contract.md:665).
        """
        self.bundle["bundle"]["rules"] = [
            rule
            for rule in self.bundle["bundle"]["rules"]
            if rule["id"] != PRESERVE_RULE
        ]
        self.invocation["inputs"] = {}
        envelope = self.run_bundle("unconsumed-required-input-failed")
        self.assertEqual(envelope["status"], "error")
        self.assertEqual(envelope["baseline"], None)
        self.assertEqual(len(envelope["findings"]), 1)
        finding = envelope["findings"][0]
        self.assertEqual(finding["status"], "error")
        self.assertEqual(finding["code"], "execution")
        self.assertIsNone(finding["uid"])
        self.assertIsNone(finding["occurrence"])
        self.assertIsNone(finding["predicatePath"])
        self.assertIsNone(finding["kind"])
        self.assertEqual(finding["evidence"]["input"], BASELINE_INPUT)

    # -- declaration ids a visibility policy names (contract.md:853-856) ---

    def test_an_unknown_closed_field_is_a_configuration_error(self):
        """`closedWhenTrue` is a field declaration id and must resolve.

        Unresolved, it reached the visibility walk and produced a blocked
        `input` leaf whose evidence named a null field on a real record — a
        fabricated field diagnostic inside normative evidence, where
        contract.md:816 wants a configuration failure.
        """
        policy = visibility_view(self.bundle)["config"]["policy"]
        policy["closedWhenTrue"] = "model:reference/element:FOO/field:NOPE"
        self.assertIn(
            "closedWhenTrue", self.refuse_bundle("unknown-closed-field")
        )

    def test_an_unknown_hierarchy_view_is_a_configuration_error(self):
        """`hierarchy` is a view id and resolves in bundle.views.

        Unresolved, it reached the leaf and aborted the run with no envelope
        at all rather than the configuration failure of contract.md:816.
        """
        visibility_view(self.bundle)["config"]["hierarchy"] = (
            "model:reference/view:NOPE"
        )
        self.assertIn("hierarchy", self.refuse_bundle("unknown-hierarchy-view"))

    def test_a_hierarchy_that_is_not_a_forest_is_a_configuration_error(self):
        """The visibility walk reads a selected forest (contract.md:298-301)."""
        view = visibility_view(self.bundle)
        view["config"]["hierarchy"] = view["id"]
        self.assertIn(
            "not a selected forest", self.refuse_bundle("hierarchy-not-a-forest")
        )

    # -- the prerequisite set a leaf earns (contract.md:733-748) -----------

    def test_a_missing_forest_prerequisite_is_a_configuration_error(self):
        """visible-target requires its hierarchy's forest-validity rule.

        contract.md:738-740 states the requirement and refuses a missing
        prerequisite rather than inventing a check. Without the edge the
        evaluator walked an invalid forest and returned a substantive
        `no-shared-root` verdict off a hierarchy contract.md:300-301 calls
        unusable, instead of blocking (contract.md:749-753).
        """
        rule_named(self.bundle, REFERENCE_RULE)["requires"] = []
        message = self.refuse_bundle("missing-forest-prerequisite")
        self.assertIn(REFERENCE_RULE, message)
        self.assertIn(FOREST_RULE, message)

    def test_a_missing_endpoint_count_prerequisite_is_a_configuration_error(self):
        """Each endpoint selector requires its own count rule.

        contract.md:733-736 requires exactly one standalone count rule per
        endpoint, comparing eq to 1 on the same element.
        """
        rule = rule_named(self.bundle, ENDPOINT_PATH_RULE)
        rule["requires"] = [
            required for required in rule["requires"] if required != LOWER_COUNT_RULE
        ]
        message = self.refuse_bundle("missing-endpoint-count-prerequisite")
        self.assertIn(ENDPOINT_PATH_RULE, message)
        self.assertIn(LOWER_COUNT_RULE, message)

    def test_an_ambiguous_endpoint_count_prerequisite_is_a_configuration_error(self):
        """Two matching count rules throw naming the endpoint.

        contract.md:736 and contract.md:748 both say more than one match
        throws, so the evaluator may not pick one.
        """
        twin = copy.deepcopy(rule_named(self.bundle, LOWER_COUNT_RULE))
        twin["id"] = "model:reference/element:BAR/check:one-Q-again"
        twin["name"] = "one-Q-again"
        self.bundle["bundle"]["rules"].append(twin)
        message = self.refuse_bundle("ambiguous-endpoint-count-prerequisite")
        self.assertIn("lower endpoint", message)
        self.assertIn("2 rules match", message)

    def test_a_forest_prerequisite_under_any_does_not_establish_its_fact(self):
        """A satisfied `any` does not establish the forest leaf's fact.

        contract.md:745-747 admits a forest prerequisite leaf standalone or
        under `all` operators only, so wrapping it in `any` leaves the
        dependent rules with no usable match.
        """
        rule = rule_named(self.bundle, FOREST_RULE)
        rule["check"] = {"any": [copy.deepcopy(rule["check"])]}
        message = self.refuse_bundle("forest-prerequisite-under-any")
        self.assertIn("forest validity", message)
        self.assertIn("0 rules match", message)

    # -- the field-value leaf (contract.md:237-252, contract.md:826-846) ----

    def field_value_leaf(self, **overrides):
        """A field-value leaf over the packet's FLAG field."""
        leaf = {
            "absentSatisfies": False,
            "field": "FLAG",
            "kind": "field-value",
            "subject": "record",
            "values": ["false"],
        }
        leaf.update(overrides)
        return leaf

    def replace_check(self, rule_id, **overrides):
        """Put a field-value leaf in place of one rule's whole check."""
        rule_named(self.bundle, rule_id)["check"] = self.field_value_leaf(**overrides)

    def test_a_field_value_leaf_reads_the_selected_record_s_field(self):
        """The positive control for every refusal below.

        The packet corpus never carries a field-value leaf, so a bundle that
        merely refuses one proves nothing about the refusal being the mutation.
        This admits FLAG false alone over the FOO records, and F2 is the one
        FOO carrying true, so the leaf must violate on F2 and on no other
        record.
        """
        self.replace_check(RECORD_RULE)
        envelope = self.run_bundle("field-value-reads-a-record-field")
        entry = entry_named(envelope, RECORD_RULE)
        self.assertEqual(entry["status"], "violated")
        self.assertEqual(
            [
                finding["uid"]
                for finding in entry["findings"]
                if finding["status"] == "violated"
            ],
            [CLOSED_RECORD],
        )
        offending = next(
            finding for finding in entry["findings"] if finding["uid"] == CLOSED_RECORD
        )
        self.assertEqual(offending["kind"], "field-value")
        self.assertEqual(offending["code"], "field-value")
        self.assertEqual(
            offending["evidence"],
            {
                "absentSatisfies": False,
                "expected": ["false"],
                "field": "FLAG",
                "present": True,
                "record": CLOSED_RECORD,
                "values": ["true"],
            },
        )

    def test_a_field_value_leaf_under_a_model_selector_is_refused(self):
        """Only a records or an occurrences selector binds a record."""
        self.replace_check(FOREST_RULE)
        message = self.refuse_bundle("field-value-under-a-model-selector")
        self.assertIn("not valid under a model selector", message)

    def test_a_record_subject_under_an_occurrences_selector_is_refused(self):
        """An occurrences selector binds the owner and the target, not record."""
        self.replace_check(TARGET_TYPE_RULE, subject="record")
        message = self.refuse_bundle("field-value-record-subject-in-occurrences")
        self.assertIn("names the subject record", message)
        self.assertIn("occurrences selector does not bind", message)

    def test_a_target_subject_under_a_records_selector_is_refused(self):
        """A records selector binds one record and no occurrence endpoint."""
        self.replace_check(RECORD_RULE, subject="target")
        message = self.refuse_bundle("field-value-target-subject-in-records")
        self.assertIn("names the subject target", message)
        self.assertIn("records selector does not bind", message)

    def test_a_field_the_selected_element_does_not_declare_is_refused(self):
        """A records selector fixes the element, so the name resolves at load.

        The packet declares FLAG on FOO alone, so naming it under the BAR
        records rule is a configuration failure rather than a leaf that blocks
        on every BAR at evaluation.
        """
        self.replace_check(LOWER_COUNT_RULE)
        message = self.refuse_bundle("field-value-field-not-on-the-element")
        self.assertIn("names the field FLAG", message)
        self.assertIn("BAR does not declare", message)

    def test_an_owner_subject_field_the_owner_does_not_declare_is_refused(self):
        """An occurrences selector fixes the owner, so the owner resolves too.

        The refusal is the point. Before it, this bundle loaded and then
        blocked every P occurrence at evaluation, reporting a model
        configuration fault as an unevaluable candidate: envelope status
        blocked, no envelope finding, empty causes. BAR owns P and declares
        UID alone, so FLAG on the owner is refused at load exactly as it is
        under a records selector.
        """
        self.replace_check(LOWER_ENDPOINT_RULE, subject="owner")
        message = self.refuse_bundle("field-value-owner-field-not-on-the-owner")
        self.assertIn("names the field FLAG", message)
        self.assertIn("BAR does not declare", message)

    def test_a_field_no_element_declares_is_refused(self):
        """An occurrences selector still requires the name to exist."""
        self.replace_check(TARGET_TYPE_RULE, field="NOPE", subject="target")
        message = self.refuse_bundle("field-value-undeclared-field-name")
        self.assertIn("names the undeclared field NOPE", message)

    def test_an_empty_value_list_is_refused(self):
        """A leaf admitting nothing would violate unconditionally."""
        self.replace_check(RECORD_RULE, values=[])
        message = self.refuse_bundle("field-value-with-no-values")
        self.assertIn("needs at least one value", message)

    def test_a_quoted_absent_satisfies_is_refused(self):
        """absentSatisfies is a JSON boolean, not a quoted string."""
        self.replace_check(RECORD_RULE, absentSatisfies="false")
        message = self.refuse_bundle("field-value-with-a-quoted-flag")
        self.assertIn("absentSatisfies keyword rejects", message)


class FieldValueBlocking(unittest.TestCase):
    """The three ways a field-value leaf blocks, which no fixture reaches.

    The note-state-field family exercises the leaf's satisfied and violated
    arms and by design cannot reach the blocked ones: its one element declares
    the field for every subject, its field is optional so no absence is an
    input error, and every occurrence target resolves. Each test here puts a
    field-value leaf over the packet's H occurrences, reading the target's
    FLAG, and mutates the one candidate record that target names.

    The assertions are as much about ``causes`` as about the leaf. A blocked
    leaf earns its cause from ``evidence.record`` and ``evidence.field``, or
    from the finding's own occurrence, so a leaf that reuses those two evidence
    names is cited correctly with no engine change at all.
    """

    TARGET_FLAG_LEAF = {
        "absentSatisfies": False,
        "field": "FLAG",
        "kind": "field-value",
        "subject": "target",
        "values": ["false"],
    }

    # The first H occurrence of F1, whose target the tests below change.
    OWNER = "F1"
    OCCURRENCE_INDEX = 0

    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.directory = pathlib.Path(self.workspace.name)
        self.bundle = read_json(PACKET_DIRECTORY / "bundle.json")
        rule_named(self.bundle, TARGET_TYPE_RULE)["check"] = copy.deepcopy(
            self.TARGET_FLAG_LEAF
        )
        self.candidate = read_json(PACKET_DIRECTORY / "candidate.json")
        write_json(
            self.directory, "baseline.json", read_json(PACKET_DIRECTORY / "baseline.json")
        )
        write_json(
            self.directory,
            "invocation.json",
            read_json(PACKET_DIRECTORY / "invocation.json"),
        )

    def record_named(self, uid):
        """The one candidate record carrying a uid."""
        for record in self.candidate["records"]:
            if record["uid"] == uid:
                return record
        raise AssertionError("the packet candidate holds no record " + uid)

    def point_at(self, uid):
        """Point F1's first H occurrence at another uid."""
        self.record_named(self.OWNER)["relations"][self.OCCURRENCE_INDEX][
            "target"
        ] = uid

    def run_candidate(self, evaluation):
        """Evaluate the field-value bundle against the mutated candidate."""
        return evaluate(
            bundle_path=str(write_json(self.directory, "bundle.json", self.bundle)),
            candidate_path=str(
                write_json(self.directory, "candidate.json", self.candidate)
            ),
            invocation_path=str(self.directory / "invocation.json"),
            evaluation=evaluation,
        )

    def blocked_findings(self, envelope, owners):
        """The field-value entry and its blocked findings, owners asserted.

        ``owners`` is every occurrence owner whose target the mutation made
        unreadable, so a mutation that reaches more than one occurrence has to
        name them all rather than pass on the first.
        """
        entry = entry_named(envelope, TARGET_TYPE_RULE)
        self.assertEqual(entry["status"], "blocked")
        blocked = [
            finding
            for finding in entry["findings"]
            if finding["status"] == "blocked"
        ]
        self.assertEqual([finding["uid"] for finding in blocked], owners)
        for finding in blocked:
            self.assertEqual(finding["kind"], "field-value")
            self.assertEqual(finding["occurrenceIndex"], self.OCCURRENCE_INDEX)
        return entry, blocked

    def test_the_leaf_reads_the_target_record_s_field(self):
        """The positive control: with no mutation, the leaf reads each H target.

        F2 is the one FOO carrying FLAG true, so the two occurrences naming it
        violate and every other satisfies. Nothing blocks.
        """
        envelope = self.run_candidate("field-value-target-control")
        entry = entry_named(envelope, TARGET_TYPE_RULE)
        self.assertEqual(entry["status"], "violated")
        self.assertEqual(entry["causes"], [])
        self.assertEqual(
            [
                (finding["uid"], finding["status"])
                for finding in entry["findings"]
                if finding["status"] != "satisfied"
            ],
            [("F2a", "violated"), ("F2b", "violated")],
        )

    def test_an_unresolved_target_blocks_and_cites_its_occurrence(self):
        """An unresolved subject uid blocks with code unresolved-target."""
        self.point_at("GONE")
        envelope = self.run_candidate("field-value-unresolved-target")
        entry, (blocked,) = self.blocked_findings(envelope, [self.OWNER])
        self.assertEqual(blocked["code"], "unresolved-target")
        self.assertIsNone(blocked["evidence"]["record"])
        self.assertEqual(blocked["evidence"]["present"], False)
        self.assertEqual(blocked["evidence"]["values"], [])
        self.assertEqual(len(entry["causes"]), 1)
        cited = self.finding_at(envelope, entry["causes"][0])
        self.assertEqual(cited["code"], "unresolved-target")
        self.assertEqual(cited["uid"], self.OWNER)
        self.assertEqual(cited["occurrenceIndex"], self.OCCURRENCE_INDEX)

    def test_a_target_element_without_the_field_blocks_with_no_cause(self):
        """No envelope finding describes a field an element never declares.

        BAZ declares UID alone, so native field validation never reports FLAG
        on Z0 and there is nothing for the entry to cite. contract.md:680-683
        allows exactly that: a subject-local block with no envelope finding
        behind it leaves the entry blocked with empty causes.
        """
        self.point_at("Z0")
        envelope = self.run_candidate("field-value-target-without-the-field")
        entry, (blocked,) = self.blocked_findings(envelope, [self.OWNER])
        self.assertEqual(blocked["code"], "input")
        self.assertEqual(blocked["evidence"]["record"], "Z0")
        self.assertEqual(
            blocked["evidence"]["reason"], "The BAZ record Z0 has no FLAG field."
        )
        self.assertEqual(entry["causes"], [])

    def test_an_unusable_target_value_blocks_and_repeats_its_reason(self):
        """A refused native value blocks with the envelope finding's own words.

        The leaf never decides what is unusable: a scalar field carrying two
        values is already an envelope input error (contract.md:298-302), so the
        leaf reports blocked, repeats that finding's reason and cites it. F1
        and F2 both name F0 as their H parent, so two leaves block on one
        refused value and the entry cites that one finding once.
        """
        self.record_named("F0")["fields"]["FLAG"] = ["true", "false"]
        envelope = self.run_candidate("field-value-unusable-target-value")
        entry, blocked = self.blocked_findings(envelope, ["F1", "F2"])
        for finding in blocked:
            self.assertEqual(finding["code"], "input")
            self.assertEqual(finding["evidence"]["record"], "F0")
            self.assertEqual(finding["evidence"]["values"], ["true", "false"])
        self.assertEqual(len(entry["causes"]), 1)
        cited = self.finding_at(envelope, entry["causes"][0])
        self.assertEqual(cited["code"], "input")
        self.assertEqual(cited["uid"], "F0")
        self.assertEqual(cited["evidence"]["field"], "FLAG")
        self.assertEqual(
            cited["evidence"]["reason"], blocked[0]["evidence"]["reason"]
        )

    def finding_at(self, envelope, pointer):
        """The envelope finding one /findings/N cause names."""
        prefix = "/findings/"
        self.assertTrue(pointer.startswith(prefix), pointer)
        return envelope["findings"][int(pointer[len(prefix) :])]


class BaselineDeclarationNames(unittest.TestCase):
    """A captured snapshot resolves its declaration names.

    contract.md:494-495 requires a snapshot's declaration names, unique uids
    and UID consistency to be valid. Only missing or invalid semantic field
    VALUES are exempt from repair (contract.md:492-494). An undeclared name is
    therefore an invalid snapshot, so acquisition fails and every rule
    declaring that input reports error (contract.md:523-525) rather than
    turning the undeclared name into a preserve difference.
    """

    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.directory = pathlib.Path(self.workspace.name)
        (self.directory / "invocation.json").write_text(
            json.dumps(
                {
                    "inputs": {
                        BASELINE_INPUT: {
                            "command": ["cat", "baseline.json"],
                            "timeoutSeconds": 10,
                        }
                    }
                }
            ),
            encoding="utf-8",
        )

    def run_snapshot(self, records, identity, evaluation):
        """Evaluate the packet bundle against a handwritten snapshot."""
        (self.directory / "baseline.json").write_text(
            json.dumps(
                {
                    "model": "reference",
                    "identity": identity,
                    "complete": True,
                    "records": records,
                }
            ),
            encoding="utf-8",
        )
        return evaluate(
            bundle_path=str(PACKET_DIRECTORY / "bundle.json"),
            candidate_path=str(PACKET_DIRECTORY / "candidate.json"),
            invocation_path=str(self.directory / "invocation.json"),
            evaluation=evaluation,
        )

    def assert_acquisition_failed(self, envelope):
        """The input failed, so its one consuming rule reports error."""
        self.assertEqual(envelope["status"], "error")
        self.assertIsNone(envelope["baseline"])
        entry = entry_named(envelope, PRESERVE_RULE)
        self.assertEqual(entry["status"], "error")
        self.assertEqual(entry["causes"], [BASELINE_INPUT])
        self.assertEqual([one["code"] for one in entry["findings"]], ["execution"])

    def test_a_declared_snapshot_is_accepted(self):
        """The positive control: declared names capture and compare."""
        envelope = self.run_snapshot(
            [
                {
                    "uid": "I0",
                    "element": "FOO",
                    "fields": {"UID": ["I0"], "FLAG": ["false"]},
                    "relations": [],
                }
            ],
            "declared-names-control",
            "declared-snapshot-control",
        )
        self.assertEqual(envelope["status"], "satisfied")
        self.assertEqual(envelope["baseline"], "declared-names-control")

    def test_an_undeclared_element_fails_acquisition(self):
        envelope = self.run_snapshot(
            [
                {
                    "uid": "I0",
                    "element": "QUX",
                    "fields": {"UID": ["I0"]},
                    "relations": [],
                }
            ],
            "undeclared-element",
            "undeclared-element-snapshot",
        )
        self.assert_acquisition_failed(envelope)

    def test_an_undeclared_field_fails_acquisition(self):
        envelope = self.run_snapshot(
            [
                {
                    "uid": "I0",
                    "element": "FOO",
                    "fields": {"UID": ["I0"], "WOBBLE": ["x"]},
                    "relations": [],
                }
            ],
            "undeclared-field",
            "undeclared-field-snapshot",
        )
        self.assert_acquisition_failed(envelope)

    def test_an_undeclared_relation_role_fails_acquisition(self):
        envelope = self.run_snapshot(
            [
                {
                    "uid": "I0",
                    "element": "FOO",
                    "fields": {"UID": ["I0"]},
                    "relations": [
                        {"role": "ZZZ", "direction": "parent", "target": "F0"}
                    ],
                }
            ],
            "undeclared-relation-role",
            "undeclared-relation-snapshot",
        )
        self.assert_acquisition_failed(envelope)

    def test_a_declared_role_in_the_wrong_direction_fails_acquisition(self):
        """A relation resolves by owner element, direction and name.

        FOO declares H as a parent relation only (contract.md:851-852), so the
        same role as a child occurrence does not resolve.
        """
        envelope = self.run_snapshot(
            [
                {
                    "uid": "I0",
                    "element": "FOO",
                    "fields": {"UID": ["I0"]},
                    "relations": [
                        {"role": "H", "direction": "child", "target": "F0"}
                    ],
                }
            ],
            "undeclared-relation-direction",
            "undeclared-direction-snapshot",
        )
        self.assert_acquisition_failed(envelope)


if __name__ == "__main__":
    unittest.main()

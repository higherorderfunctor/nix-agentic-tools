"""Independent M3d ABI, hostile transport and admission tests; no CodeQL build."""

from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from facts import baseline_shapes, canonical, complete, key, projection, rows, source_admission


# A trusted stdlib-only command transport, independent of the real Nix producer.
if __name__ == "__main__" and sys.argv[1:] == ["--produce"]:
    job = json.load(sys.stdin)
    mode = job["moduleArguments"]["mode"]
    packet = projection(job["identities"], job["moduleArguments"].get("admission"))
    Path(job["moduleArguments"]["marker"]).write_text("executed\n")
    if mode == "partial":
        candidate_observations = {row[0] for row in rows(packet, "nx_observation_candidates")}
        candidate_relations = {"nx_candidates", "nx_definition_candidate_priorities",
                               "nx_definition_selections", "nx_observation_candidates"}
        retained_origins = {row[3] for row in rows(packet, "nx_definitions")}
        packet["facts"] = [
            item for item in packet["facts"]
            if item[0] not in candidate_relations
            and not (item[0] == "nx_observations" and item[1][0] in candidate_observations)
            and not (item[0] == "nx_origins" and item[1][0] not in retained_origins)
        ]
        rows(packet, "nx_request_results")[0][1:] = ["partial", "definition-body-opaque", 2]
    elif mode == "partial-candidates":
        rows(packet, "nx_request_results")[0][1:] = ["partial", "definition-body-opaque", 5]
    elif mode == "lying-count":
        rows(packet, "nx_request_results")[0][3] = 3
    elif mode == "foreign-request":
        rows(packet, "nx_observations")[0][1] = key("request", ["foreign"])
    elif mode == "missing-candidate-subject":
        observation = rows(packet, "nx_observation_candidates")[0][0]
        packet["facts"] = [item for item in packet["facts"]
                           if not (item[0] == "nx_observation_candidates" and item[1][0] == observation)]
    print(json.dumps(packet))
    sys.exit(0)

from jsonschema import ValidationError

OWNER = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(OWNER / "src/eval"))
import protocol
import supervisor
from supervisor import supervise

CANDIDATE_ROWS = ("nx_candidates", "nx_definition_candidate_priorities",
                  "nx_definition_selections", "nx_observation_candidates")


def reframe_candidate(packet, index, module, group):
    """Give a synthetic candidate the identity implied by a merge chain."""
    candidate = rows(packet, "nx_candidates")[index]
    original = candidate[0]
    request = rows(packet, "nx_requests")[0][0]
    framed = key("candidate", [request, candidate[1], module, candidate[4],
                               canonical(group)])
    for relation in CANDIDATE_ROWS:
        subject = 1 if relation == "nx_observation_candidates" else 0
        for row in rows(packet, relation):
            if row[subject] == original:
                row[subject] = framed
    return framed


def request(**budgets):
    return dict(domain="option-metadata", facet="all-definitions", path=["demo", "answer"],
                maxBytes=1048576, maxDepth=1, maxMemoryMiB=256, maxNodes=5,
                maxSeconds=5) | budgets


def manifest(root, requests):
    return {"manifestVersion": 1, "targets": {"D": {
        "adapter": "evalModules", "adapterVersion": "1", "system": "x86_64-linux",
        "argumentDescription": {"hash": "arguments", "moduleArgumentsRef": "module:1",
                                "specialArgumentsRef": "special:1"},
        "evaluation": {"kind": "rich-result", "reference": "eval:1"},
        "fingerprint": {"evaluatorVersion": "pinned-test", "libVersion": "none",
                        "modelVersion": "not-requested", "policyHash": "isolated",
                        "sourceSnapshotHash": "snapshot"},
        "inputIdentities": {"project": "snapshot"}, "observationModes": ["metadata"],
        "requests": requests,
        "sourceRoots": [{"logicalName": "project", "path": str(root),
                         "rootContentIdentity": "snapshot"}],
        "syntaxOnlyFallback": True,
    }}}


class AllDefinitionsAbiTests(unittest.TestCase):
    def assert_valid(self, packet):
        self.assertEqual(protocol.envelope(packet["facts"]), packet)

    def assert_rejected(self, packet):
        with self.assertRaises((ValueError, ValidationError)):
            protocol.envelope(packet["facts"])

    def test_candidate_packet_trap_and_schema_projection(self):
        packet = complete()
        self.assert_valid(packet)
        self.assertEqual(rows(packet, "nx_request_results")[0][1:], ["complete", "", 5])
        self.assertEqual(len(rows(packet, "nx_candidates")), 3)
        rendered = protocol.trap(packet["facts"])
        self.assertEqual(len([line for line in rendered.splitlines()
                              if line.startswith("nx_candidates(")]), 3)
        self.assertNotIn("True", rendered)
        self.assertNotIn("False", rendered)
        schema = protocol.abi.dbscheme()
        self.assertIn("string active: string", schema)
        self.assertIn("string selected: string", schema)
        self.assertIn("unique int candidate: @nx_candidate", schema,
                      "candidate must be a typed entity, not a text forgery")
        self.assertIn("int candidate: @nx_candidate ref", schema)
        self.assertEqual(schema, (OWNER / "schema/evaluation.dbscheme").read_text())

    def test_candidate_state_priority_and_identity_domains(self):
        packet = complete()
        candidate = rows(packet, "nx_candidates")[0]
        for invalid in (True, False, 1, "maybe", ""):
            broken = complete()
            rows(broken, "nx_candidates")[0][5] = invalid
            with self.subTest(active=invalid):
                self.assert_rejected(broken)
        broken = complete()
        rows(broken, "nx_candidates")[1][6] = True
        self.assert_rejected(broken)
        broken = complete()
        rows(broken, "nx_definition_candidate_priorities")[0][1] = "09"
        self.assert_rejected(broken)
        broken = complete()
        rows(broken, "nx_definition_candidate_priorities")[0][1] = "-9223372036854775808"
        self.assert_valid(broken)
        broken = complete()
        rows(broken, "nx_definition_candidate_priorities")[0][1] = "9223372036854775807"
        self.assert_valid(broken)
        broken = complete()
        rows(broken, "nx_definition_candidate_priorities")[0][1] = "9223372036854775808"
        self.assert_rejected(broken)
        # Candidate identity is framed from the contract's five semantic inputs.
        broken = complete()
        forged = key("candidate", ["forged"])
        for relation in ("nx_candidates", "nx_definition_candidate_priorities",
                         "nx_definition_selections", "nx_observation_candidates"):
            for row in rows(broken, relation):
                if row[0] == candidate[0]:
                    row[0] = forged
        self.assert_rejected(broken)

    def test_wrapper_chain_is_canonical_and_closed(self):
        packet = complete()
        chain = json.loads(rows(packet, "nx_candidates")[1][7])
        anchor = chain[0]["anchor"]
        for valid in (
            [],
            [{"kind": "merge", "anchor": anchor, "index": 0}],
            [{"kind": "if", "anchor": anchor, "truth": "unknown"}],
            [{"kind": "override", "anchor": anchor, "priority": None}],
            [{"kind": "order", "anchor": anchor, "priority": "-1"}],
        ):
            broken = complete()
            if valid and valid[0]["kind"] == "merge":
                reframe_candidate(broken, 1, "fallback", [0])
            rows(broken, "nx_candidates")[1][7] = json.dumps(valid, separators=(",", ":"))
            with self.subTest(valid=valid):
                self.assert_valid(broken)
        for invalid in (
            [{"kind": "custom", "anchor": anchor}],
            [{"kind": "merge", "anchor": anchor}],
            [{"kind": "merge", "anchor": anchor, "index": -1}],
            [{"kind": "if", "anchor": anchor, "truth": True}],
            [{"kind": "if", "anchor": anchor, "truth": "unknown", "extra": 1}],
            [{"kind": "override", "anchor": anchor}],
            [{"kind": "order", "anchor": "nixql:v1:anchor:missing", "priority": "0"}],
            [{"kind": "order", "anchor": anchor, "priority": "0x1"}],
        ):
            broken = complete()
            rows(broken, "nx_candidates")[1][7] = json.dumps(invalid, separators=(",", ":"))
            with self.subTest(invalid=invalid):
                self.assert_rejected(broken)
        broken = complete()
        rows(broken, "nx_candidates")[1][7] = json.dumps([chain[0]], indent=1)
        self.assert_rejected(broken)

    def test_typed_candidates_selection_and_ordinals_cannot_be_forged(self):
        self.assert_valid(complete())
        for mode in (
            "missing-subject", "mixed-subject", "foreign-option", "failed-result",
            "unadmitted-anchor", "selected-false-link", "selected-true-without-link",
            "duplicate-option-ordinal", "ordinal-gap",
        ):
            packet = complete()
            observation = rows(packet, "nx_observation_candidates")[0][0]
            option = rows(packet, "nx_options")[0][0]
            if mode == "missing-subject":
                packet["facts"] = [item for item in packet["facts"]
                                   if not (item[0] == "nx_observation_candidates"
                                           and item[1][0] == observation)]
            elif mode == "mixed-subject":
                packet["facts"].append(["nx_observation_options", [observation, option]])
            elif mode == "foreign-option":
                rows(packet, "nx_candidates")[0][1] = key("option", ["foreign"])
            elif mode == "failed-result":
                rows(packet, "nx_request_results")[0][1] = "failed"
            elif mode == "unadmitted-anchor":
                packet["facts"] = [item for item in packet["facts"]
                                   if item[0] != "nx_target_inputs"]
            elif mode == "selected-false-link":
                rows(packet, "nx_definition_selections")[0][0] = rows(packet, "nx_candidates")[1][0]
            elif mode == "selected-true-without-link":
                packet["facts"] = [item for item in packet["facts"]
                                   if item[0] != "nx_definition_selections"]
            elif mode == "duplicate-option-ordinal":
                original = rows(packet, "nx_candidates")[0]
                forged = key("candidate", ["duplicate"])
                packet["facts"].append(["nx_candidates", [forged, *original[1:]]])
            else:
                rows(packet, "nx_candidates")[2][2] = 3
            with self.subTest(mode=mode):
                self.assert_rejected(packet)

    def test_l3_candidate_correspondence_group_and_loser_invariants(self):
        shared = complete()
        fallback = rows(shared, "nx_candidates")[1]
        fallback[6] = "true"
        shared["facts"].append(["nx_definition_selections", [
            fallback[0], rows(shared, "nx_definitions")[0][0],
        ]])
        self.assert_rejected(shared)

        mismatched = complete()
        chain = json.loads(rows(mismatched, "nx_candidates")[1][7])
        merge_anchor = chain[0]["anchor"]
        chain.insert(0, {"kind": "merge", "anchor": merge_anchor, "index": 0})
        rows(mismatched, "nx_candidates")[1][7] = canonical(chain)
        self.assert_rejected(mismatched)

        unknown_selected = complete()
        candidate = rows(unknown_selected, "nx_candidates")[2]
        candidate[5] = "unknown"
        candidate[6] = "true"
        unknown_selected["facts"].append(["nx_definition_selections", [
            candidate[0], rows(unknown_selected, "nx_definitions")[0][0],
        ]])
        self.assert_rejected(unknown_selected)

        unsupported_loser = complete()
        loser = rows(unsupported_loser, "nx_candidates")[1]
        unsupported_loser["facts"] = [
            item for item in unsupported_loser["facts"]
            if not (item[0] == "nx_definition_candidate_priorities"
                    and item[1][0] == loser[0])
        ]
        self.assert_rejected(unsupported_loser)

    def test_candidate_origin_file_cannot_diverge_from_its_anchor(self):
        packet = complete()
        candidates = rows(packet, "nx_candidates")
        anchors = {row[0]: row[1] for row in rows(packet, "nx_anchors")}
        origins = {row[0]: row[1] for row in rows(packet, "nx_origin_files")}
        source = anchors[candidates[0][4]]
        forged = anchors[candidates[1][4]]
        self.assertNotEqual(source, forged)
        for row in rows(packet, "nx_origin_files"):
            if origins[row[0]] == source:
                row[1] = forged
                break
        else:
            self.fail("candidate origin was not source-linked")
        self.assert_rejected(packet)

    def test_retained_selection_stays_on_the_existing_definition_table(self):
        packet = complete()
        self.assert_valid(packet)
        ordinary = next(row for row in rows(packet, "nx_candidates") if row[6] == "true")
        self.assertEqual(rows(packet, "nx_definitions")[0][1:3],
                         [ordinary[1], 0])
        self.assertEqual(len(rows(packet, "nx_definition_selections")), 1)
        broken = complete()
        # A source candidate cannot enter the retained table without an authenticated
        # occurrence correspondence and observation.
        forged = key("definition", ["candidate-forgery"])
        broken["facts"].append(["nx_definitions", [
            forged, rows(broken, "nx_options")[0][0], 1,
            key("origin", [rows(broken, "nx_requests")[0][0], "fallback.nix"]),
        ]])
        self.assert_rejected(broken)


class AllDefinitionsSupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.serial = 0

    def run_jobs(self, mode="complete", **budgets):
        self.serial += 1
        marker = self.root / ("executed-" + str(self.serial))
        trap = self.root / ("trap-" + str(self.serial))
        admission = source_admission(self.root)
        bindings = {
            "eval:1": {"command": [sys.executable, str(Path(__file__).resolve()), "--produce"]},
            "module:1": {"admission": admission["shapes"], "mode": mode,
                         "marker": str(marker)},
            "special:1": {},
        }
        packet = supervise(manifest(self.root, [request(**budgets)]), bindings, trap,
                           source_files=admission["files"],
                           source_anchors=admission["anchors"],
                           source_mappings=admission["mappings"])
        self.assertEqual(protocol.envelope(packet["facts"]), packet)
        return packet, marker, trap

    def test_graph_domain_rejects_all_definitions_before_execution(self):
        invalid = request() | {"domain": "module-graph", "path": []}
        with patch.object(supervisor, "admitted_sources") as admission, \
                patch.object(supervisor, "execute") as execute:
            packet = supervise(manifest(self.root, [invalid]), {}, self.root / "trap")
        admission.assert_not_called()
        execute.assert_not_called()
        self.assertTrue(any(row[2] == "manifest-invalid" for row in rows(packet, "nx_diagnostics")))
        self.assertFalse(rows(packet, "nx_targets"))
        self.assertFalse(rows(packet, "nx_requests"))

    def test_manifest_admits_facet_and_publishes_typed_inventory(self):
        packet, marker, _ = self.run_jobs()
        self.assertEqual(marker.read_text(), "executed\n")
        self.assertEqual(rows(packet, "nx_request_results")[0][1:], ["complete", "", 5])
        self.assertEqual(len(rows(packet, "nx_candidates")), 3)
        self.assertEqual(len(rows(packet, "nx_observation_candidates")), 3)
        self.assertTrue(any(row[1:] == ["all-definitions", "supported", ""]
                            for row in rows(packet, "nx_capabilities")))

    def test_opaque_inventory_can_be_atomically_empty_and_partial(self):
        packet, marker, trap = self.run_jobs("partial")
        self.assertEqual(marker.read_text(), "executed\n")
        self.assertEqual(rows(packet, "nx_request_results")[0][1:],
                         ["partial", "definition-body-opaque", 2])
        for relation in CANDIDATE_ROWS:
            self.assertFalse(rows(packet, relation), relation)
            for path in trap.rglob("*.trap"):
                self.assertNotIn(relation + "(", path.read_text())
        self.assertEqual(len(rows(packet, "nx_observations")), 2)
        self.assertTrue(rows(packet, "nx_options"))
        self.assertTrue(rows(packet, "nx_definitions"))

    def test_partial_inventory_may_publish_known_candidates_without_completing(self):
        packet, marker, _ = self.run_jobs("partial-candidates")
        self.assertEqual(marker.read_text(), "executed\n")
        self.assertEqual(rows(packet, "nx_request_results")[0][1:],
                         ["partial", "definition-body-opaque", 5])
        self.assertEqual(len(rows(packet, "nx_candidates")), 3)
        self.assertEqual(len(rows(packet, "nx_observation_candidates")), 3)

    def test_root_only_depth_refuses_option_and_children_atomically(self):
        packet, marker, trap = self.run_jobs(maxDepth=0)
        self.assertEqual(marker.read_text(), "executed\n")
        self.assertEqual(rows(packet, "nx_request_results")[0][1:],
                         ["failed", "depth-limit", 0])
        for relation in ("nx_options", "nx_definitions", "nx_option_metadata",
                         "nx_option_priority", *CANDIDATE_ROWS):
            self.assertFalse(rows(packet, relation), relation)
            for path in trap.rglob("*.trap"):
                self.assertNotIn(relation + "(", path.read_text(), relation)

    def test_hostile_counts_and_subjects_never_become_complete_inventory(self):
        for mode in ("lying-count", "foreign-request", "missing-candidate-subject"):
            with self.subTest(mode=mode):
                packet, _, trap = self.run_jobs(mode)
                self.assertFalse(any(result[1:] == ["complete", "", 5]
                                     for result in rows(packet, "nx_request_results")))
                self.assertTrue(rows(packet, "nx_diagnostics"))
                for relation in CANDIDATE_ROWS:
                    self.assertFalse(rows(packet, relation), relation)
                    for path in trap.rglob("*.trap"):
                        self.assertNotIn(relation + "(", path.read_text())


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(loader.loadTestsFromTestCase(cls)
                              for cls in (AllDefinitionsAbiTests,
                                          AllDefinitionsSupervisorTests))


if __name__ == "__main__":
    unittest.main()

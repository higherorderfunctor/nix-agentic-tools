"""Independent F1 ownership and supervisor manifest-admission regressions."""

from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile
import unittest

from facts import complete, key, projection, rows


# A trusted command transport, deliberately independent of the real Nix producer.
# Keep this branch stdlib-only: the supervisor removes ambient Python paths.
if __name__ == "__main__" and sys.argv[1:] == ["--produce"]:
    job = json.load(sys.stdin)
    arguments = job["moduleArguments"]
    Path(arguments["marker"]).write_text("executed\n")
    print(json.dumps(projection(job["identities"], empty=arguments["empty"])))
    sys.exit(0)

from test_graph_regressions import GRAPH_ROWS, NONCOMPLETE, OBSERVATION_ROWS, graph_request, manifest
import protocol
from supervisor import supervise


class GraphOwnershipAbiTests(unittest.TestCase):
    def assert_valid(self, packet):
        self.assertEqual(protocol.envelope(packet["facts"]), packet)

    def assert_rejected(self, packet):
        with self.assertRaises(ValueError):
            protocol.envelope(packet["facts"])

    def test_complete_nonempty_and_empty_controls(self):
        for empty, count in ((False, 5), (True, 1)):
            with self.subTest(empty=empty):
                packet = complete(empty=empty)
                self.assert_valid(packet)
                self.assertEqual(rows(packet, "nx_request_results")[0][1:], ["complete", "", count])
                self.assertEqual(len(rows(packet, "nx_modules")), count - 1)
                self.assertEqual(len(rows(packet, "nx_observation_contexts")), 1)
                self.assertEqual(len(rows(packet, "nx_observation_modules")), count - 1)

    def test_noncomplete_status_only_control(self):
        for state in NONCOMPLETE:
            with self.subTest(state=state):
                packet = complete(empty=True)
                self.assert_valid(packet)
                packet["facts"] = [item for item in packet["facts"] if item[0] not in OBSERVATION_ROWS]
                rows(packet, "nx_request_results")[0][1:] = [state, "ownership-test", 0]
                self.assert_valid(packet)
                self.assertFalse(rows(packet, "nx_modules"))

    def test_graph_rows_require_a_graph_request_even_without_observations(self):
        packet = complete()
        self.assert_valid(packet)
        removed = (*OBSERVATION_ROWS, "nx_requests", "nx_request_results")
        packet["facts"] = [item for item in packet["facts"] if item[0] not in removed]
        self.assertEqual(len(rows(packet, "nx_modules")), 4)
        self.assert_rejected(packet)

    def test_graph_request_requires_observations_and_typed_links(self):
        for removed in (OBSERVATION_ROWS, ("nx_observation_contexts", "nx_observation_modules")):
            with self.subTest(removed=removed):
                packet = complete()
                self.assert_valid(packet)
                packet["facts"] = [item for item in packet["facts"] if item[0] not in removed]
                self.assert_rejected(packet)

    def test_option_declarations_request_cannot_own_graph_rows(self):
        packet = complete(empty=True)
        self.assert_valid(packet)
        packet["facts"] = [item for item in packet["facts"] if item[0] not in OBSERVATION_ROWS]
        request = rows(packet, "nx_requests")[0]
        request[3:7] = ["option-metadata", '["option"]', "declarations", 0]
        option = key("option", [request[2], '["option"]'])
        observation = key("observation", [request[0], "option-control"])
        packet["facts"].extend([
            ["nx_options", [option, request[2], '["option"]']],
            ["nx_observations", [observation, request[0], "pre-apply-metadata", "observed"]],
            ["nx_observation_options", [observation, option]],
        ])
        self.assert_valid(packet)
        # Add the exact independent fixture graph without its closure witnesses.
        packet["facts"].extend(deepcopy(item) for item in complete()["facts"]
                               if item[0] in (*GRAPH_ROWS, "nx_origins"))
        self.assertEqual(len(rows(packet, "nx_modules")), 4)
        self.assert_rejected(packet)


class GraphOwnershipSupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.serial = 0

    def run_jobs(self, requests, *, empty=False):
        self.serial += 1
        self.marker = self.root / ("executed-" + str(self.serial))
        self.trap = self.root / ("trap-" + str(self.serial))
        bindings = {
            "eval:1": {"command": [sys.executable, str(Path(__file__).resolve()), "--produce"]},
            "module:1": {"empty": empty, "marker": str(self.marker)},
            "special:1": {},
        }
        packet = supervise(manifest(self.root, requests), bindings, self.trap)
        self.assertEqual(protocol.envelope(packet["facts"]), packet)
        return packet

    def assert_discovery_refusal(self, requests):
        # F2 may reject the manifest, or supervisor discovery may reject it.
        # Either authority must refuse the whole manifest before any execution.
        packet = self.run_jobs(requests)
        self.assertFalse(self.marker.exists(), "invalid manifest executed a producer")
        for phase in ("discovery", "evaluation"):
            self.assertTrue(any(row[1:3] == [phase, "failed"] for row in rows(packet, "nx_phases")), phase)
        self.assertTrue(rows(packet, "nx_diagnostics"))
        for relation in (*GRAPH_ROWS, *OBSERVATION_ROWS, "nx_targets", "nx_contexts", "nx_requests", "nx_target_inputs"):
            self.assertFalse(rows(packet, relation), relation)
            for path in self.trap.rglob("*.trap"):
                self.assertNotIn(relation + "(", path.read_text(), str(path))
        self.assertFalse([path for path in self.trap.rglob("*")
                          if path.is_file() and path.suffix != ".trap"])

    def test_complete_nonempty_and_empty_transport_controls(self):
        for empty, count in ((False, 5), (True, 1)):
            with self.subTest(empty=empty):
                packet = self.run_jobs([graph_request()], empty=empty)
                self.assertEqual(self.marker.read_text(), "executed\n")
                self.assertEqual(rows(packet, "nx_request_results")[0][1:], ["complete", "", count])
                self.assertEqual(len(rows(packet, "nx_modules")), count - 1)
                self.assertEqual(len(rows(packet, "nx_observation_contexts")), 1)
                self.assertEqual(any("nx_modules(" in path.read_text() for path in self.trap.rglob("*.trap")), not empty)

    def test_malformed_graph_facet_refused_before_execution_or_admission(self):
        self.assert_discovery_refusal([graph_request(facet="declarations")])

    def test_nonempty_graph_path_refused_before_execution_or_admission(self):
        self.assert_discovery_refusal([graph_request(path=["option"])])

    def test_valid_first_invalid_second_never_publishes_earlier_graph(self):
        for invalid in (graph_request(facet="declarations"), graph_request(path=["option"])):
            with self.subTest(invalid=invalid):
                self.assert_discovery_refusal([graph_request(), invalid])


if __name__ == "__main__":
    unittest.main()

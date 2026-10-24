"""F3 health and ABI witnesses; no producer is used to derive expectations."""

from pathlib import Path
import sys
import unittest

OWNER = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(OWNER / "schema"))
sys.path.insert(0, str(OWNER / "checks/fixtures/abi"))
import abi
from golden import BINDING_GRAPH

# M3p relation inventory, independently spelled rather than generated.
RELATIONS = {
    "nx_anchors", "nx_capabilities", "nx_contexts", "nx_definition_order", "nx_definitions",
    "nx_diagnostic_requests", "nx_diagnostic_targets", "nx_diagnostics", "nx_files",
    "nx_module_lib_bindings",
    "nx_observation_definitions", "nx_observation_options", "nx_observations",
    "nx_option_declarations", "nx_option_metadata",
    "nx_option_priority", "nx_options", "nx_origin_files", "nx_origin_positions",
    "nx_origins", "nx_phases", "nx_request_results", "nx_requests", "nx_runs",
    "nx_syntax_results", "nx_target_inputs", "nx_targets",
}


class SentinelTests(unittest.TestCase):
    def test_abi_witness_covers_every_relation(self):
        abi.validate(BINDING_GRAPH)
        self.assertEqual({name for name, _ in BINDING_GRAPH}, RELATIONS)

    def test_health_has_explicit_successful_work(self):
        rows = lambda name: [args for relation, args in BINDING_GRAPH if relation == name]
        runs = rows("nx_runs")
        self.assertTrue(runs, "no extraction run")
        self.assertTrue(rows("nx_targets"), "no admitted target")
        self.assertTrue(rows("nx_syntax_results"), "no syntax result")
        self.assertTrue(rows("nx_request_results"), "no observation result")
        for run in runs:
            self.assertIn([run[0], "discovery", "complete", ""], rows("nx_phases"))
        self.assertTrue(all(args[-1] == "complete" for args in rows("nx_targets")))
        self.assertTrue(all(args[1:] == ["complete", 0] for args in rows("nx_syntax_results")))
        self.assertTrue(all(args[1] == "complete" and args[3] > 0 for args in rows("nx_request_results")))


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""O2: closure is a graph facet, refused for option metadata at F2 discovery."""

from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_graph_regressions import graph_request, manifest

OWNER = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(OWNER / "src/eval"))
import protocol
import supervisor


class FacetAdmissionTests(unittest.TestCase):
    def test_option_metadata_closure_refused_before_execution_or_admission(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            request = graph_request(domain="option-metadata", path=["_module", "args"], maxDepth=0)
            # These controls distinguish O2 from an otherwise invalid manifest.
            for facet in ("declarations", "definitions", "isDefined", "priority", "selection"):
                supervisor.validate(manifest(root, [request | {"facet": facet}]), "target-manifest.json")
            supervisor.validate(manifest(root, [graph_request()]), "target-manifest.json")
            trap = root / "trap"
            with patch.object(supervisor, "admitted_sources") as admission, patch.object(supervisor, "execute") as execute:
                packet = supervisor.supervise(manifest(root, [request]), {}, trap)
            admission.assert_not_called()
            execute.assert_not_called()
            self.assertEqual(protocol.envelope(packet["facts"]), packet)
            tables = {}
            for relation, args in packet["facts"]:
                tables.setdefault(relation, []).append(args)
            self.assertTrue(any(row[2] == "manifest-invalid" for row in tables["nx_diagnostics"]))
            for phase in ("discovery", "evaluation"):
                self.assertTrue(any(row[1:3] == [phase, "failed"] for row in tables["nx_phases"]))
            for relation in ("nx_targets", "nx_target_inputs", "nx_contexts", "nx_requests", "nx_request_results", "nx_options", "nx_observations"):
                self.assertNotIn(relation, tables)
                for path in trap.rglob("*.trap"):
                    self.assertNotIn(relation + "(", path.read_text())


if __name__ == "__main__":
    unittest.main()

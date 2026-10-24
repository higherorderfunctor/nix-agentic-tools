"""Independent M3g ABI, hostile transport and E1 controls; no CodeQL build."""

from copy import deepcopy
import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest

from jsonschema import ValidationError

from facts import complete, key, rows

OWNER = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(OWNER / "src/eval"))
import protocol
from supervisor import supervise

spec = importlib.util.spec_from_file_location("graph_isolation", OWNER / "checks/fixtures/eval-isolation/test_supervisor.py")
isolation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(isolation)


class GraphAbiTests(unittest.TestCase):
    def test_boolean_envelope_trap_and_physical_schema(self):
        packet = complete()
        self.assertEqual(protocol.envelope(packet["facts"]), packet)
        self.assertEqual(protocol.envelope(complete(empty=True)["facts"]), complete(empty=True))
        rendered = protocol.trap(packet["facts"])
        module_rows = [line for line in rendered.splitlines() if line.startswith("nx_modules(")]
        self.assertEqual(len(module_rows), 4)
        self.assertEqual([line.rsplit(",", 1)[1].strip() for line in module_rows], ["0)", "1)", "1)", "0)"])
        self.assertNotIn("True", rendered)
        self.assertNotIn("False", rendered)
        schema = protocol.abi.dbscheme()
        self.assertIn("disabled: int ref", schema)
        self.assertEqual(schema, (OWNER / "schema/evaluation.dbscheme").read_text())
        for invalid in (0, 1, "true", "false", None):
            packet = complete()
            rows(packet, "nx_modules")[0][4] = invalid
            with self.subTest(invalid=invalid), self.assertRaises((ValueError, ValidationError)):
                # envelope is the same authority exercised by the importer.
                protocol.envelope(packet["facts"])

    def test_graph_structure_requires_contiguous_reachable_single_parent_occurrences(self):
        protocol.envelope(complete()["facts"])
        for mode in ("root-gap", "child-gap", "parentless", "root-has-parent", "two-parents", "cycle", "duplicate-key", "dangling"):
            packet = complete()
            modules = rows(packet, "nx_modules")
            if mode == "root-gap":
                rows(packet, "nx_module_roots")[1][1] = 2
            elif mode == "child-gap":
                rows(packet, "nx_module_imports")[1][1] = 2
            elif mode == "parentless":
                packet["facts"] = [item for item in packet["facts"] if item[0] != "nx_module_imports"]
            elif mode == "root-has-parent":
                packet["facts"].append(["nx_module_imports", [modules[1][0], 0, modules[0][0]]])
            elif mode == "two-parents":
                packet["facts"].append(["nx_module_imports", [modules[3][0], 0, modules[1][0]]])
            elif mode == "cycle":
                packet["facts"] = [item for item in packet["facts"] if item[0] != "nx_module_imports"]
                packet["facts"].extend([["nx_module_imports", [modules[2][0], 0, modules[1][0]]], ["nx_module_imports", [modules[1][0], 0, modules[2][0]]]])
            elif mode == "duplicate-key":
                # Relation primary keys, unlike reported moduleKey, are unique.
                packet["facts"].append(deepcopy(next(item for item in packet["facts"] if item[0] == "nx_module_imports")))
            else:
                rows(packet, "nx_module_imports")[0][2] = key("module", ["missing"])
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                protocol.abi.validate(packet["facts"])

    def test_exactly_one_typed_subject_success_and_context_cannot_be_forged(self):
        protocol.envelope(complete()["facts"])
        for mode in ("missing-subject", "mixed-subject", "foreign-context", "foreign-request", "failed", "missing-module-witness", "missing-context-witness", "duplicate-request", "nonroot-path"):
            packet = complete()
            observation = rows(packet, "nx_observation_modules")[0][0]
            if mode == "missing-subject":
                packet["facts"] = [item for item in packet["facts"] if not (item[0] == "nx_observation_modules" and item[1][0] == observation)]
            elif mode == "mixed-subject":
                packet["facts"].append(["nx_observation_contexts", [observation, rows(packet, "nx_contexts")[0][0]]])
            elif mode == "foreign-context":
                other = key("context", ["other"])
                packet["facts"].append(["nx_contexts", [other, rows(packet, "nx_targets")[0][0], "root", "[]"]])
                rows(packet, "nx_modules")[0][1] = other
            elif mode == "foreign-request":
                rows(packet, "nx_observations")[1][1] = key("request", ["other"])
            elif mode == "failed":
                rows(packet, "nx_request_results")[0][1] = "failed"
            elif mode in ("missing-module-witness", "missing-context-witness"):
                relation = "nx_observation_modules" if mode == "missing-module-witness" else "nx_observation_contexts"
                witness = rows(packet, relation)[0][0]
                packet["facts"] = [item for item in packet["facts"] if not (item[0] in (relation, "nx_observations") and item[1][0] == witness)]
            elif mode == "duplicate-request":
                request = deepcopy(rows(packet, "nx_requests")[0])
                request[0] = key("request", ["second"])
                packet["facts"].append(["nx_requests", request])
            else:
                rows(packet, "nx_requests")[0][4] = '["not-root"]'
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                protocol.abi.validate(packet["facts"])


class GraphSupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_projection(self, mode="ok", **budgets):
        request = dict(domain="module-graph", facet="closure", path=[], maxBytes=1048576,
                       maxDepth=1, maxMemoryMiB=256, maxNodes=5, maxSeconds=5) | budgets
        manifest = isolation.manifest(self.root, [request])
        bindings = {"eval:1": {"command": [sys.executable, str(Path(__file__).with_name("producer.py"))]},
                    "module:1": {"mode": mode}, "special:1": {}}
        trap = Path(tempfile.mkdtemp(dir=self.temp.name))
        packet = supervise(manifest, bindings, trap, nix=isolation.NIX)
        protocol.envelope(packet["facts"])
        self.assertEqual(len(rows(packet, "nx_request_results")), 1, rows(packet, "nx_diagnostics"))
        return packet, "\n".join(path.read_text() for path in trap.glob("*.trap"))

    def test_direct_producer_uses_exact_framed_occurrence_and_origin_identities(self):
        for name in ("fixture.nix", "path-child.nix", "root.nix"):
            shutil.copy(Path(__file__).with_name(name), self.root / name)
        ids = {kind: key(kind, ["identity-test"]) for kind in ("context", "request", "run", "target")}
        job = {"identities": ids, "request": dict(domain="module-graph", facet="closure", path=[],
               maxBytes=1048576, maxDepth=1, maxMemoryMiB=256, maxNodes=5, maxSeconds=5)}
        expression = 'import ' + str(OWNER / "src/eval/nix/modules.nix") + ' { lib = import ' + os.environ["CODEQL_NIX_TEST_LIB"] + '; modules = [ ' + str(self.root / "root.nix") + ' ]; job = builtins.fromJSON ' + json.dumps(json.dumps(job)) + '; }'
        result = subprocess.run([isolation.NIX, "eval", "--json", "--impure", "--expr", expression],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        packet = json.loads(result.stdout)
        expected = {(key("module", [ids["request"], ids["context"], path]),
                     key("origin", [ids["request"], path])) for path in ("[0]", "[0,0]", "[0,1]", "[1]")}
        self.assertEqual({(row[0], row[3]) for row in rows(packet, "nx_modules")}, expected)
        self.assertEqual(rows(packet, "nx_request_results"), [[ids["request"], "complete", "", 5]])

    def test_complete_and_empty_closures_have_context_witness_no_option(self):
        for mode, count in (("ok", 5), ("empty", 1)):
            packet, _ = self.run_projection(mode)
            self.assertEqual(rows(packet, "nx_request_results")[0][1:], ["complete", "", count])
            self.assertEqual(len(rows(packet, "nx_observation_contexts")), 1)
            self.assertEqual(len(rows(packet, "nx_observation_modules")), count - 1)
            self.assertEqual(rows(packet, "nx_options"), [])
            self.assertEqual(rows(packet, "nx_definitions"), [])
            self.assertIn(["module-graph", "supported", ""], [row[1:] for row in rows(packet, "nx_capabilities")])

    def test_at_and_over_node_depth_byte_time_and_memory_controls(self):
        for mode, accepted, refused in (
            ("ok", {"maxNodes": 5}, {"maxNodes": 4}),
            ("ok", {"maxDepth": 1}, {"maxDepth": 0}),
            ("bytes", {"maxBytes": 131072}, {"maxBytes": 131071}),
            ("timeout", {"maxSeconds": 5}, {"maxSeconds": 1}),
            ("memory", {"maxMemoryMiB": 256}, {"maxMemoryMiB": 64}),
        ):
            with self.subTest(mode=mode):
                packet, _ = self.run_projection(mode, **accepted)
                self.assertEqual(rows(packet, "nx_request_results")[0][1], "complete")
                packet, trap = self.run_projection(mode, **refused)
                self.assertNotEqual(rows(packet, "nx_request_results")[0][1], "complete")
                self.assertTrue(rows(packet, "nx_diagnostics"))
                for relation in ("nx_modules", "nx_module_imports", "nx_module_roots", "nx_observations", "nx_observation_contexts", "nx_observation_modules"):
                    self.assertFalse(rows(packet, relation), relation)
                    self.assertNotIn(relation + "(", trap)

    def test_incomplete_or_forged_closure_is_never_partial_success(self):
        for mode in ("missing-context", "missing-module", "foreign-request", "lying-count"):
            with self.subTest(mode=mode):
                packet, trap = self.run_projection(mode)
                self.assertNotEqual(rows(packet, "nx_request_results")[0][1], "complete")
                self.assertFalse(rows(packet, "nx_modules"))
                self.assertNotIn("nx_modules(", trap)
                self.assertTrue(rows(packet, "nx_diagnostics"))


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(loader.loadTestsFromTestCase(cls) for cls in (GraphAbiTests, GraphSupervisorTests))

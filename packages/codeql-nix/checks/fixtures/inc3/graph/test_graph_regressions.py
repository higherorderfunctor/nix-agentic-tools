"""M3g contract regressions: independent expectations, no learned golden rows.

The same file supplies a hostile command transport when invoked with --produce.
It does not replace the real producer in the direct Nix boundary tests.
"""

from copy import deepcopy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from facts import complete, key, projection, rows

OWNER = Path(__file__).resolve().parents[4]
NIX = os.environ.get("CODEQL_NIX_TEST_NIX") or shutil.which("nix")
GRAPH_ROWS = ("nx_modules", "nx_module_imports", "nx_module_roots")
OBSERVATION_ROWS = ("nx_observations", "nx_observation_contexts", "nx_observation_modules")
NONCOMPLETE = ("blocked", "failed", "partial", "skipped", "unsupported")


def graph_request(**budgets):
    return dict(domain="module-graph", facet="closure", path=[], maxBytes=1048576,
                maxDepth=1, maxMemoryMiB=256, maxNodes=5, maxSeconds=5) | budgets


def manifest(root, requests):
    return {"manifestVersion": 1, "targets": {"G": {
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


def without_observations(packet):
    packet["facts"] = [item for item in packet["facts"] if item[0] not in OBSERVATION_ROWS]


def sourced_packet():
    packet = complete()
    origin = rows(packet, "nx_modules")[0][3]
    root = key("root", ["project", "source-content"])
    file = key("file", [root, "root.nix", "file-content"])
    rows(packet, "nx_origins")[0][2] = "source"
    packet["facts"].extend([
        ["nx_files", [file, root, "root.nix", "file-content", "project"]],
        ["nx_origin_files", [origin, file]],
    ])
    return packet, file


def hostile_producer():
    job = json.load(sys.stdin)
    arguments = job["moduleArguments"]
    Path(arguments["marker"]).write_text("executed\n")
    packet = projection(job["identities"])
    state = arguments["state"]
    if state != "complete":
        rows(packet, "nx_request_results")[0][1:] = [state, "incomplete-test", 0]
        if not arguments.get("observed", False):
            without_observations(packet)
    print(json.dumps(packet))


# The supervisor clears ambient Python paths. Keep the transport stdlib-only.
if __name__ == "__main__" and sys.argv[1:] == ["--produce"]:
    hostile_producer()
    sys.exit(0)

sys.path.insert(0, str(OWNER / "src/eval"))
import protocol
from supervisor import supervise


class GraphRegressionAbiTests(unittest.TestCase):
    def assert_rejected(self, packet):
        # Both producer import and consumer import use this complete authority.
        with self.assertRaises(ValueError):
            protocol.envelope(packet["facts"])

    def test_complete_nonempty_and_empty_positive_baselines(self):
        for empty, count in ((False, 5), (True, 1)):
            with self.subTest(empty=empty):
                packet = complete(empty=empty)
                self.assertEqual(protocol.envelope(packet["facts"]), packet)
                self.assertEqual(rows(packet, "nx_request_results")[0][1:], ["complete", "", count])
                self.assertEqual(len(rows(packet, "nx_observation_contexts")), 1)
                self.assertEqual(len(rows(packet, "nx_observation_modules")), count - 1)

    def test_noncomplete_status_only_control_and_graph_rows_forbidden(self):
        for state in NONCOMPLETE:
            with self.subTest(state=state):
                packet = complete()
                rows(packet, "nx_request_results")[0][1:] = [state, "incomplete-test", 0]
                without_observations(packet)
                status_only = deepcopy(packet)
                status_only["facts"] = [item for item in status_only["facts"]
                                        if item[0] not in GRAPH_ROWS + ("nx_origins",)]
                self.assertEqual(protocol.envelope(status_only["facts"]), status_only)
                self.assert_rejected(packet)

    def test_partial_graph_cannot_keep_successful_observations(self):
        packet = complete()
        rows(packet, "nx_request_results")[0][1] = "partial"
        self.assert_rejected(packet)

    def test_context_and_module_witnesses_require_graph_domain(self):
        for kind in ("context", "module"):
            with self.subTest(kind=kind):
                packet = complete()
                original = rows(packet, "nx_requests")[0]
                other = deepcopy(original)
                other[0] = key("request", ["option-request"])
                other[3:6] = ["option-metadata", "[]", "declarations"]
                packet["facts"].extend([
                    ["nx_requests", other],
                    ["nx_request_results", [other[0], "complete", "", 0]],
                ])
                observation = key("observation", ["wrong-domain", kind])
                subject = rows(packet, "nx_observation_" + kind + "s")[0][1]
                packet["facts"].extend([
                    ["nx_observations", [observation, other[0], "pre-apply-metadata", "observed"]],
                    ["nx_observation_" + kind + "s", [observation, subject]],
                ])
                self.assert_rejected(packet)

    def test_context_and_module_witnesses_require_closure_facet(self):
        for empty in (True, False):
            with self.subTest(empty=empty):
                packet = complete(empty=empty)
                rows(packet, "nx_requests")[0][5] = "declarations"
                self.assert_rejected(packet)

    def test_exact_context_and_module_witness_multiplicity(self):
        for kind in ("context", "module"):
            for mutation in ("missing", "duplicate"):
                with self.subTest(kind=kind, mutation=mutation):
                    packet = complete()
                    relation = "nx_observation_" + kind + "s"
                    observation, subject = rows(packet, relation)[0]
                    if mutation == "missing":
                        packet["facts"] = [item for item in packet["facts"]
                                            if not (item[0] in ("nx_observations", relation)
                                                    and item[1][0] == observation)]
                    else:
                        duplicate = key("observation", ["duplicate", kind])
                        packet["facts"].extend([
                            ["nx_observations", [duplicate, rows(packet, "nx_requests")[0][0],
                                                 "pre-apply-metadata", "observed"]],
                            [relation, [duplicate, subject]],
                        ])
                    self.assert_rejected(packet)

    def test_one_occurrence_cannot_occupy_multiple_root_or_child_positions(self):
        for mutation in ("duplicate-root", "root-also-child"):
            with self.subTest(mutation=mutation):
                packet = complete()
                root = rows(packet, "nx_module_roots")[0]
                if mutation == "duplicate-root":
                    packet["facts"].append(["nx_module_roots", [root[0], 2, root[2]]])
                else:
                    other_root = rows(packet, "nx_module_roots")[1][2]
                    packet["facts"].append(["nx_module_imports", [other_root, 0, root[2]]])
                self.assert_rejected(packet)

    def test_module_origin_file_requires_admission_to_referencing_snapshot(self):
        packet, file = sourced_packet()
        admitted = deepcopy(packet)
        admitted["facts"].append(["nx_target_inputs", [rows(packet, "nx_targets")[0][0], file, "root"]])
        self.assertEqual(protocol.envelope(admitted["facts"]), admitted)
        self.assert_rejected(packet)

    def test_other_snapshot_admission_does_not_authenticate_module_origin(self):
        packet, file = sourced_packet()
        other_run = deepcopy(rows(packet, "nx_runs")[0])
        other_run[0], other_run[-1] = key("run", ["other"]), "other-snapshot"
        other_target = deepcopy(rows(packet, "nx_targets")[0])
        other_target[0:3] = [key("target", ["other"]), other_run[0], "other"]
        packet["facts"].extend([
            ["nx_runs", other_run], ["nx_targets", other_target],
            ["nx_target_inputs", [other_target[0], file, "root"]],
        ])
        self.assert_rejected(packet)


class GraphRegressionSupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.serial = 0

    def run_jobs(self, requests, state="complete", observed=False):
        self.serial += 1
        self.marker = self.root / ("producer-executed-" + str(self.serial))
        self.trap = self.root / ("trap-" + str(self.serial))
        bindings = {"eval:1": {"command": [sys.executable, str(Path(__file__).resolve()), "--produce"]},
                    "module:1": {"state": state, "observed": observed, "marker": str(self.marker)},
                    "special:1": {}}
        packet = supervise(manifest(self.root, requests), bindings, self.trap, nix=NIX)
        self.assertEqual(protocol.envelope(packet["facts"]), packet)
        return packet

    def assert_no_graph_publication(self, packet):
        for relation in GRAPH_ROWS + OBSERVATION_ROWS:
            self.assertEqual(len(rows(packet, relation)), 0, relation)
            for path in self.trap.rglob("*.trap"):
                self.assertNotIn(relation + "(", path.read_text(), str(path))
        self.assertFalse([path for path in self.trap.rglob("*")
                          if path.is_file() and path.suffix != ".trap"])

    def test_successful_control_executes_producer_and_publishes_complete_graph(self):
        packet = self.run_jobs([graph_request()])
        self.assertEqual(self.marker.read_text(), "executed\n")
        self.assertEqual(rows(packet, "nx_request_results")[0][1:], ["complete", "", 5])
        self.assertEqual(len(rows(packet, "nx_modules")), 4)
        self.assertTrue(any("nx_modules(" in path.read_text() for path in self.trap.rglob("*.trap")))

    def test_noncomplete_graph_is_atomic_including_partial_observed_rows(self):
        for state, observed in [(state, False) for state in NONCOMPLETE] + [("partial", True)]:
            with self.subTest(state=state, observed=observed):
                packet = self.run_jobs([graph_request()], state, observed)
                self.assertTrue(self.marker.exists())
                self.assertNotEqual(rows(packet, "nx_request_results")[0][1], "complete")
                self.assert_no_graph_publication(packet)
                self.assertTrue(rows(packet, "nx_diagnostics"))

    def test_duplicate_graph_manifest_fails_discovery_before_execution_without_crash(self):
        first = graph_request()
        # Distinct budgets still select the same context and cannot evade the gate.
        for second in (deepcopy(first), graph_request(maxNodes=6)):
            with self.subTest(second=second):
                packet = self.run_jobs([first, second])
                self.assertFalse(self.marker.exists(), "manifest rejection ran a producer")
                self.assertFalse(rows(packet, "nx_targets"))
                self.assertFalse(rows(packet, "nx_requests"))
                self.assertTrue(rows(packet, "nx_diagnostics"))
                self.assertTrue(any(row[1] in ("discovery", "target-discovery") and row[2] == "failed"
                                    for row in rows(packet, "nx_phases")))
                self.assert_no_graph_publication(packet)


class GraphRegressionProducerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("fixture.nix", "path-child.nix", "root.nix"):
            shutil.copy(Path(__file__).with_name(name), self.root / name)

    def evaluate(self, *, unavailable=False, **budgets):
        ids = {kind: key(kind, ["regression"]) for kind in ("context", "request", "run", "target")}
        job = {"identities": ids, "request": graph_request(**budgets)}
        # Actual pinned lib, with only the rich result's graph field withheld.
        lib = "(import " + os.environ["CODEQL_NIX_TEST_LIB"] + ")"
        if unavailable:
            lib = "(let actual = " + lib + "; in actual // { evalModules = args: builtins.removeAttrs (actual.evalModules args) [ \"graph\" ]; })"
        expression = "import " + str(OWNER / "src/eval/nix/modules.nix") + " { lib = " + lib + "; modules = [ " + str(self.root / "root.nix") + " ]; job = builtins.fromJSON " + json.dumps(json.dumps(job)) + "; }"
        result = subprocess.run([NIX, "eval", "--json", "--impure", "--expr", expression],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout), ids

    def test_direct_producer_budget_refusal_suppresses_graph_before_serialization(self):
        packet, ids = self.evaluate()
        self.assertEqual(rows(packet, "nx_request_results"), [[ids["request"], "complete", "", 5]])
        self.assertEqual(len(rows(packet, "nx_modules")), 4)
        for budgets, reason in (({"maxNodes": 4}, "node-limit"), ({"maxDepth": 0}, "depth-limit")):
            with self.subTest(budgets=budgets):
                packet, ids = self.evaluate(**budgets)
                self.assertEqual(rows(packet, "nx_request_results"), [[ids["request"], "failed", reason, 0]])
                self.assertEqual(len(packet["facts"]), 1, "refusal must precede graph serialization")

    def test_missing_runtime_graph_returns_unavailability_evidence_without_eval_crash(self):
        packet, _ = self.evaluate(unavailable=True)
        result = rows(packet, "nx_request_results")
        self.assertEqual(len(result), 1)
        self.assertNotEqual(result[0][1], "complete")
        self.assertIn("unavailable", result[0][2])
        self.assertEqual(result[0][3], 0)
        self.assertEqual(len(packet["facts"]), 1)


if __name__ == "__main__":
    unittest.main()

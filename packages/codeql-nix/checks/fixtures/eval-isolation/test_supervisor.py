"""E1 contract-first tests; producer rows and Nix oracle are independent.

No expected output is learned from the supervisor. F1 validates the complete
returned graph; a direct Nix evaluation separately proves the minimal projection.
"""

# cspell:ignore ITIMER multifield setitimer unrequested

from http.server import BaseHTTPRequestHandler, HTTPServer
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import unittest

OWNER = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(OWNER / "src/eval"))
from supervisor import ExtractionFailed, supervise

spec = importlib.util.spec_from_file_location("abi", OWNER / "schema/abi.py")
abi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(abi)
PRODUCER = Path(__file__).with_name("producer.py")
NIX = os.environ.get("CODEQL_NIX_TEST_NIX") or shutil.which("nix")


def request(mode="ok", **budgets):
    return dict(domain="config", facet="value", path=[mode], maxBytes=16384,
                maxDepth=0, maxMemoryMiB=256, maxNodes=10, maxSeconds=4) | budgets


def manifest(root, requests):
    return {"manifestVersion": 1, "targets": {"literal.[name].with.dots": {
        "adapter": "evalModules", "adapterVersion": "1",
        "argumentDescription": {"hash": "arguments", "moduleArgumentsRef": "module:1", "specialArgumentsRef": "special:1"},
        "evaluation": {"kind": "config-only", "reference": "eval:1"},
        "fingerprint": {"evaluatorVersion": "pinned-test", "libVersion": "none", "modelVersion": "1", "policyHash": "isolated", "sourceSnapshotHash": "snapshot"},
        "inputIdentities": {"project": "snapshot"}, "observationModes": ["selected-value"],
        "requests": requests, "reusable": True,
        "sourceRoots": [{"logicalName": "project", "path": str(root), "rootContentIdentity": "snapshot"}],
        "syntaxOnlyFallback": True, "system": "x86_64-linux",
    }}}


def rows(packet, name):
    return [args for relation, args in packet["facts"] if relation == name]


class ProjectionCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "admitted"
        self.root.mkdir()
        self.bindings = {"eval:1": {"command": [sys.executable, str(PRODUCER)]},
                         "module:1": {"sentinel": "module"}, "special:1": {"sentinel": "special"}}

    def run_jobs(self, *requests, strict=False, packet=None):
        self.trap = Path(tempfile.mkdtemp(prefix="trap-", dir=self.temp.name))
        result = supervise(packet or manifest(self.root, list(requests)), self.bindings,
                           self.trap, strict=strict, nix=NIX)
        self.assertEqual(result["protocolVersion"], 1)
        abi.validate(result["facts"])
        return result

    def assert_failed_request(self, packet, expected=None):
        results = rows(packet, "nx_request_results")
        self.assertEqual(len(results), 1)
        self.assertNotEqual(results[0][1], "complete")
        if expected:
            self.assertEqual(results[0][1], expected)
        self.assertTrue(rows(packet, "nx_diagnostics"))
        self.assertTrue(rows(packet, "nx_diagnostic_requests"))
        self.assertTrue(rows(packet, "nx_diagnostic_targets"))
        self.assertFalse(rows(packet, "nx_scalar_values"))
        self.assertNotEqual(rows(packet, "nx_targets")[0][-1], "complete")
        self.assertNotEqual(next(row[2] for row in rows(packet, "nx_phases") if row[1] == "evaluation"), "complete")
        for path in self.trap.rglob("*.trap"):
            self.assertNotIn("nx_scalar_values", path.read_text())


class SupervisorTests(ProjectionCase):
    def test_positive_bound_arguments_literal_paths_statuses_and_atomic_handoff(self):
        packet = self.run_jobs(request("binding"), request("a.b"), request("a", path=["a", "b"]))
        self.assertEqual([row[4] for row in rows(packet, "nx_requests")], ['["binding"]', '["a.b"]', '["a","b"]'])
        self.assertEqual(rows(packet, "nx_targets")[0][2], "literal.[name].with.dots")
        self.assertEqual([row[1] for row in rows(packet, "nx_request_results")], ["complete"] * 3)
        self.assertEqual([row[-1] for row in rows(packet, "nx_scalar_values")], ["true"] * 3)
        self.assertTrue(rows(packet, "nx_capabilities"))
        self.assertEqual(rows(packet, "nx_targets")[0][-1], "complete")
        traps = list(self.trap.rglob("*.trap"))
        self.assertTrue(traps)
        self.assertTrue(any("nx_scalar_values" in path.read_text() for path in traps))
        self.assertFalse([path for path in self.trap.rglob("*") if path.is_file() and path.suffix != ".trap"])

    def test_subprocesses_are_serialized(self):
        log = Path(self.temp.name) / "order"
        self.bindings["module:1"] = {"log": str(log)}
        self.run_jobs(request("serial"), request("serial"), request("serial"))
        self.assertEqual(log.read_text().splitlines(), ["start", "end"] * 3)

    def test_error_isolation_preserves_completed_projection_and_strict_evidence(self):
        with self.assertRaises(ExtractionFailed) as raised:
            self.run_jobs(request("ok"), request("crash"), request("ok"), strict=True)
        packet = raised.exception.packet
        abi.validate(packet["facts"])
        self.assertEqual(sorted(row[1] for row in rows(packet, "nx_request_results")), ["complete", "complete", "failed"])
        self.assertEqual(len(rows(packet, "nx_scalar_values")), 2)
        self.assertEqual(rows(packet, "nx_targets")[0][-1], "partial")
        self.assertTrue(any("nx_scalar_values" in path.read_text() for path in self.trap.rglob("*.trap")))

    def test_crashed_malformed_invalid_and_forged_transactions_publish_no_values(self):
        for mode in ("crash", "malformed", "invalid-abi", "forge", "foreign-request"):
            with self.subTest(mode=mode):
                self.assert_failed_request(self.run_jobs(request(mode)))

    def test_time_limit_is_bounded_and_diagnosed(self):
        import time
        start = time.monotonic()
        packet = self.run_jobs(request("timeout", maxSeconds=1))
        self.assertLess(time.monotonic() - start, 8)
        self.assert_failed_request(packet)
        reasons = " ".join(row[2] for row in rows(packet, "nx_request_results") + rows(packet, "nx_diagnostics"))
        self.assertTrue("timeout" in reasons or "time-limit" in reasons)

    def test_memory_output_node_depth_and_diagnostic_budgets_refuse_atomically(self):
        for mode, budget in (("memory", {"maxMemoryMiB": 64}), ("bytes", {"maxBytes": 1024}),
                             ("nodes", {"maxNodes": 2}), ("depth", {"maxDepth": 0}), ("trace", {})):
            with self.subTest(mode=mode):
                self.assert_failed_request(self.run_jobs(request(mode, **budget)))

    def test_invalid_manifest_fails_discovery_before_target_admission(self):
        packet = manifest(self.root, [request()])
        del next(iter(packet["targets"].values()))["system"]
        result = self.run_jobs(packet=packet)
        self.assertFalse(rows(result, "nx_targets"))
        self.assertTrue(rows(result, "nx_runs"))
        self.assertTrue(rows(result, "nx_diagnostics"))
        self.assertTrue(any(row[1] in ("discovery", "target-discovery") and row[2] == "failed" for row in rows(result, "nx_phases")))

    def test_formats_and_authorization_are_enforced_by_production_boundary(self):
        for mutation in (lambda q: q.update(maxNodes=True), lambda q: q.update(maxSeconds=1.0),
                         lambda q: q.update(path=["é" * 524289]), lambda q: q.update(facet="declarations")):
            packet = manifest(self.root, [request()])
            mutation(next(iter(packet["targets"].values()))["requests"][0])
            result = self.run_jobs(packet=packet)
            self.assertFalse(rows(result, "nx_scalar_values"))
            self.assertTrue(rows(result, "nx_diagnostics"))

    def test_missing_any_opaque_binding_blocks_instead_of_inventing_values(self):
        for reference in tuple(self.bindings):
            with self.subTest(reference=reference):
                saved = self.bindings.pop(reference)
                self.assert_failed_request(self.run_jobs(request()), "blocked")
                self.bindings[reference] = saved


    def test_complete_selected_value_requires_observed_root_value_and_preserves_other_requests(self):
        for mode in ("result-only", "observation-without-value"):
            with self.subTest(mode=mode):
                with self.assertRaises(ExtractionFailed) as raised:
                    self.run_jobs(request(mode), strict=True)
                self.assert_failed_request(raised.exception.packet)
                self.assertEqual(rows(raised.exception.packet, "nx_request_results")[0][2], "projection-incomplete")
                self.assertFalse(rows(raised.exception.packet, "nx_observations"))
                self.assertFalse(rows(raised.exception.packet, "nx_values"))
                packet = self.run_jobs(request("ok"), request(mode), request("binding"))
                self.assertEqual([row[1] for row in rows(packet, "nx_request_results")], ["complete", "failed", "complete"])
                self.assertEqual([row[-1] for row in rows(packet, "nx_scalar_values")], ["true", "true"])
                self.assertEqual(rows(packet, "nx_targets")[0][-1], "partial")

    def test_complete_opaque_empty_container_and_null_values_have_explicit_root_witnesses(self):
        for mode, kind, completeness in (
            ("opaque-function", "function", "opaque"),
            ("empty-attrset", "attrset", "complete"),
            ("empty-list", "list", "complete"),
            ("explicit-null", "null", "complete"),
        ):
            with self.subTest(mode=mode):
                packet = self.run_jobs(request(mode), strict=True)
                self.assertEqual(rows(packet, "nx_request_results")[0][1], "complete")
                self.assertEqual(rows(packet, "nx_values")[0][1:], [kind, completeness])
                self.assertEqual(rows(packet, "nx_observations")[0][2:], ["config-path", json.dumps([mode]), "applied-config", "observed"])
                self.assertEqual(rows(packet, "nx_observation_values")[0][1], rows(packet, "nx_values")[0][0])
                self.assertEqual([row[1:] for row in rows(packet, "nx_scalar_values")], [["null-json-v1", "null"]] if kind == "null" else [])
                self.assertTrue(any("nx_values" in path.read_text() for path in self.trap.glob("*.trap")))

    def test_metadata_members_and_context_requests_cannot_publish_values(self):
        for domain, facet, modes in (
            ("option-metadata", "priority", ["metadata"]),
            ("config", "members", ["selected-value"]),
            ("config", "string-context", ["selected-value", "string-context"]),
            ("option-value", "value", ["selected-value"]),
            ("definition-value", "value", ["selected-value"]),
        ):
            with self.subTest(domain=domain, facet=facet):
                packet = manifest(self.root, [request("ok", domain=domain, facet=facet)])
                target = next(iter(packet["targets"].values()))
                target["evaluation"]["kind"] = "rich-result"
                target["observationModes"] = modes
                self.assert_failed_request(self.run_jobs(packet=packet), "blocked")
                # Same manifest remains usable for an unrelated explicitly authorized request.
                target["requests"].append(request("binding"))
                if "selected-value" not in target["observationModes"]:
                    target["observationModes"].append("selected-value")
                packet = self.run_jobs(packet=packet)
                self.assertEqual([row[1] for row in rows(packet, "nx_request_results")], ["blocked", "complete"])
                self.assertEqual([row[-1] for row in rows(packet, "nx_scalar_values")], ["true"])

    def test_unsupported_request_is_blocked_before_producer_execution(self):
        log = Path(self.temp.name) / "unauthorized-producer"
        self.bindings["module:1"] = {"log": str(log)}
        self.assert_failed_request(self.run_jobs(request("serial", facet="members")), "blocked")
        self.assertFalse(log.exists())

    def test_value_request_cannot_publish_unrequested_string_context(self):
        self.assert_failed_request(self.run_jobs(request("string-context-output")))

    def test_multifield_output_above_exact_text_limit_is_admitted(self):
        packet = self.run_jobs(request("large-fields", maxBytes=2000000, maxDepth=1))
        self.assertEqual(rows(packet, "nx_request_results")[0][1], "complete")
        payloads = [row[-1] for row in rows(packet, "nx_scalar_values")]
        self.assertEqual(payloads, [json.dumps("x" * 600000)] * 2)
        self.assertGreater(sum(len(path.read_bytes()) for path in self.trap.glob("*.trap")), 1048576)

    def test_aggregate_stdout_and_stderr_overflow_are_refused(self):
        for mode in ("large-fields", "large-stderr"):
            with self.subTest(mode=mode):
                packet = self.run_jobs(request(mode, maxBytes=1100000, maxDepth=1))
                self.assert_failed_request(packet)
                self.assertEqual(rows(packet, "nx_request_results")[0][2], "byte-limit")

    def test_oversized_individual_field_refuses_whole_transaction(self):
        packet = self.run_jobs(request("oversized-field", maxBytes=3000000, maxDepth=1))
        self.assert_failed_request(packet)
        self.assertEqual(rows(packet, "nx_request_results")[0][2], "text-field-too-large")
        self.assertFalse(rows(packet, "nx_values"))

    def test_shared_dag_is_bounded_by_graph_size(self):
        # Outer deadline covers Python validation too, unlike the child deadline.
        def expired(*_):
            raise TimeoutError("shared DAG processing exceeded outer test deadline")
        previous = signal.signal(signal.SIGALRM, expired)
        signal.setitimer(signal.ITIMER_REAL, 5)
        try:
            packet = self.run_jobs(request("shared-dag", maxDepth=25, maxNodes=60, maxBytes=1000000))
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
        self.assertEqual(rows(packet, "nx_request_results")[0][1], "complete")
        self.assertEqual(len(rows(packet, "nx_values")), 26)
        self.assertEqual(len(rows(packet, "nx_value_members")), 50)

    def test_cycles_are_refused_and_converging_paths_use_longest_depth(self):
        cycle = self.run_jobs(request("cycle", maxDepth=10, maxBytes=100000))
        self.assert_failed_request(cycle)
        self.assertEqual(rows(cycle, "nx_request_results")[0][2], "projection-invalid")
        self.assertTrue(any("cyclic" in row[-1] for row in rows(cycle, "nx_diagnostics")))
        packet = self.run_jobs(request("unequal-depth", maxDepth=2, maxBytes=100000))
        self.assert_failed_request(packet)
        self.assertEqual(rows(packet, "nx_request_results")[0][2], "depth-limit")
        packet = self.run_jobs(request("unequal-depth", maxDepth=3, maxBytes=100000))
        self.assertEqual(rows(packet, "nx_request_results")[0][1], "complete")
        self.assertEqual(len(rows(packet, "nx_values")), 4)

    def test_lone_surrogate_manifest_publishes_failed_discovery_and_strict_evidence(self):
        packet = manifest(self.root, [request()])
        next(iter(packet["targets"].values()))["argumentDescription"]["hash"] = json.loads('"\\ud800"')
        with self.assertRaises(ExtractionFailed) as raised:
            self.run_jobs(packet=packet, strict=True)
        result = raised.exception.packet
        abi.validate(result["facts"])
        self.assertFalse(rows(result, "nx_targets"))
        self.assertFalse(rows(result, "nx_values"))
        self.assertEqual(next(row[2] for row in rows(result, "nx_phases") if row[1] == "discovery"), "failed")
        self.assertTrue(rows(result, "nx_diagnostics"))
        traps = list(self.trap.glob("*.trap"))
        self.assertTrue(traps)
        for path in traps:
            self.assertIn("nx_phases", path.read_text(encoding="utf-8"))
            self.assertNotIn("nx_scalar_values", path.read_text(encoding="utf-8"))


# Independently spelled F1 rows; `selected` comes from a direct Nix expression.
NIX_PROJECTION = '''{ job }:
let selected = EXPRESSION; i = job.identities;
    key = namespace: "nixql:v1:${namespace}:${toString (builtins.stringLength i.request)}:${i.request}";
in { protocolVersion = 1; facts = [
  [ "nx_request_results" [ i.request "complete" "" 1 ] ]
  [ "nx_observations" [ (key "observation") i.request "config-path" (builtins.toJSON job.request.path) "applied-config" "observed" ] ]
  [ "nx_observation_values" [ (key "observation") (key "value") ] ]
  [ "nx_values" [ (key "value") "boolean" "complete" ] ]
  [ "nx_scalar_values" [ (key "value") "boolean-json-v1" (if selected then "true" else "false") ] ]
]; }
'''


class RealNixTests(ProjectionCase):
    def projection(self, expression):
        self.assertIsNotNone(NIX, "CI must supply a real Nix executable")
        path = self.root / "projection.nix"
        path.write_text(NIX_PROJECTION.replace("EXPRESSION", expression))
        self.bindings["eval:1"] = {"expression": path}

    def test_real_minimal_projection_agrees_with_direct_nix_and_is_lazy(self):
        oracle = subprocess.run([NIX, "--extra-experimental-features", "nix-command", "eval", "--json", "--expr", "let x = { good = true; poison = throw \"unselected\"; }; in x.good"], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(oracle.stdout), True)
        self.projection('let x = { good = true; poison = throw "unselected"; }; in x.good')
        packet = self.run_jobs(request())
        self.assertEqual([row[-1] for row in rows(packet, "nx_scalar_values")], ["true"])

    def test_real_admitted_import_and_argument_bindings(self):
        (self.root / "input.nix").write_text("true")
        self.projection('(import ./input.nix) && job.moduleArguments.sentinel == "module" && job.specialArguments.sentinel == "special"')
        self.assertEqual(rows(self.run_jobs(request()), "nx_scalar_values")[0][-1], "true")

    def test_real_second_admitted_root_is_accessible_by_its_pinned_fetch_tree(self):
        dependency = Path(self.temp.name) / "dependency"
        dependency.mkdir()
        (dependency / "value.nix").write_text("true")
        hashed = subprocess.run([NIX, "--extra-experimental-features", "nix-command", "hash", "path", str(dependency)], capture_output=True, text=True, check=True).stdout.strip()
        self.projection('(import ((builtins.fetchTree { type = "path"; path = ' + json.dumps(str(dependency)) + '; narHash = ' + json.dumps(hashed) + '; }).outPath + "/value.nix"))')
        packet = manifest(self.root, [request()])
        next(iter(packet["targets"].values()))["sourceRoots"].append({
            "logicalName": "dependency", "path": str(dependency), "rootContentIdentity": hashed})
        result = self.run_jobs(packet=packet)
        self.assertEqual(rows(result, "nx_request_results")[0][1], "complete")
        self.assertEqual([row[-1] for row in rows(result, "nx_scalar_values")], ["true"])

    def test_real_throw_is_failure_and_missing_input_is_blocked(self):
        self.projection('throw "fixture selected error"')
        self.assert_failed_request(self.run_jobs(request()), "failed")
        self.projection("import ./not-admitted.nix")
        self.assert_failed_request(self.run_jobs(request()), "blocked")

    def test_real_host_environment_and_undeclared_path_are_not_semantic_inputs(self):
        previous = os.environ.get("NIXQL_PRIVATE_HOST_INPUT")
        os.environ["NIXQL_PRIVATE_HOST_INPUT"] = "secret"
        self.addCleanup(lambda: os.environ.pop("NIXQL_PRIVATE_HOST_INPUT", None) if previous is None else os.environ.__setitem__("NIXQL_PRIVATE_HOST_INPUT", previous))
        self.projection('builtins.getEnv "NIXQL_PRIVATE_HOST_INPUT" == ""')
        self.assertEqual(rows(self.run_jobs(request()), "nx_scalar_values")[0][-1], "true")
        private = Path(self.temp.name) / "private"
        private.write_text("secret")
        self.projection(f'builtins.readFile (builtins.toPath {json.dumps(str(private))}) == "secret"')
        self.assert_failed_request(self.run_jobs(request()), "blocked")

    def test_real_expression_outside_admitted_closure_is_blocked(self):
        self.projection("true")
        outside = Path(self.temp.name) / "outside.nix"
        outside.write_text(NIX_PROJECTION.replace("EXPRESSION", "true"))
        self.bindings["eval:1"] = {"expression": outside}
        self.assert_failed_request(self.run_jobs(request()), "blocked")

    def test_real_network_is_denied_before_loopback_request(self):
        hits = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append(self.path)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"true")

            def log_message(self, *_):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            digest = hashlib.sha256(b"true").hexdigest()
            self.projection(f'builtins.readFile (builtins.fetchurl {{ url = "http://127.0.0.1:{server.server_port}/nixql-e1-{server.server_port}"; sha256 = "{digest}"; }}) == "true"')
            self.assert_failed_request(self.run_jobs(request()), "blocked")
            self.assertEqual(hits, [])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_real_ifd_and_build_are_blocked_without_builder_execution(self):
        marker = self.root / "builder-ran"
        expression = 'import (builtins.derivation { name = "nixql-forbidden-ifd"; system = "x86_64-linux"; builder = "/bin/sh"; args = [ "-c" ' + json.dumps(f"touch {marker}; echo true > $out") + ' ]; })'
        self.projection(expression)
        self.assert_failed_request(self.run_jobs(request()), "blocked")
        self.assertFalse(marker.exists())
        self.assertFalse((self.root / "flake.lock").exists())


if __name__ == "__main__":
    unittest.main()

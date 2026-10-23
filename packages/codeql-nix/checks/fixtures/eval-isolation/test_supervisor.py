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
    return dict(domain="option-metadata", facet="isDefined", path=[mode], maxBytes=16384,
                maxDepth=0, maxMemoryMiB=256, maxNodes=10, maxSeconds=4) | budgets


def manifest(root, requests):
    return {"manifestVersion": 1, "targets": {"literal.[name].with.dots": {
        "adapter": "evalModules", "adapterVersion": "1",
        "argumentDescription": {"hash": "arguments", "moduleArgumentsRef": "module:1", "specialArgumentsRef": "special:1"},
        "evaluation": {"kind": "rich-result", "reference": "eval:1"},
        "fingerprint": {"evaluatorVersion": "pinned-test", "libVersion": "none", "modelVersion": "not-requested", "policyHash": "isolated", "sourceSnapshotHash": "snapshot"},
        "inputIdentities": {"project": "snapshot"}, "observationModes": ["metadata"],
        "requests": requests,
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
        self.assertFalse(rows(packet, "nx_option_metadata"))
        self.assertNotEqual(rows(packet, "nx_targets")[0][-1], "complete")
        self.assertNotEqual(next(row[2] for row in rows(packet, "nx_phases") if row[1] == "evaluation"), "complete")
        for path in self.trap.rglob("*.trap"):
            self.assertNotIn("nx_option_metadata", path.read_text())


class SupervisorTests(ProjectionCase):
    def test_positive_bound_arguments_literal_paths_statuses_and_atomic_handoff(self):
        packet = self.run_jobs(request("binding"), request("a.b"), request("a", path=["a", "b"]))
        self.assertEqual([row[4] for row in rows(packet, "nx_requests")], ['["binding"]', '["a.b"]', '["a","b"]'])
        self.assertEqual(rows(packet, "nx_targets")[0][2], "literal.[name].with.dots")
        self.assertEqual([row[1] for row in rows(packet, "nx_request_results")], ["complete"] * 3)
        self.assertEqual([row[-1] for row in rows(packet, "nx_option_metadata")], ["true"] * 3)
        self.assertTrue(rows(packet, "nx_capabilities"))
        self.assertEqual(rows(packet, "nx_runs")[0][-2], "not-requested")
        self.assertEqual(rows(packet, "nx_targets")[0][-1], "complete")
        traps = list(self.trap.rglob("*.trap"))
        self.assertTrue(traps)
        self.assertTrue(any("nx_option_metadata" in path.read_text() for path in traps))
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
        self.assertEqual(len(rows(packet, "nx_option_metadata")), 2)
        self.assertEqual(rows(packet, "nx_targets")[0][-1], "partial")
        self.assertTrue(any("nx_option_metadata" in path.read_text() for path in self.trap.rglob("*.trap")))

    def test_crashed_malformed_invalid_and_forged_transactions_publish_no_metadata(self):
        for mode in ("crash", "malformed", "invalid-abi", "forge", "foreign-request", "foreign-observation", "foreign-context", "foreign-path", "foreign-origin"):
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
        for mode, budget in (("memory", {"maxMemoryMiB": 64}), ("bytes", {"maxBytes": 1024, "facet": "declarations"}),
                             ("nodes", {"maxNodes": 2}), ("depth", {"maxDepth": 1}), ("trace", {})):
            with self.subTest(mode=mode):
                self.assert_failed_request(self.run_jobs(request(mode, **budget)))

    def test_invalid_manifest_fails_discovery_before_target_admission(self):
        packet = manifest(self.root, [request()])
        del next(iter(packet["targets"].values()))["system"]
        result = self.run_jobs(packet=packet)
        self.assertFalse(rows(result, "nx_targets"))
        self.assertTrue(rows(result, "nx_runs"))
        self.assertEqual(rows(result, "nx_runs")[0][-2], "not-requested")
        self.assertTrue(rows(result, "nx_diagnostics"))
        self.assertTrue(any(row[1] in ("discovery", "target-discovery") and row[2] == "failed" for row in rows(result, "nx_phases")))

    def test_formats_and_authorization_are_enforced_by_production_boundary(self):
        for mutation in (lambda q: q.update(maxNodes=True), lambda q: q.update(maxSeconds=1.0),
                         lambda q: q.update(path=["é" * 524289]), lambda q: q.update(facet="value")):
            packet = manifest(self.root, [request()])
            mutation(next(iter(packet["targets"].values()))["requests"][0])
            result = self.run_jobs(packet=packet)
            self.assertFalse(rows(result, "nx_option_metadata"))
            self.assertTrue(rows(result, "nx_diagnostics"))

    def test_missing_any_opaque_binding_blocks_instead_of_inventing_metadata(self):
        for reference in tuple(self.bindings):
            with self.subTest(reference=reference):
                saved = self.bindings.pop(reference)
                self.assert_failed_request(self.run_jobs(request()), "blocked")
                self.bindings[reference] = saved


    def test_complete_metadata_requires_observed_option_and_preserves_other_requests(self):
        for mode in ("result-only", "observation-without-metadata", "unobserved-metadata"):
            with self.subTest(mode=mode):
                with self.assertRaises(ExtractionFailed) as raised:
                    self.run_jobs(request(mode), strict=True)
                self.assert_failed_request(raised.exception.packet)
                self.assertEqual(rows(raised.exception.packet, "nx_request_results")[0][2], "projection-incomplete")
                self.assertFalse(rows(raised.exception.packet, "nx_observations"))
                self.assertFalse(rows(raised.exception.packet, "nx_options"))
                packet = self.run_jobs(request("ok"), request(mode), request("binding"))
                self.assertEqual([row[1] for row in rows(packet, "nx_request_results")], ["complete", "failed", "complete"])
                self.assertEqual([row[-1] for row in rows(packet, "nx_option_metadata")], ["true", "true"])
                self.assertEqual(rows(packet, "nx_targets")[0][-1], "partial")

    def test_metadata_facets_and_priority_require_their_own_witness(self):
        for facet in ("declarations", "isDefined", "priority"):
            with self.subTest(facet=facet):
                packet = self.run_jobs(request(facet=facet), strict=True)
                self.assertEqual(rows(packet, "nx_request_results")[0][1], "complete")
                self.assertEqual(rows(packet, "nx_observations")[0][-1], "observed")
        self.assert_failed_request(self.run_jobs(request("priority-without-witness", facet="priority")))
        self.assert_failed_request(self.run_jobs(request("unrequested-metadata")))

    def test_nested_request_is_blocked_before_producer_execution(self):
        log = Path(self.temp.name) / "unauthorized-producer"
        self.bindings["module:1"] = {"log": str(log)}
        self.assert_failed_request(self.run_jobs(request("serial", maxDepth=1)), "blocked")
        self.assertFalse(log.exists())

    def test_multifield_output_above_exact_text_limit_is_admitted(self):
        packet = self.run_jobs(request("large-fields", facet="declarations", maxBytes=2000000))
        self.assertEqual(rows(packet, "nx_request_results")[0][1], "complete")
        payloads = [row[1] for row in rows(packet, "nx_origins")]
        self.assertEqual(payloads, ["x" * 600000] * 2)
        self.assertGreater(sum(len(path.read_bytes()) for path in self.trap.glob("*.trap")), 1048576)

    def test_node_budget_counts_metadata_records_without_trusting_reported_count(self):
        packet = self.run_jobs(request("large-fields", facet="declarations", maxBytes=2000000, maxNodes=3))
        self.assertEqual(rows(packet, "nx_request_results")[0][1], "complete")
        self.assertEqual(rows(packet, "nx_request_results")[0][-1], 1)
        self.assertEqual(len(rows(packet, "nx_options")) + len(rows(packet, "nx_option_declarations")), 3)
        packet = self.run_jobs(request("large-fields", facet="declarations", maxBytes=2000000, maxNodes=2))
        self.assert_failed_request(packet)
        self.assertEqual(rows(packet, "nx_request_results")[0][2], "node-limit")

    def test_aggregate_stdout_and_stderr_overflow_are_refused(self):
        for mode in ("large-fields", "large-stderr"):
            with self.subTest(mode=mode):
                packet = self.run_jobs(request(mode, facet="declarations", maxBytes=1100000))
                self.assert_failed_request(packet)
                self.assertEqual(rows(packet, "nx_request_results")[0][2], "byte-limit")

    def test_oversized_individual_field_refuses_whole_transaction(self):
        packet = self.run_jobs(request("oversized-field", facet="declarations", maxBytes=3000000))
        self.assert_failed_request(packet)
        self.assertEqual(rows(packet, "nx_request_results")[0][2], "text-field-too-large")
        self.assertFalse(rows(packet, "nx_options"))

    def test_lone_surrogate_manifest_publishes_failed_discovery_and_strict_evidence(self):
        packet = manifest(self.root, [request()])
        next(iter(packet["targets"].values()))["argumentDescription"]["hash"] = json.loads('"\\ud800"')
        with self.assertRaises(ExtractionFailed) as raised:
            self.run_jobs(packet=packet, strict=True)
        result = raised.exception.packet
        abi.validate(result["facts"])
        self.assertFalse(rows(result, "nx_targets"))
        self.assertFalse(rows(result, "nx_options"))
        self.assertEqual(next(row[2] for row in rows(result, "nx_phases") if row[1] == "discovery"), "failed")
        self.assertTrue(rows(result, "nx_diagnostics"))
        traps = list(self.trap.glob("*.trap"))
        self.assertTrue(traps)
        for path in traps:
            self.assertIn("nx_phases", path.read_text(encoding="utf-8"))
            self.assertNotIn("nx_option_metadata", path.read_text(encoding="utf-8"))


# Independently spelled metadata rows; `selected` comes from a direct Nix expression.
NIX_PROJECTION = '''{ job }:
let selected = EXPRESSION; i = job.identities;
    key = namespace: "nixql:v1:${namespace}:${toString (builtins.stringLength i.request)}:${i.request}";
in { protocolVersion = 1; facts = [
  [ "nx_request_results" [ i.request "complete" "" 1 ] ]
  [ "nx_observations" [ (key "observation") i.request "pre-apply-metadata" "observed" ] ]
  [ "nx_observation_options" [ (key "observation") (key "option") ] ]
  [ "nx_options" [ (key "option") i.context (builtins.toJSON job.request.path) ] ]
  [ "nx_option_metadata" [ (key "option") "isDefined" (if selected then "true" else "false") ] ]
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
        self.assertEqual([row[-1] for row in rows(packet, "nx_option_metadata")], ["true"])

    def test_real_admitted_import_and_argument_bindings(self):
        (self.root / "input.nix").write_text("true")
        self.projection('(import ./input.nix) && job.moduleArguments.sentinel == "module" && job.specialArguments.sentinel == "special"')
        self.assertEqual(rows(self.run_jobs(request()), "nx_option_metadata")[0][-1], "true")

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
        self.assertEqual([row[-1] for row in rows(result, "nx_option_metadata")], ["true"])

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
        self.assertEqual(rows(self.run_jobs(request()), "nx_option_metadata")[0][-1], "true")
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

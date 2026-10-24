"""Bounded M3n producer and supervisor controls.

The upstream controls are direct `lib.evalModules` witnesses. Supervisor cases
reuse the existing E1 harness; no second evaluator or production oracle is
introduced here.
"""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

OWNER = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(OWNER / "src/eval"))
import supervisor as eval_supervisor
FIXTURE = OWNER / "checks/fixtures/eval-isolation/test_supervisor.py"
spec = importlib.util.spec_from_file_location("nested_controls_supervisor", FIXTURE)
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

STEP = {"option": ["services"], "memberKind": "attribute", "memberKey": "a.b"}


def relation(packet, name):
    return [arguments for relation, arguments in packet["facts"] if relation == name]


def request_row(packet, path):
    return next(arguments for arguments in relation(packet, "nx_requests")
                if arguments[4] == json.dumps(path, ensure_ascii=False, separators=(",", ":")))


class SupervisorControls(base.ProjectionCase):
    def assert_nested_refusal(self, packet, nested_path, state, reason):
        nested = request_row(packet, nested_path)
        root = request_row(packet, ["ok"])
        results = {arguments[0]: arguments for arguments in relation(packet, "nx_request_results")}
        self.assertEqual(results[nested[0]][1:4], [state, reason, 0])
        self.assertEqual(results[root[0]][1:4], ["complete", "", 1])
        self.assertEqual(nested[2], root[2])
        self.assertEqual([row for row in relation(packet, "nx_contexts") if row[2] != "root"], [])
        self.assertEqual(relation(packet, "nx_context_parents"), [])
        self.assertEqual(relation(packet, "nx_targets")[0][-1], "partial")

    def test_disallowed_deep_chain_never_calls_its_constructor(self):
        calls = []
        original = eval_supervisor.context_chain

        def constructor(*arguments):
            calls.append(arguments)
            return original(*arguments)

        deep = base.request("ok", facet="isDefined", maxDepth=0, maxNodes=0,
                            maxBytes=1048576, path=["answer"])
        deep["contextPath"] = [STEP] * 20
        with patch.object(eval_supervisor, "context_chain", constructor):
            packet = self.run_jobs(deep, base.request("ok", facet="isDefined"))
        self.assertEqual(calls, [])
        self.assert_nested_refusal(packet, ["answer"], "failed", "depth-limit")

    def test_allowed_deep_chain_is_byte_bounded_before_large_rows(self):
        calls = []
        key_lengths = []
        key_total = [0]
        original = eval_supervisor.context_chain
        original_key = eval_supervisor.abi.key

        after_cap = [0]

        def bounded_key(namespace, parts):
            limit = calls[-1][-1]
            # Exact framed size, computed before the key is allocated.
            projected = len(f"nixql:v1:{namespace}:") + sum(
                len(str(len(part.encode()))) + 1 + len(part.encode()) for part in parts)
            # A parent within budget bounds its child; only the crossing step's last key may follow.
            if key_total[0] > limit:
                after_cap[0] += 1
            if projected > 3 * limit or after_cap[0] > 1:
                raise AssertionError("context key allocated beyond the byte budget")
            value = original_key(namespace, parts)
            key_lengths.append(len(value.encode()))
            key_total[0] += key_lengths[-1]
            return value

        def constructor(*arguments):
            calls.append(arguments)
            with patch.object(eval_supervisor.abi, "key", bounded_key):
                return original(*arguments)

        deep = base.request("ok", facet="isDefined", maxDepth=20, maxNodes=41,
                            maxBytes=4096, path=["answer"])
        deep["contextPath"] = [STEP] * 20
        with patch.object(eval_supervisor, "context_chain", constructor):
            packet = self.run_jobs(deep, base.request("ok", facet="isDefined"))
        self.assertEqual(len(calls), 1)
        self.assertLessEqual(max(key_lengths), 3 * 4096)
        self.assertLessEqual(key_total[0], 4 * 4096)
        self.assertLess(len(key_lengths), 2 * len(deep["contextPath"]))
        self.assert_nested_refusal(packet, ["answer"], "failed", "byte-limit")

    def test_nested_text_overflow_is_atomic_and_root_survives(self):
        nested = base.request("oversized-field", facet="declarations", maxDepth=1,
                              maxNodes=10, maxBytes=3145728, path=["oversized-field"])
        nested["contextPath"] = [STEP]
        packet = self.run_jobs(nested, base.request("ok", facet="isDefined"))
        self.assert_nested_refusal(packet, ["oversized-field"], "failed", "text-field-too-large")

    def test_nested_deadline_is_atomic_and_root_survives(self):
        nested = base.request("timeout", facet="isDefined", maxDepth=1, maxNodes=10,
                              maxBytes=1048576, maxSeconds=1, path=["timeout"])
        nested["contextPath"] = [STEP]
        packet = self.run_jobs(nested, base.request("ok", facet="isDefined"))
        self.assert_nested_refusal(packet, ["timeout"], "failed", "timeout")

    def test_nested_source_policy_failure_is_atomic_and_root_survives(self):
        outside = Path(self.temp.name) / "outside.nix"
        outside.write_text("true")
        # Unrestricted Nix reads it, so only the admission policy can refuse it.
        direct = subprocess.run([base.NIX, "--extra-experimental-features", "nix-command", "eval",
                                 "--json", "--file", str(outside)], capture_output=True, text=True)
        self.assertEqual((direct.returncode, direct.stdout.strip()), (0, "true"), direct.stderr)
        projection = self.root / "projection.nix"
        projection.write_text(base.NIX_PROJECTION.replace(
            "EXPRESSION",
            "(if job.request ? contextPath then import (builtins.toPath " + json.dumps(str(outside)) +
            ") else true)",
        ))
        self.bindings["eval:1"] = {"expression": projection}
        nested = base.request("source-policy", facet="isDefined", maxDepth=1,
                              maxNodes=10, path=["source-policy"])
        nested["contextPath"] = [STEP]
        packet = self.run_jobs(nested, base.request("ok", facet="isDefined"))
        self.assert_nested_refusal(packet, ["source-policy"], "blocked", "evaluation-blocked")


class RealAdapterControls(base.ProjectionCase):
    def setUp(self):
        super().setUp()
        self.source = Path(tempfile.mkdtemp(prefix="nested-controls-", dir=self.temp.name))
        self.adapter = self.source / "adapter.nix"
        shutil.copy(OWNER / "src/eval/nix/modules.nix", self.adapter)
        adapters = self.source / "adapters"
        adapters.mkdir()
        shutil.copy(OWNER / "src/eval/nix/adapters/evalModules.nix", adapters / "evalModules.nix")
        (self.source / "options.nix").write_text('''{lib, ...}: {
          options.services = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options.answer = lib.mkOption { type = lib.types.int; };
            });
          };
          options.lazy = lib.mkOption {
            type = lib.types.lazyAttrsOf (lib.types.submodule {
              options.answer = lib.mkOption { type = lib.types.int; };
            });
          };
          options.items = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options.answer = lib.mkOption { type = lib.types.int; };
            });
          };
          options.nested = lib.mkOption {
            type = lib.types.submodule {
              options.inner = lib.mkOption {
                type = lib.types.submodule {
                  options.answer = lib.mkOption { type = lib.types.int; };
                };
              };
            };
          };
        }''')
        (self.source / "values.nix").write_text('''{ ... }: {
          _file = "values.nix";
          config.services."a.b".answer = 7;
          config.services.poison.answer = throw "unselected sibling";
          config.lazy."a.b".answer = 5;
          config.lazy.poison = throw "lazy sibling";
          config.items = [{answer = 10;} {answer = 20;}];
          config.nested.inner.answer = 11;
        }''')

    def nix_json(self, arguments, expression):
        result = subprocess.run([
            base.NIX, "--extra-experimental-features", "nix-command", "eval", "--json",
            "--impure", "--expr", expression,
        ], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        return json.loads(result.stdout)

    def upstream(self):
        arguments = {
            "nixpkgs": os.environ["CODEQL_NIX_TEST_NIXPKGS"],
            "source": str(self.source),
        }
        encoded = json.dumps(json.dumps(arguments))
        return self.nix_json(
            arguments,
            '(import ' + json.dumps(str(Path(__file__).with_name("controls-oracle.nix"))) +
            ' (builtins.fromJSON ' + encoded + '))',
        )

    def adapter_facts(self, case, request_value):
        identity = "nixql:v1:request:" + str(len(case.encode())) + ":" + case
        job = {
            "identities": {
                "context": "nixql:v1:context:1:c",
                "model": "nixql:v1:run:1:m",
                "request": identity,
                "run": "nixql:v1:run:1:r",
                "target": "nixql:v1:target:1:t",
            },
            "request": request_value,
        }
        encoded = json.dumps(json.dumps(job))
        expression = (
            'let lib = import ' + json.dumps(os.environ["CODEQL_NIX_TEST_NIXPKGS"] + "/lib") +
            '; modules = [ ' + json.dumps(str(self.source / "options.nix")) + ' ' +
            json.dumps(str(self.source / "values.nix")) +
            ' ]; job = builtins.fromJSON ' + encoded +
            '; in import ' + json.dumps(str(self.adapter)) + ' { inherit lib modules job; }'
        )
        return self.nix_json(job, expression)["facts"]

    def selected(self, context, path, *, max_depth=1, max_nodes=4):
        return {
            "contextPath": context,
            "domain": "option-metadata",
            "facet": "selection",
            "maxBytes": 1048576,
            "maxDepth": max_depth,
            "maxMemoryMiB": 1024,
            "maxNodes": max_nodes,
            "maxSeconds": 30,
            "path": path,
        }

    def test_explicit_root_and_huge_index_are_real_adapter_behavior(self):
        huge = self.selected(
            [{"option": ["items"], "memberKind": "index", "memberKey": "9223372036854775808"}],
            ["answer"],
        )
        huge["facet"] = "isDefined"
        facts = self.adapter_facts("huge", huge)
        self.assertEqual([row[1][1:4] for row in facts if row[0] == "nx_request_results"],
                         [["failed", "instance-unavailable", 0]])
        self.assertFalse([row for row in facts if row[0] in {
            "nx_contexts", "nx_context_parents", "nx_options", "nx_option_metadata",
        }])
        self.assertFalse(self.upstream()["hugeIndex"]["hugeInRange"])

    def test_sibling_throw_lazy_absence_and_multi_step_match_upstream(self):
        upstream = self.upstream()
        sibling = self.adapter_facts("sibling", self.selected([STEP], ["answer"]))
        self.assertEqual([row[1][1:4] for row in sibling if row[0] == "nx_request_results"],
                         [["complete", "", 4]])
        self.assertEqual([row[1][2] for row in sibling if row[0] == "nx_option_metadata"], ["true"])
        self.assertFalse(upstream["siblingThrow"]["valueSuccess"])

        lazy_step = {"option": ["lazy"], "memberKind": "attribute", "memberKey": "absent"}
        absent = self.adapter_facts("lazy-absent", self.selected([lazy_step], ["answer"]))
        self.assertEqual([row[1][1:4] for row in absent if row[0] == "nx_request_results"],
                         [["failed", "instance-unavailable", 0]])
        self.assertFalse([row for row in absent if row[0] in {"nx_options", "nx_option_metadata"}])
        self.assertFalse(upstream["lazyAbsent"]["present"])
        self.assertFalse(upstream["lazyAbsent"]["valueSuccess"])

        multi_steps = [
            {"option": ["nested"], "memberKind": "submodule", "memberKey": ""},
            {"option": ["inner"], "memberKind": "submodule", "memberKey": ""},
        ]
        multi = self.adapter_facts(
            "multi", self.selected(multi_steps, ["answer"], max_depth=2, max_nodes=10),
        )
        expected = upstream["multiStep"]
        # Final option, its definitions, and one context plus one traversal option per step.
        self.assertEqual([row[1][1:4] for row in multi if row[0] == "nx_request_results"],
                         [["complete", "", 1 + len(expected["definitions"]) + 2 * len(multi_steps)]])
        self.assertEqual([row[1][2] for row in multi if row[0] == "nx_option_metadata"],
                         [json.dumps(expected["isDefined"])])
        self.assertEqual([row[1][1] for row in multi if row[0] == "nx_option_priority"], [expected["priority"]])
        labels = {row[1][0]: row[1][1] for row in multi if row[0] == "nx_origins"}
        self.assertEqual([labels[row[1][3]] for row in sorted(
            (row for row in multi if row[0] == "nx_definitions"), key=lambda row: row[1][2])],
            expected["definitions"])
        self.assertEqual(expected["value"], 11)


def load_tests(loader, tests, pattern):
    controls = [
        SupervisorControls(name) for name in (
            "test_disallowed_deep_chain_never_calls_its_constructor",
            "test_allowed_deep_chain_is_byte_bounded_before_large_rows",
            "test_nested_text_overflow_is_atomic_and_root_survives",
            "test_nested_deadline_is_atomic_and_root_survives",
            "test_nested_source_policy_failure_is_atomic_and_root_survives",
        )
    ]
    real = [
        RealAdapterControls(name) for name in (
            "test_explicit_root_and_huge_index_are_real_adapter_behavior",
            "test_sibling_throw_lazy_absence_and_multi_step_match_upstream",
        )
    ]
    return unittest.TestSuite(controls + real)


if __name__ == "__main__":
    unittest.main()

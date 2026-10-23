"""E2a contract-first metadata oracles; no selected value is evaluated."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

OWNER = Path(__file__).resolve().parents[3]
FIXTURE = OWNER / "checks/fixtures/eval-isolation/test_supervisor.py"
spec = importlib.util.spec_from_file_location("isolation_fixture", FIXTURE)
previous = importlib.util.module_from_spec(spec)
spec.loader.exec_module(previous)


def expression(setup, job):
    return 'let ' + setup + ' in import ' + str(OWNER / "src/eval/nix/modules.nix") + ' { inherit lib modules; moduleArguments = {}; specialArguments = {}; job = builtins.fromJSON ' + json.dumps(json.dumps(job)) + '; }'


class ModulesTests(previous.ProjectionCase):
    def setUp(self):
        super().setUp()
        self.store = f"local?store={self.temp.name}/store&state={self.temp.name}/state&log={self.temp.name}/log"
        self.bindings["eval:1"] = {"command": [sys.executable, str(Path(__file__).with_name("producer.py"))]}

    def assert_typed_subjects(self, packet):
        observations = previous.rows(packet, "nx_observations")
        links = previous.rows(packet, "nx_observation_options") + previous.rows(packet, "nx_observation_definitions")
        self.assertTrue(observations)
        self.assertEqual(len({row[0] for row in observations}), len(observations))
        self.assertCountEqual([row[0] for row in links], [row[0] for row in observations])
        for observation in observations:
            self.assertEqual(len(observation), 4)
            self.assertEqual(observation[2:], ["pre-apply-metadata", "observed"])
        for relation, entities in (("nx_observation_definitions", "nx_definitions"), ("nx_observation_options", "nx_options")):
            self.assertCountEqual([row[1] for row in previous.rows(packet, relation)],
                                  [row[0] for row in previous.rows(packet, entities)])

    def test_definitions_are_observed_and_contiguous_without_values(self):
        packet = self.run_jobs(previous.request("ok", facet="definitions"), previous.request("ok", facet="definitions"), strict=True)
        self.assertEqual([[row[2] for row in previous.rows(packet, "nx_definitions") if row[1] == option[0]] for option in previous.rows(packet, "nx_options")], [[0, 1], [0, 1]])
        self.assertEqual([row[1] for row in previous.rows(packet, "nx_request_results")], ["complete"] * 2)
        self.assert_typed_subjects(packet)
        self.assertFalse(previous.rows(packet, "nx_option_priority"))
        self.assertTrue(any("nx_definitions" in path.read_text() for path in self.trap.glob("*.trap")))

    def test_definition_node_budget_at_and_over_counts_actual_rows(self):
        packet = self.run_jobs(previous.request("ok", facet="definitions", maxNodes=3), strict=True)
        self.assertEqual(len(previous.rows(packet, "nx_options")) + len(previous.rows(packet, "nx_definitions")), 3)
        packet = self.run_jobs(previous.request("ok", facet="definitions", maxNodes=2))
        self.assert_failed_request(packet)
        self.assertEqual(previous.rows(packet, "nx_request_results")[0][2], "node-limit")
        self.assertFalse(previous.rows(packet, "nx_definitions"))

    def test_definition_ordinal_and_foreign_origin_transactions_are_rejected(self):
        for mode in ("gap", "duplicate", "starts-one", "foreign-origin", "detached-origin", "foreign-request", "foreign-target", "foreign-context", "no-witness"):
            with self.subTest(mode=mode):
                packet = self.run_jobs(previous.request(mode, facet="definitions"))
                self.assert_failed_request(packet)
                self.assertFalse(previous.rows(packet, "nx_definitions"))
                self.assertFalse(previous.rows(packet, "nx_options"))

    def test_missing_foreign_or_repeated_subject_links_refuse_atomically(self):
        self.assert_typed_subjects(self.run_jobs(previous.request("ok", facet="definitions"), strict=True))
        modes = ("duplicate-definition-observation", "duplicate-option-observation", "duplicate-subject-link",
                 "foreign-definition-link", "foreign-observation-link", "foreign-option-link",
                 "missing-definition-link", "missing-definition-observation", "missing-option-link",
                 "mixed-subject-links", "wrong-definition-sibling")
        for mode in modes:
            with self.subTest(mode=mode):
                refused = self.run_jobs(previous.request(mode, facet="definitions"))
                self.assert_failed_request(refused)
                for relation in ("nx_definitions", "nx_observation_definitions", "nx_observation_options", "nx_observations", "nx_options"):
                    self.assertFalse(previous.rows(refused, relation), relation)
                    for path in self.trap.glob("*.trap"):
                        self.assertNotIn(relation + "(", path.read_text())
                packet = self.run_jobs(previous.request("ok", facet="definitions"), previous.request(mode, facet="definitions"), previous.request("ok", facet="definitions"))
                results = previous.rows(packet, "nx_request_results")
                self.assertEqual([row[1] for row in results], ["complete", "failed", "complete"])
                self.assertEqual(len(previous.rows(packet, "nx_options")), 2)
                self.assertEqual(len(previous.rows(packet, "nx_definitions")), 4)
                self.assert_typed_subjects(packet)
                self.assertTrue(previous.rows(packet, "nx_diagnostics"))
                self.assertEqual(previous.rows(packet, "nx_targets")[0][-1], "partial")
                projected = [path.read_text() for path in self.trap.glob("*.trap") if "nx_observations(" in path.read_text()]
                self.assertEqual(len(projected), 2)
                self.assertTrue(all(results[1][0] not in text for text in projected))

    def test_definition_depth_root_at_and_over_and_refusal_preserves_other_request(self):
        packet = self.run_jobs(previous.request("ok", facet="definitions", maxDepth=0), strict=True)
        self.assertEqual(previous.rows(packet, "nx_request_results")[0][1], "complete")
        for mode, budget in (("ok", {"maxDepth": 1}), ("oversized", {"maxBytes": 3000000}), ("timeout", {"maxSeconds": 1})):
            with self.subTest(mode=mode):
                packet = self.run_jobs(previous.request("ok", facet="definitions"), previous.request(mode, facet="definitions", **budget))
                self.assertEqual([row[1] for row in previous.rows(packet, "nx_request_results")][0], "complete")
                self.assertNotEqual(previous.rows(packet, "nx_request_results")[1][1], "complete")
                self.assertEqual(len(previous.rows(packet, "nx_definitions")), 2)
                self.assertEqual(previous.rows(packet, "nx_targets")[0][-1], "partial")

    def nix(self, expression, succeeds=True):
        result = subprocess.run([previous.NIX, "--store", self.store, "--extra-experimental-features", "nix-command", "eval", "--json", "--impure", "--expr", expression], capture_output=True, text=True, timeout=30)
        if not succeeds:
            self.assertNotEqual(result.returncode, 0)
            return result.stderr
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def fixture(self, override="lib.mkDefault", label=None):
        sources = {
            "default.nix": '{lib,...}: { demo.answer = ' + override + ' 23; }',
            "options.nix": '{lib,...}: { options.demo.answer = lib.mkOption { type = lib.types.int; apply = _: throw "post-apply sentinel"; }; options.demo.poison = lib.mkOption { type = lib.types.int; }; options.demo.unset = lib.mkOption { type = lib.types.int; }; options."a.b" = lib.mkOption { type = lib.types.int; }; }',
            "ordinary.nix": '{...}: let hidden = 17; in { demo.poison = throw "unselected sentinel"; demo.answer = hidden; "a.b" = hidden; }',
        }
        if label:
            sources["default.nix"] = '{lib,...}: { _file = ' + json.dumps(label) + '; demo.answer = lib.mkOverride 50 23; }'
        for name, text in sources.items():
            (self.root / name).write_text(text)
        paths = "[ " + " ".join(str(self.root / name) for name in sources) + " ]"
        return 'lib = import ' + os.environ["CODEQL_NIX_TEST_LIB"] + '; modules = ' + paths + ';'

    def project(self, setup, facet, path=None, succeeds=True):
        ids = {name: previous.abi.key(name, ["fixture"]) for name in ("context", "request", "run", "target")}
        request = previous.request(facet=facet, path=path or ["demo", "answer"])
        job = {"identities": ids, "request": request, "moduleArguments": {}, "specialArguments": {}}
        packet = self.nix(expression(setup, job), succeeds)
        if succeeds and previous.rows(packet, "nx_request_results")[0][1] == "complete":
            self.assert_typed_subjects(packet)
        return packet

    def test_real_module_files_declarations_and_priority_match_independent_nix_oracle(self):
        for override, selected, priority in (("lib.mkDefault", "ordinary.nix", "100"), ("lib.mkOverride 50", "default.nix", "50"), ("lib.mkOverride (-7)", "default.nix", "-7")):
            with self.subTest(override=override):
                setup = self.fixture(override)
                oracle = self.nix('let ' + setup + ' result = lib.evalModules { inherit modules; }; option = result.options.demo.answer; in { files = map (d: d.file) option.definitionsWithLocations; declarations = option.declarations; priority = toString option.highestPrio; }')
                self.assertEqual(oracle, {"files": [str(self.root / selected)], "declarations": [str(self.root / "options.nix")], "priority": priority})
                for facet, relation, index, expected in (("definitions", "nx_definitions", 3, oracle["files"]), ("declarations", "nx_option_declarations", 2, oracle["declarations"])):
                    packet = self.project(setup, facet)
                    origins = {row[0]: row[1] for row in previous.rows(packet, "nx_origins")}
                    self.assertEqual([origins[row[index]] for row in previous.rows(packet, relation)], expected)
                    self.assertEqual(previous.rows(packet, "nx_request_results")[0][1], "complete")
                packet = self.project(setup, "priority")
                self.assertEqual([row[1] for row in previous.rows(packet, "nx_option_priority")], [priority])
                self.assertEqual([row[2] for row in previous.rows(packet, "nx_option_metadata")], ["true"])

    def test_equal_priority_retains_both_definitions_and_literal_segments(self):
        setup = self.fixture("lib.mkOverride 100")
        packet = self.project(setup, "definitions")
        origins = {row[0]: row[1] for row in previous.rows(packet, "nx_origins")}
        self.assertEqual(sorted(origins[row[3]] for row in previous.rows(packet, "nx_definitions")), sorted(str(self.root / name) for name in ("ordinary.nix", "default.nix")))
        self.assertEqual(sorted(row[2] for row in previous.rows(packet, "nx_definitions")), [0, 1])
        packet = self.project(setup, "definitions", ["a.b"])
        self.assertEqual([row[2] for row in previous.rows(packet, "nx_options")], ['["a.b"]'])
        self.assertEqual(len(previous.rows(packet, "nx_definitions")), 1)

    def test_undefined_and_missing_option_never_manufacture_successful_priority(self):
        setup = self.fixture()
        packet = self.project(setup, "isDefined", ["demo", "unset"])
        self.assertEqual([row[2] for row in previous.rows(packet, "nx_option_metadata")], ["false"])
        for path in (["demo", "missing"], ["a", "b"]):
            packet = self.project(setup, "priority", path)
            self.assertFalse(previous.rows(packet, "nx_option_priority"))
            self.assertNotEqual(previous.rows(packet, "nx_request_results")[0][1], "complete")

    def test_empty_definitions_and_is_defined_keep_one_option_subject(self):
        setup = self.fixture()
        for facet in ("definitions", "isDefined"):
            with self.subTest(facet=facet):
                packet = self.project(setup, facet, ["demo", "unset"])
                self.assertEqual(previous.rows(packet, "nx_request_results")[0][1], "complete")
                self.assertEqual(len(previous.rows(packet, "nx_observation_options")), 1)
                self.assertFalse(previous.rows(packet, "nx_observation_definitions"))
                self.assertFalse(previous.rows(packet, "nx_definitions"))

    def test_synthetic_file_label_never_establishes_source_identity(self):
        packet = self.project(self.fixture(label="synthetic-module"), "definitions")
        origins = {row[0]: row for row in previous.rows(packet, "nx_origins")}
        definitions = previous.rows(packet, "nx_definitions")
        self.assertEqual([origins[row[3]][1] for row in definitions], ["synthetic-module"])
        self.assertFalse(previous.rows(packet, "nx_origin_files"))

    def test_module_throw_and_missing_input_refuse_without_value_serialization(self):
        setup = self.fixture()
        (self.root / "ordinary.nix").write_text('throw "selected module failure sentinel"')
        self.assertIn("selected module failure sentinel", self.project(setup, "definitions", succeeds=False))
        setup = 'lib = import ' + os.environ["CODEQL_NIX_TEST_LIB"] + '; modules = [ ' + str(self.root / "absent-module.nix") + ' ];'
        self.assertIn("absent-module.nix", self.project(setup, "definitions", succeeds=False))

    def authenticate(self, setup, facet="definitions", mutate=None, label=None):
        copied = Path(tempfile.mkdtemp(dir=self.temp.name)) / "copy"
        shutil.copytree(self.root, copied)
        files = [["nx_files", [previous.abi.key("file", [previous.abi.key("root", ["project", "snapshot"]), path.name, hashlib.sha256(path.read_bytes()).hexdigest()]), previous.abi.key("root", ["project", "snapshot"]), path.name, hashlib.sha256(path.read_bytes()).hexdigest(), "project"]] for path in sorted(self.root.glob("*.nix"))]
        if label is not None:
            (copied / "default.nix").write_text('{lib,...}: { ' + label + ' }')
        if mutate:
            mutate(copied)
        tree = 'builtins.path { path = ' + str(copied) + '; name = "e2a-copy"; }'
        store_copy = self.nix(tree)
        self.copied_filename = store_copy + "/ordinary.nix"
        mappings = {store_copy + "/" + row[1][2]: row[1][0] for row in files}
        for row in files:
            setup = setup.replace(str(self.root / row[1][2]), '((' + tree + ') + ' + json.dumps('/' + row[1][2]) + ')')
        self.bindings["module:1"] = {"moduleFixture": {"adapter": str(OWNER / "src/eval/nix/modules.nix"), "nix": str(previous.NIX), "setup": setup, "store": self.store}}
        query = [previous.request("module", facet=part, path=["demo", "answer"], maxSeconds=30, maxMemoryMiB=1024) for part in ([facet] if isinstance(facet, str) else facet)]
        self.trap = Path(tempfile.mkdtemp(dir=self.temp.name))
        return previous.supervise(previous.manifest(self.root, query), self.bindings, self.trap, source_files=files, source_mappings=mappings, nix=previous.NIX)

    def test_authenticated_original_and_matching_nix_copy_link_actual_definition_and_declaration(self):
        packet = self.authenticate(self.fixture(), ("definitions", "declarations", "priority"))
        self.assertEqual([row[1] for row in previous.rows(packet, "nx_request_results")], ["complete"] * 3, previous.rows(packet, "nx_diagnostics"))
        files = {row[0]: row[2] for row in previous.rows(packet, "nx_files")}
        self.assertEqual([files[row[1]] for row in previous.rows(packet, "nx_origin_files")], ["ordinary.nix", "options.nix"])
        self.assertEqual([row[1] for row in previous.rows(packet, "nx_option_priority")], ["100"])
        self.assertTrue(previous.rows(packet, "nx_target_inputs"))
        previous.abi.validate(packet["facts"])
        self.assert_typed_subjects(packet)

    def test_changed_nix_copy_refuses_without_publishing_definition_or_source_link(self):
        packet = self.authenticate(self.fixture(), mutate=lambda copy: (copy / "ordinary.nix").write_text('{...}: { demo.answer = 18; }'))
        self.assert_failed_request(packet)
        self.assertFalse(previous.rows(packet, "nx_definitions"))
        self.assertFalse(previous.rows(packet, "nx_origin_files"))

    def test_explicit_file_even_matching_admitted_path_cannot_authenticate(self):
        for label in ("_file = toString ./ordinary.nix; demo.answer = lib.mkOverride 50 23;", "_file = ./ordinary.nix; demo.answer = lib.mkOverride 50 23;", 'demo.answer = lib.mkDefinition { file = "${builtins.path { path = ./.; name = "e2a-copy"; }}/ordinary.nix"; value = lib.mkOverride 50 23; };'):
            packet = self.authenticate(self.fixture(), label=label)
            self.assertEqual(previous.rows(packet, "nx_request_results")[0][1], "complete")
            self.assertEqual(len(previous.rows(packet, "nx_definitions")), 1)
            self.assertEqual([row[1] for row in previous.rows(packet, "nx_origins")], [self.copied_filename])
            self.assertFalse(previous.rows(packet, "nx_origin_files"))

    def test_producer_cannot_forge_file_admission_or_source_links(self):
        root = previous.abi.key("root", ["project", "snapshot"])
        file = [previous.abi.key("file", [root, "forged.nix", "digest"]), root, "forged.nix", "digest", "project"]
        for relation in ("nx_files", "nx_origin_files", "nx_target_inputs"):
            self.bindings["module:1"] = {"file": file, "forged": relation}
            self.trap = Path(tempfile.mkdtemp(dir=self.temp.name))
            packet = previous.supervise(previous.manifest(self.root, [previous.request("forged-source", facet="definitions")]), self.bindings, self.trap, source_files=[] if relation == "nx_files" else [["nx_files", file]])
            self.assert_failed_request(packet)
            self.assertFalse(previous.rows(packet, "nx_definitions"))
            self.assertFalse(previous.rows(packet, relation) if relation != "nx_files" else [row for row in previous.rows(packet, relation) if row[0] == file[0]])

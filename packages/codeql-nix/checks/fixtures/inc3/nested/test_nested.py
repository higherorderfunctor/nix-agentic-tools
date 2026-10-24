"""M3n contract tests; expectations precede producer implementation.

The Nix oracle imports only the pinned upstream library. Packet expectations
cover schema admission, typed context identity, atomic refusal and transport.
"""

from copy import deepcopy
import csv
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest

from jsonschema import Draft202012Validator, ValidationError

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "abi"))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "installed"))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "protocol"))
import golden
import test_installed
from examples import MANIFEST
from test_protocol import FORMATS

OWNER = Path(__file__).resolve().parents[4]
SCHEMA_DIR = Path(__file__).resolve().parents[4] / "schema"
SPEC = importlib.util.spec_from_file_location("nested_abi", SCHEMA_DIR / "abi.py")
abi = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(abi)
LIMIT = 1048576
ATTRIBUTE_STEP = {"option": ["services"], "memberKind": "attribute", "memberKey": "a.b"}
OTHER_STEP = {"option": ["services"], "memberKind": "attribute", "memberKey": "other"}
CONTEXT_JSON = json.dumps([ATTRIBUTE_STEP], ensure_ascii=False, separators=(",", ":"))
OTHER_CONTEXT_JSON = json.dumps([OTHER_STEP], ensure_ascii=False, separators=(",", ":"))

SOURCES = {
    "direct": '{...}: { _file="direct.nix"; config.unit.answer=42; }',
    "direct-options": '{lib,...}: { options.unit=lib.mkOption { type=lib.types.submodule { options.answer=lib.mkOption { type=lib.types.int; }; }; }; }',
    "first": '{...}: { _file="first.nix"; config.items=[{answer=10;}]; }',
    "hosts": '{...}: { _file="hosts.nix"; config.services."a.b".answer=7; config.services.other.answer=8; }',
    "freeform-options": '{lib,...}: { options.services=lib.mkOption { type=lib.types.attrsOf lib.types.anything; }; config.services."a.b".answer=1; }',
    "list-options": '{lib,...}: { options.items=lib.mkOption { type=lib.types.listOf (lib.types.submodule { options.answer=lib.mkOption { type=lib.types.int; }; }); }; }',
    "options": '{lib,...}: { options.services=lib.mkOption { apply=_: throw "outer apply"; type=lib.types.attrsOf (lib.types.submodule { options.answer=lib.mkOption { type=lib.types.int; }; }); }; }',
    "second": '{...}: { _file="second.nix"; config.items=[{answer=20;}]; }',
}

# Semantic keys group fresh physical request/context/option bindings.
REQUEST_CONTEXTS = '''from @nx_request request, @nx_target target, @nx_context context,
  string instancePath, string optionPath, string facet, int requestCount, int contextCount
where nx_requests(request, target, context, _, optionPath, facet, _, _, _, _, _)
  and nx_contexts(context, target, _, instancePath)
  and requestCount = count(@nx_request other | exists(@nx_context otherContext, @nx_option otherOption |
      nx_requests(other, target, otherContext, _, optionPath, facet, _, _, _, _, _)
        and nx_contexts(otherContext, target, _, instancePath)
        and nx_options(otherOption, otherContext, optionPath)) | other)
  and contextCount = count(@nx_context otherContext | exists(@nx_request other, @nx_option otherOption |
      nx_requests(other, target, otherContext, _, optionPath, facet, _, _, _, _, _)
        and nx_contexts(otherContext, target, _, instancePath)
        and nx_options(otherOption, otherContext, optionPath)) | otherContext)
select instancePath, optionPath, facet, requestCount, contextCount'''
CONCRETE_CONTEXTS = '''from string instancePath, int total
where exists(@nx_context context | nx_contexts(context, _, "concrete-submodule", instancePath))
  and total = count(@nx_context context | nx_contexts(context, _, "concrete-submodule", instancePath) | context)
select instancePath, total'''
# Displayed semantic rows; set semantics merge identical repeated selections.
SELECTION_CHAINS = '''from @nx_request request,
  @nx_context context, @nx_definition definition, @nx_option option,
  @nx_observation observation, @nx_origin origin, string instancePath,
  string optionPath, string label, string priority
where nx_requests(request, _, context, _, optionPath, "selection", _, _, _, _, _)
  and nx_contexts(context, _, _, instancePath)
  and nx_options(option, context, optionPath)
  and nx_definitions(definition, option, _, origin)
  and nx_observation_definitions(observation, definition)
  and nx_observations(observation, request, "pre-apply-metadata", "observed")
  and nx_origins(origin, label, _)
  and nx_option_priority(option, priority)
select instancePath, optionPath, label, priority'''
# Physical chains: every nested selection request keeps its own typed observations.
PHYSICAL_CHAINS = '''predicate chain(@nx_request request, @nx_definition definition) {
  exists(@nx_context context, @nx_option option, string optionPath,
      @nx_observation optionObservation, @nx_observation definitionObservation |
    nx_requests(request, _, context, _, optionPath, "selection", _, _, _, _, _)
      and nx_contexts(context, _, "concrete-submodule", _)
      and nx_options(option, context, optionPath)
      and nx_observation_options(optionObservation, option)
      and nx_observations(optionObservation, request, "pre-apply-metadata", "observed")
      and nx_definitions(definition, option, _, _)
      and nx_observation_definitions(definitionObservation, definition)
      and nx_observations(definitionObservation, request, "pre-apply-metadata", "observed"))
}
select count(@nx_request request | chain(request, _) | request),
  count(@nx_definition definition | chain(_, definition) | definition)'''


def canonical_step(option, kind, key):
    return {"option": option, "memberKind": kind, "memberKey": key}


def nix_value(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[ " + " ".join(nix_value(item) for item in value) + " ]"
    if isinstance(value, dict):
        return "{ " + "".join(name + " = " + nix_value(item) + ";" for name, item in value.items()) + " }"
    raise TypeError(type(value))


def request(context, path, *, facet="selection", max_bytes=1048576, max_depth=1, max_nodes=4):
    value = {
        "domain": "option-metadata",
        "facet": facet,
        "maxBytes": max_bytes,
        "maxDepth": max_depth,
        "maxMemoryMiB": 1024,
        "maxNodes": max_nodes,
        "maxSeconds": 30,
        "path": path,
    }
    if context is not None:
        value["contextPath"] = context
    return value


class NestedPacketTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        manifest = json.loads((SCHEMA_DIR / "target-manifest.json").read_text())
        observations = json.loads((SCHEMA_DIR / "observation-protocol.json").read_text())
        cls.manifest_schema = Draft202012Validator(manifest, format_checker=FORMATS)
        cls.observation_schema = Draft202012Validator(observations, format_checker=FORMATS)

    def manifest(self, value):
        self.manifest_schema.validate(value)

    def rejected_manifest(self, value):
        with self.assertRaises(ValidationError):
            self.manifest(value)

    def context_manifest(self, context):
        value = deepcopy(MANIFEST)
        value["targets"]["host.workstation"]["requests"][0] |= {
            "contextPath": context,
            "facet": "selection",
            "path": ["answer"],
        }
        return value

    def test_manifest_admits_exact_context_steps_and_refuses_invented_shapes(self):
        for kind, key in (
            ("submodule", ""),
            ("attribute", ""),
            ("attribute", "a.b"),
            ("index", "0"),
            ("index", "2147483647"),
        ):
            with self.subTest(kind=kind, key=key):
                self.manifest(self.context_manifest([canonical_step(["services"], kind, key)]))
        self.manifest(self.context_manifest([]))  # Explicit root equals the absent default.
        for context in (
            [{"memberKind": "attribute", "memberKey": "a.b"}],
            [{"option": "services", "memberKind": "attribute", "memberKey": "a.b"}],
            [{"option": ["services"], "memberKind": "schema", "memberKey": "a.b"}],
            [{"option": ["services"], "memberKind": "submodule", "memberKey": "x"}],
            [{"option": ["services"], "memberKind": "index", "memberKey": 0}],
            [{"option": ["services"], "memberKind": "index", "memberKey": "01"}],
            [{"option": ["services"], "memberKind": "index", "memberKey": "-1"}],
            [{"option": ["services"], "memberKind": "attribute", "memberKey": "x" * (LIMIT + 1)}],
        ):
            with self.subTest(context=context):
                self.rejected_manifest(self.context_manifest(context))
        packet = self.context_manifest([ATTRIBUTE_STEP])
        packet["targets"]["host.workstation"]["requests"][0]["contextPath"][0]["future"] = True
        self.rejected_manifest(packet)

    def nested_graph(self):
        rows = deepcopy(golden.BINDING_GRAPH)
        remove = {
            "nx_definition_order", "nx_definitions", "nx_observation_definitions",
            "nx_observation_options", "nx_observations", "nx_option_declarations",
            "nx_option_metadata", "nx_option_priority", "nx_module_lib_bindings", "nx_context_parents",
        }
        rows = [[name, arguments] for name, arguments in rows if name not in remove]
        rows = [[name, arguments] for name, arguments in rows
                if not (name == "nx_contexts" and arguments[0] == golden.I["n"])
                and not (name == "nx_options" and arguments[0] == golden.I["s"])]
        for _, arguments in rows:
            if arguments and arguments[0] == golden.PRIORITY_REQUEST:
                arguments[:] = []
        rows = [[name, arguments] for name, arguments in rows if arguments]
        child = abi.key("context", [golden.I["q"], golden.I["c"], golden.I["o"], "attribute", "a.b"])
        final_option = abi.key("option", [child, "answer"])
        final_definition = abi.key("definition", [final_option, "0"])
        option_observation = abi.key("observation", [golden.I["q"], "option"])
        definition_observation = abi.key("observation", [golden.I["q"], "definition"])
        for name, arguments in rows:
            if name == "nx_options":
                arguments[2] = '["services"]'
            elif name == "nx_requests" and arguments[0] == golden.I["q"]:
                arguments[2] = child
                arguments[4] = '["answer"]'
                arguments[5] = "selection"
                arguments[6:11] = [1, 4, 1048576, 30, 1024]
            elif name == "nx_request_results" and arguments[0] == golden.I["q"]:
                arguments[1:4] = ["complete", "", 2]
        rows += [
            ["nx_capabilities", [golden.I["t"], "nested-metadata", "supported", ""]],
            ["nx_context_parents", [child, golden.I["c"], golden.I["o"], "attribute", "a.b"]],
            ["nx_contexts", [child, golden.I["t"], "concrete-submodule", CONTEXT_JSON]],
            ["nx_definitions", [final_definition, final_option, 0, golden.I["p"]]],
            ["nx_observation_definitions", [definition_observation, final_definition]],
            ["nx_observation_options", [option_observation, final_option]],
            ["nx_observations", [option_observation, golden.I["q"], "pre-apply-metadata", "observed"]],
            ["nx_observations", [definition_observation, golden.I["q"], "pre-apply-metadata", "observed"]],
            ["nx_option_metadata", [final_option, "isDefined", "true"]],
            ["nx_option_priority", [final_option, "100"]],
            ["nx_options", [final_option, child, '["answer"]']],
        ]
        return rows, child

    def rejects_parent(self, mutate):
        rows, _ = self.nested_graph()
        mutate(rows)
        with self.assertRaises(ValueError):
            abi.validate(rows)

    def test_packet_context_identity_and_transport_are_request_qualified(self):
        rows, child = self.nested_graph()
        self.assertEqual(child, abi.key(
            "context", [golden.I["q"], golden.I["c"], golden.I["o"], "attribute", "a.b"]
        ))
        for index in range(5):
            components = [golden.I["q"], golden.I["c"], golden.I["o"], "attribute", "a.b"]
            components[index] += "-changed"
            self.assertNotEqual(child, abi.key("context", components))
        abi.validate(rows)
        packet = {"protocolVersion": 1, "facts": rows}
        before = deepcopy(packet)
        self.observation_schema.validate(packet)
        abi.validate(packet["facts"])
        self.assertEqual(packet, before)

    def test_parent_links_are_typed_exact_and_acyclic(self):
        def parent_row(rows):
            return next(arguments for name, arguments in rows if name == "nx_context_parents")

        def context_row(rows, identity):
            return next(arguments for name, arguments in rows
                        if name == "nx_contexts" and arguments[0] == identity)

        def wrong_target(rows):
            other_run = "nixql:v1:run:1:other"
            other_target = "nixql:v1:target:1:other"
            run = deepcopy(next(arguments for name, arguments in rows if name == "nx_runs"))
            target = deepcopy(next(arguments for name, arguments in rows if name == "nx_targets"))
            run[0], target[0], target[1] = other_run, other_target, other_run
            context_row(rows, parent_row(rows)[1])[1] = other_target
            rows += [["nx_runs", run], ["nx_targets", target]]

        def wrong_parent_option_context(rows):
            other_option = abi.key("option", [golden.I["j"], "services"])
            rows.append(["nx_options", [other_option, golden.I["j"], '["services"]']])
            parent_row(rows)[2] = other_option

        def duplicate(rows):
            rows.append(["nx_context_parents", deepcopy(parent_row(rows))])

        def root_parent(rows):
            rows.append(["nx_context_parents", [golden.I["c"], golden.I["c"], golden.I["o"], "attribute", "a.b"]])

        def cycle(rows):
            child = parent_row(rows)[0]
            second = abi.key("context", ["second", child, "attribute", "other"])
            middle = abi.key("option", [child, "answer"])
            rows += [
                ["nx_contexts", [second, golden.I["t"], "concrete-submodule",
                                  json.dumps([ATTRIBUTE_STEP, canonical_step(["answer"], "attribute", "other")],
                                             ensure_ascii=False, separators=(",", ":"))]],
                ["nx_options", [middle, child, '["answer"]']],
                ["nx_context_parents", [second, child, middle, "attribute", "other"]],
            ]
            parent_row(rows)[1:3] = [second, middle]

        for name, mutation in (
            ("cross-target", wrong_target),
            ("parent-option-context", wrong_parent_option_context),
            ("duplicate", duplicate),
            ("root-parent", root_parent),
            ("cycle", cycle),
        ):
            with self.subTest(name=name):
                self.rejects_parent(mutation)

    def test_member_step_keys_are_exact_and_canonical(self):
        def mutate(kind, key):
            def apply(rows):
                parent = next(arguments for name, arguments in rows if name == "nx_context_parents")
                context = next(arguments for name, arguments in rows
                               if name == "nx_contexts" and arguments[0] == parent[0])
                parent[3:5] = [kind, key]
                context[3] = json.dumps([canonical_step(["services"], kind, key)],
                                         ensure_ascii=False, separators=(",", ":"))
            return apply

        rows, _ = self.nested_graph()
        mutate("attribute", "")(rows)
        abi.validate(rows)  # Attribute keys are exact, including the empty string.
        for kind, key in (
            ("submodule", "x"), ("index", "01"), ("index", "-1"),
            ("submodule", ""), ("index", "0"),
        ):
            with self.subTest(kind=kind, key=key):
                mutation = mutate(kind, key)
                if (kind, key) in (("submodule", ""), ("index", "0")):
                    rows, _ = self.nested_graph()
                    mutation(rows)
                    abi.validate(rows)
                else:
                    self.rejects_parent(mutation)

    def failure_packet(self, reason):
        rows, _ = self.nested_graph()
        rows = [[name, arguments] for name, arguments in rows if name not in {
            "nx_capabilities", "nx_context_parents", "nx_definitions",
            "nx_observation_definitions", "nx_observation_options", "nx_observations",
            "nx_option_metadata", "nx_option_priority",
        }]
        child = next(arguments for name, arguments in rows
                     if name == "nx_contexts" and arguments[2] == "concrete-submodule")
        rows = [[name, arguments] for name, arguments in rows
                if not (name == "nx_contexts" and arguments is child)
                and name != "nx_options"]
        diagnostic = abi.key("diagnostic", [golden.I["q"], reason])
        for name, arguments in rows:
            if name == "nx_requests" and arguments[0] == golden.I["q"]:
                arguments[2] = golden.I["c"]
            elif name == "nx_request_results" and arguments[0] == golden.I["q"]:
                arguments[1:4] = ["failed" if reason != "nested-metadata-unavailable" else "unsupported", reason, 0]
        rows += [
            ["nx_diagnostics", [diagnostic, golden.I["r"], reason,
                                "nested request refused: " + CONTEXT_JSON]],
            ["nx_diagnostic_requests", [diagnostic, golden.I["q"]]],
            ["nx_diagnostic_targets", [diagnostic, golden.I["t"]]],
        ]
        return rows

    def test_failed_traversal_packet_is_atomic_and_root_remains_representable(self):
        rows = self.failure_packet("option-unavailable")
        abi.validate(rows)
        packet = {"protocolVersion": 1, "facts": rows}
        self.observation_schema.validate(packet)
        self.assertEqual([name for name, arguments in rows if name == "nx_context_parents"], [])
        self.assertFalse(any(name == "nx_contexts" and arguments[2] == "concrete-submodule"
                             for name, arguments in rows))
        diagnostic_id = abi.key("diagnostic", [golden.I["q"], "option-unavailable"])
        diagnostic = next(arguments for name, arguments in rows
                          if name == "nx_diagnostics" and arguments[0] == diagnostic_id)
        self.assertIn(CONTEXT_JSON, diagnostic[3])
        request = next(arguments for name, arguments in rows if name == "nx_request_results")
        self.assertEqual(request[1:4], ["failed", "option-unavailable", 0])


class NestedInstalledTests(test_installed.InstalledTests):
    def fixture(self, case="attrs", cases=None, paths=None, facets=None):
        # Each case owns a fresh source root; the base fixture never reuses files.
        self.fixtures = getattr(self, "fixtures", 0) + 1
        self.root = self.scratch / ("source-" + str(self.fixtures))
        self.root.mkdir()
        super().fixture()
        self.cases = cases if cases is not None else {"attrs": [ATTRIBUTE_STEP]}
        self.paths = paths if paths is not None else {}
        self.facets = facets if facets is not None else {}
        self.list_modules = ["first", "second"]
        for name, source in SOURCES.items():
            (self.root / (name + ".nix")).write_text(source)
        modules = {
            "attrs": ("options", "hosts"),
            "direct": ("direct-options", "direct"),
            "freeform": ("freeform-options", "hosts"),
            "list": ("list-options", "first", "second"),
            "missing": ("options", "hosts"),
        }[case]
        projection = self.root / "projection.nix"
        text = projection.read_text().replace(
            "inherit job;",
            "library = job.moduleArguments.nixpkgs; inherit job;",
        ).replace(
            "[ ./options.nix ./ordinary.nix ./default.nix ]",
            "[ " + " ".join("./" + name + ".nix" for name in modules) + " ]",
        )
        projection.write_text(text)
        target = self.root / ".nixql/targets.nix"
        requests = [request(None, ["services"], facet="isDefined", max_depth=0, max_nodes=1)]
        requests += [
            request(steps, [self.paths.get(name, "answer")], facet=self.facets.get(name, "selection"))
            for name, steps in self.cases.items()
        ]
        target_text = target.read_text().replace(
            '"literal.[name].with.dots"', '"N"'
        ).replace(
            'libVersion = "pinned-test"', "libVersion = " + json.dumps(self.inputs["nixpkgs"]["narHash"])
        )
        target_text, request_rewrites = re.subn(
            r'requests = map \(facet: \{.*?\}\) \[ "declarations" "definitions" "priority" \];',
            "requests = " + nix_value(requests) + ";",
            target_text,
            count=1,
            flags=re.DOTALL,
        )
        self.assertEqual(request_rewrites, 1)
        self.assertIn("contextPath = ", target_text)
        self.assertNotIn('"demo" "answer"', target_text)
        target.write_text(target_text)

    def oracle(self, case, member, leaf, *, value=False, failure=None):
        arguments = {
            "case": case, "leaf": leaf, "listModules": self.list_modules,
            "member": member, "nixpkgs": self.inputs["nixpkgs"]["path"],
            "source": str(self.root), "forceValue": value,
        }
        encoded = json.dumps(json.dumps(arguments))
        result = subprocess.run([
            self.nix, "--extra-experimental-features", "nix-command", "eval", "--json", "--impure",
            "--file", str(Path(__file__).with_name("oracle.nix")),
            "--apply", "oracle: oracle (builtins.fromJSON " + encoded + ")",
        ], env=self.env, capture_output=True, text=True)
        if failure is not None:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(failure, result.stderr)
            return
        self.assertEqual(result.returncode, 0, result.stderr)
        returned = json.loads(result.stdout)
        return returned if value else {name: sorted(value) if name == "definitions" else value
                                       for name, value in returned.items()}

    def database(self, name="db"):
        database, result = self.create(name, success=False)
        if result.returncode:
            self.run_codeql("database", "finalize", database)
        return database, result

    def product(self, database):
        bqrs = self.scratch / "submodule-origins.bqrs"
        self.run_codeql("query", "run", Path(os.environ["CODEQL_NIX_TEST_QUERIES"]) / "SubmoduleOrigins.ql",
                        "--database=" + str(database), "--output=" + str(bqrs))
        decoded = self.run_codeql("bqrs", "decode", bqrs, "--format=csv", "--no-titles")
        bqrs.unlink()
        return list(csv.reader(io.StringIO(decoded.stdout)))

    def test_attribute_metadata_is_pre_apply_and_other_member_is_absent(self):
        self.fixture()
        database, result = self.database()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        oracle = self.oracle("attrs", "a.b", "answer")
        self.assertEqual(oracle, {"definitions": ["hosts.nix"], "isDefined": True, "priority": "100"})
        expected = [line.strip()[2:-2].split(" | ") for line in
                    (OWNER / "ql/test/inc3/nested/SubmoduleOrigins.expected").read_text().splitlines()]
        self.assertCountEqual(self.product(database), expected)
        self.oracle("attrs", "a.b", "answer", value=True, failure="outer apply")

    def test_direct_and_list_index_traversal_follow_exact_members(self):
        for case, context, member in (
            ("direct", [{"option": ["unit"], "memberKind": "submodule", "memberKey": ""}], ""),
            ("list", [{"option": ["items"], "memberKind": "index", "memberKey": "0"}], "0"),
        ):
            with self.subTest(case=case):
                self.fixture(case, {case: context})
                database, _ = self.database(case)
                oracle = self.oracle(case, member, "answer")
                expected = [[
                    "N", json.dumps(context, ensure_ascii=False, separators=(",", ":")), '["answer"]',
                    str(index), file, oracle["priority"], "pre-apply-metadata"
                ] for index, file in enumerate(oracle["definitions"])]
                self.assertCountEqual(self.product(database), expected)
                if case == "direct":
                    self.assertEqual(self.oracle(case, member, "answer", value=True), {"answer": 42})
                else:
                    self.assertEqual(self.oracle(case, member, "answer", value=True), [{"answer": 20}, {"answer": 10}])
        self.fixture("list", {"list": [{"option": ["items"], "memberKind": "index", "memberKey": "0"}]})
        projection = self.root / "projection.nix"
        projection.write_text(projection.read_text().replace(
            "./first.nix ./second.nix", "./second.nix ./first.nix"))
        self.list_modules = ["second", "first"]
        database, _ = self.database("swapped")
        oracle = self.oracle("list", "0", "answer")
        self.assertEqual(oracle["definitions"], ["first.nix"])
        self.assertIn(["N", json.dumps([{"option": ["items"], "memberKind": "index", "memberKey": "0"}],
                                       ensure_ascii=False, separators=(",", ":")), '["answer"]', "0",
                       oracle["definitions"][0], "100", "pre-apply-metadata"], self.product(database))

    def test_requests_have_distinct_contexts_and_query_deduplicates_semantics(self):
        self.fixture("attrs", {
            "repeat-a": [ATTRIBUTE_STEP],
            "declare-a": [ATTRIBUTE_STEP],
            "repeat-b": [ATTRIBUTE_STEP],
            "sibling": [OTHER_STEP],
        }, facets={"declare-a": "declarations"})
        database, result = self.database("identity")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rows = self.query(database, "RequestContexts", REQUEST_CONTEXTS)
        nested = sorted(row for row in rows if row[0] != "[]")
        self.assertEqual(nested, sorted([
            [CONTEXT_JSON, '["answer"]', "declarations", "1", "1"],
            [CONTEXT_JSON, '["answer"]', "selection", "2", "2"],
            [OTHER_CONTEXT_JSON, '["answer"]', "selection", "1", "1"],
        ]))
        self.assertCountEqual(self.query(database, "ConcreteContexts", CONCRETE_CONTEXTS),
                              [[CONTEXT_JSON, "3"], [OTHER_CONTEXT_JSON, "1"]])
        product = self.product(database)
        self.assertEqual(len(product), 2)
        self.assertEqual({row[1] for row in product}, {CONTEXT_JSON, OTHER_CONTEXT_JSON})
        chains = self.query(database, "SelectionChains", SELECTION_CHAINS)
        self.assertEqual(len(chains), 2)  # Identical repeated selections display once.
        self.assertEqual(self.query(database, "PhysicalChains", PHYSICAL_CHAINS), [["3", "3"]])
        for context_json, member in ((CONTEXT_JSON, "a.b"), (OTHER_CONTEXT_JSON, "other")):
            oracle = self.oracle("attrs", member, "answer")
            semantic = [row for row in chains if row[0] == context_json]
            self.assertEqual([row[2:] for row in semantic],
                             [[file, "100"] for file in oracle["definitions"]])

    def test_unavailable_and_failed_traversals_are_atomic_with_valid_roots(self):
        cases = {
            "freeform": ([ATTRIBUTE_STEP], "answer", "unsupported", "nested-metadata-unavailable", "unavailable"),
            "missing": ([canonical_step(["services"], "attribute", "absent")], "answer", "failed", "instance-unavailable", "supported"),
            "attrs": ([ATTRIBUTE_STEP], "missing", "failed", "option-unavailable", "supported"),
        }
        for case, (context, leaf, state, reason, capability) in cases.items():
            with self.subTest(case=case):
                self.fixture(case, {case: context}, paths={case: leaf})
                member = context[-1]["memberKey"]
                self.oracle(case, member, leaf, failure=reason)
                database, _ = self.database(case)
                health = self.query(database, "RequestHealth", '''from @nx_request request,
                  string path, string state, string reason, int observedCount
                  where nx_request_results(request, state, reason, observedCount)
                    and nx_requests(request, _, _, _, path, _, _, _, _, _, _)
                  select path, state, reason, observedCount''')
                self.assertIn([json.dumps([leaf]), state, reason, "0"], health)
                self.assertIn(['["services"]', "complete", "", "1"], health)
                capabilities = self.query(database, "Capability", '''from @nx_target target,
                  string state, string reason
                  where nx_capabilities(target, "nested-metadata", state, reason)
                    and nx_targets(target, _, "N", _, _, _, _, _, _, _)
                  select state, reason''')
                self.assertEqual([row[0] for row in capabilities], [capability])
                self.assertEqual(self.query(database, "ConcreteContexts", '''select count(@nx_context context,
                  @nx_context parent | nx_context_parents(context, parent, _, _, _) | context)'''), [["0"]])
        self.fixture("freeform", {"freeform": [ATTRIBUTE_STEP]})
        (self.root / "freeform-options.nix").write_text(SOURCES["freeform-options"].replace(
            "lib.types.attrsOf lib.types.anything", "lib.types.attrsOf (lib.types.submodule "
            "{ options.answer=lib.mkOption { type=lib.types.int; }; })"))
        self.assertIn("hosts.nix", self.oracle("freeform", "a.b", "answer")["definitions"])

    def test_depth_node_and_byte_limits_refuse_without_nested_provenance(self):
        for field, value, reason in (
            ("depth", 0, "depth-limit"),
            ("nodes", 3, "node-limit"),
            ("bytes", 1, "byte-limit"),
        ):
            with self.subTest(field=field):
                context = [ATTRIBUTE_STEP]
                self.fixture("attrs", {"limited": context})
                target = self.root / ".nixql/targets.nix"
                field_argument = {"depth": "max_depth", "nodes": "max_nodes", "bytes": "max_bytes"}[field]
                requests = [
                    request(None, ["services"], facet="isDefined", max_depth=0, max_nodes=1),
                    request(context, ["answer"], **{field_argument: value}),
                ]
                target.write_text(target.read_text().replace(
                    "requests = " + nix_value([
                        request(None, ["services"], facet="isDefined", max_depth=0, max_nodes=1),
                        request(context, ["answer"]),
                    ]) + ";",
                    "requests = " + nix_value(requests) + ";",
                ))
                self.oracle("attrs", "a.b", "answer")
                database, _ = self.database(field)
                health = self.query(database, "RequestHealth", '''from @nx_request request,
                  string path, string state, string reason, int observedCount
                  where nx_request_results(request, state, reason, observedCount)
                    and nx_requests(request, _, _, _, path, _, _, _, _, _, _)
                  select path, state, reason, observedCount''')
                self.assertIn(['["answer"]', "failed", reason, "0"], health)
                self.assertIn(['["services"]', "complete", "", "1"], health)
                self.assertEqual(self.query(database, "ConcreteContexts", '''select count(@nx_context context,
                  @nx_context parent | nx_context_parents(context, parent, _, _, _) | context)'''), [["0"]])

    def test_installed_qltest_runs_reviewed_expected_rows(self):
        self.fixture()
        shutil.copy(OWNER / "ql/test/qlpack.yml", self.root / "qlpack.yml")
        shutil.copy(Path(os.environ["CODEQL_NIX_TEST_QUERIES"]) / "SubmoduleOrigins.ql", self.root / "SubmoduleOrigins.ql")
        shutil.copy(OWNER / "ql/test/inc3/nested/SubmoduleOrigins.expected", self.root / "SubmoduleOrigins.expected")
        result = self.run_codeql("test", "run", self.root,
            env=self.env | {"CODEQL_EXTRACTOR_NIX_OPTION_INPUTS": json.dumps(self.inputs)})
        print(result.stdout[-6000:] + result.stderr[-6000:], flush=True)


def load_tests(loader, tests, pattern):
    packet = [
        NestedPacketTests(name) for name in (
            "test_manifest_admits_exact_context_steps_and_refuses_invented_shapes",
            "test_packet_context_identity_and_transport_are_request_qualified",
            "test_parent_links_are_typed_exact_and_acyclic",
            "test_member_step_keys_are_exact_and_canonical",
            "test_failed_traversal_packet_is_atomic_and_root_remains_representable",
        )
    ]
    installed = [
        NestedInstalledTests(name) for name in (
            "test_attribute_metadata_is_pre_apply_and_other_member_is_absent",
            "test_direct_and_list_index_traversal_follow_exact_members",
            "test_requests_have_distinct_contexts_and_query_deduplicates_semantics",
            "test_unavailable_and_failed_traversals_are_atomic_with_valid_roots",
            "test_depth_node_and_byte_limits_refuse_without_nested_provenance",
            "test_installed_qltest_runs_reviewed_expected_rows",
        )
    ]
    return unittest.TestSuite(packet + installed)


if __name__ == "__main__":
    unittest.main()

"""M3d installed producer/query tests frozen from contract and upstream Nix."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import unittest
from copy import deepcopy

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "installed"))
sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "src/eval"))
import protocol
import test_installed

OWNER = Path(__file__).resolve().parents[4]
FIXTURE = Path(__file__).parent
EXPECTED = OWNER / "ql/test/inc3/all-definitions/LosingDefinitions.expected"
BASE = ("options", "ordinary", "fallback", "inactive")
PATH = '["demo","answer"]'
UTF8_POSITION_SOURCE = (
    '{...}: {\n'
    '  _file = "utf8-position.nix";\n'
    '  /* é */ demo.answer = 1;\n'
    '}\n'
).encode("utf-8")


class InstalledAllDefinitionsTests(test_installed.InstalledTests):
    def create_reviewed(self, name="db", *, success=True):
        result = subprocess.run([
            self.nix, "--extra-experimental-features", "nix-command", "hash", "path", str(self.root)
        ], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.root_nar_hash = result.stdout.strip()
        return self.create(name, success=success)

    def fixture(self, modules=BASE, *, nodes=100, depth=1, override_lib=False,
                trusted_library=True):
        super().fixture()
        self.modules = modules
        for source in FIXTURE.glob("*.nix"):
            destination = self.root / source.name
            shutil.copy(source, destination)
            destination.chmod(destination.stat().st_mode | stat.S_IWUSR)
        projection = self.root / "projection.nix"
        projection_text = projection.read_text().replace(
            "inherit job;", "library = job.moduleArguments.nixpkgs; inherit job;"
        ).replace(
            "[ ./options.nix ./ordinary.nix ./default.nix ]",
            "[ " + " ".join("./" + name + ".nix" for name in modules) + " ]",
        )
        if not trusted_library:
            projection_text = projection_text.replace(
                "library = job.moduleArguments.nixpkgs; ", ""
            )
        if override_lib:
            projection_text = projection_text.replace("inherit job;", """specialArguments = {
              lib = (import (libraryTree.outPath + "/lib")) // {
                mkDefault = _: 2;
              };
            }; inherit job;""")
        projection.write_text(projection_text)
        target = self.root / ".nixql/targets.nix"
        target.write_text(target.read_text()
            .replace('"literal.[name].with.dots"', '"D"')
            .replace('libVersion = "pinned-test"',
                     'libVersion = ' + json.dumps(self.inputs["nixpkgs"]["narHash"]))
            .replace('[ "declarations" "definitions" "priority" ]', '[ "all-definitions" ]')
            .replace("maxDepth = 0", "maxDepth = " + str(depth))
            .replace("maxNodes = 100", "maxNodes = " + str(nodes)))

    def fresh(self, name, modules=BASE, **options):
        self.root = self.scratch / (name + "-source")
        self.root.mkdir()
        self.fixture(modules, **options)

    def oracle(self, *, value=False, failure=False, diagnostic=None, modules=None,
               internalKey=False, specialLib=False):
        arguments = {"forceValue": value,
                     "modules": self.modules if modules is None else modules,
                     "internalKey": internalKey, "specialLib": specialLib,
                     "nixpkgs": self.inputs["nixpkgs"]["path"], "source": str(self.root)}
        encoded = json.dumps(json.dumps(arguments))
        result = subprocess.run([
            self.nix, "--extra-experimental-features", "nix-command", "eval", "--json", "--impure",
            "--file", str(FIXTURE / "oracle.nix"),
            "--apply", "oracle: oracle (builtins.fromJSON " + encoded + ")",
        ], env=self.env, capture_output=True, text=True, timeout=60)
        if failure:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            if diagnostic is not None:
                self.assertIn(diagnostic, result.stderr)
            return None
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def product(self, database):
        return self.installed_query(database, "LosingDefinitions")

    def candidates(self, database):
        return self.query(database, "Candidates", '''from @nx_candidate candidate,
          @nx_option option, @nx_origin origin, string label, int ordinal,
          string active, string selected, string chain
          where nx_candidates(candidate, option, ordinal, origin, _, active, selected, chain)
            and nx_origins(origin, label, _)
          select label, ordinal, active, selected, chain''')

    def priorities(self, database):
        return self.query(database, "CandidatePriorities", '''from @nx_candidate candidate,
          @nx_option option, @nx_origin origin, string label, string priority
          where nx_candidates(candidate, option, _, origin, _, _, _, _)
            and nx_definition_candidate_priorities(candidate, priority)
            and nx_origins(origin, label, _)
          select label, priority''')

    def selected_links(self, database):
        return self.query(database, "CandidateSelections", '''from @nx_candidate candidate,
          @nx_definition definition, @nx_origin origin, string label
          where nx_definition_selections(candidate, definition)
            and nx_candidates(candidate, _, _, origin, _, _, "true", _)
            and nx_origins(origin, label, _)
          select label''')

    def result(self, database):
        return self.query(database, "RequestResult", '''from @nx_request request,
          string state, string reason, int observed
          where nx_requests(request, _, _, "option-metadata", ''' + json.dumps(PATH) + ''',
              "all-definitions", _, _, _, _, _)
            and nx_request_results(request, state, reason, observed)
          select state, reason, observed''')

    def origin_positions(self, database, label):
        body = '''from @nx_origin origin, string originLabel, int line, int column
          where nx_origins(origin, originLabel, _)
            and nx_origin_positions(origin, line, column, "utf8-byte-1-based")
            and originLabel = %s
          select line, column'''
        body = body.replace("%s", json.dumps(label))
        return self.query(database, "OriginPositions", body)

    def exact_signed_minimum(self, database):
        return self.query(database, "ExactSignedMinimum", '''import nix.internal.Evaluation
          from string outcome
          where
            outcome = "minimum-below-maximum" and Evaluation::decimalLessThan(
              "-9223372036854775808", "9223372036854775807"
            )
            or outcome = "minimum-below-near-minimum" and Evaluation::decimalLessThan(
              "-9223372036854775808", "-9223372036854775807"
            )
            or outcome = "equal-minimum-not-less" and not Evaluation::decimalLessThan(
              "-9223372036854775808", "-9223372036854775808"
            )
          select outcome''')
    def anchor_components(self, database, relative, start, end, node_kind):
        source = (self.root / relative).read_bytes()
        content_hash = hashlib.sha256(source).hexdigest()
        root_key = protocol.abi.key("root", ["project", self.root_nar_hash])
        body = '''from RawBridge::Anchor anchor, @nx_file file, string storedRoot,
          string storedHash
          where nx_anchors(anchor, file, __START__, __END__,
            __KIND__, _)
            and nx_files(file, storedRoot, __RELATIVE__, storedHash, "project")
          select anchor.getChildPath(), anchor.getMappingState(), storedRoot, storedHash'''
        body = (body
                .replace("__START__", str(start))
                .replace("__END__", str(end))
                .replace("__KIND__", json.dumps(node_kind))
                .replace("__RELATIVE__", json.dumps(relative)))
        rows = self.query(database, "ExactAnchorComponents", body)
        self.assertEqual(len(rows), 1, relative + ":" + str(start) + ":" + node_kind)
        child_path, mapping, stored_root, stored_hash = rows[0]
        self.assertEqual(mapping, "unique")
        self.assertEqual(stored_root, root_key)
        self.assertEqual(stored_hash, content_hash)
        components = [
            root_key, content_hash, relative, str(start), str(end), node_kind,
            child_path,
        ]
        return root_key, content_hash, components

    def anchor(self, database, relative, start, end, node_kind):
        root_key, content_hash, components = self.anchor_components(
            database, relative, start, end, node_kind)
        file_key = protocol.abi.key("file", [root_key, relative, content_hash])
        return protocol.abi.key("anchor", [
            file_key, components[3], components[4], components[5], components[6],
        ])

    def anchor_span(self, relative, text):
        # Fixture text is UTF-8; locate by exact Unicode string, then use its byte span.
        source = (self.root / relative).read_text()
        character_start = source.index(text)
        byte_start = len(source[:character_start].encode("utf-8"))
        return byte_start, byte_start + len(text.encode("utf-8"))

    def anchor_key(self, database, relative, text):
        start, end = self.anchor_span(relative, text)
        return self.anchor(database, relative, start, end, "attrpath")

    def wrapper_anchor(self, database, relative, text):
        start, end = self.anchor_span(relative, text)
        return self.anchor(database, relative, start, end, "apply_expression")

    def wrapper(self, database, relative, text, records):
        anchor = self.wrapper_anchor(database, relative, text)
        chain = []
        for record in records:
            entry = {"kind": record[0], "anchor": anchor}
            if record[0] == "merge":
                entry["index"] = record[1]
            elif record[0] == "if":
                entry["truth"] = record[1]
            else:
                entry["priority"] = record[1]
            chain.append(entry)
        return json.dumps(chain, separators=(",", ":"))

    def assert_anchor_spans(self, database):
        rows = self.query(database, "CandidateAnchors", '''from @nx_candidate candidate,
          RawBridge::Anchor anchor, @nx_file file, @nx_origin origin,
          string storedRoot, string storedHash, string relative,
          string nodeKind, int start, int end
          where nx_candidates(candidate, _, _, origin, anchor, _, _, _)
            and nx_anchors(anchor, file, start, end, nodeKind, _)
            and nx_files(file, storedRoot, relative, storedHash, "project")
            and nx_origins(origin, relative, _)
          select storedRoot, storedHash, relative, start, end, nodeKind,
            anchor.getChildPath()''')
        expected = []
        for name in self.modules:
            relative = name + ".nix"
            source = (self.root / relative).read_text()
            if not any(line.lstrip().startswith("demo.answer =")
                       for line in source.splitlines()):
                continue
            start, end = self.anchor_span(relative, "demo.answer")
            _, _, components = self.anchor_components(
                database, relative, start, end, "attrpath")
            expected.append(components)
        self.assertCountEqual(rows, expected)

    def test_exact_d_rows_inventory_and_reviewed_qltest(self):
        self.fixture()
        oracle = self.oracle()
        self.assertEqual(oracle, {"definitions": [{"file": "ordinary.nix"}],
                                  "isDefined": True, "priority": "100"})
        self.assertEqual(self.oracle(value=True), 1)
        database, _ = self.create_reviewed()
        wrapper = self.wrapper(database, "fallback.nix", "lib.mkDefault 2",
                               [("override", "1000")])
        expected_row = [["D", "[]", PATH, "fallback.nix", "1000", "100",
                         "true", "false", wrapper]]
        self.assertEqual(self.product(database), expected_row)
        inactive_wrapper = self.wrapper(
            database, "inactive.nix",
            'lib.mkIf false (lib.mkOverride 10 (throw "M3d inactive"))',
            [("if", "false")])
        inner = self.wrapper(database, "inactive.nix",
                             'lib.mkOverride 10 (throw "M3d inactive")',
                             [("override", "10")])
        # wrapper() builds one anchor per call; rebuild the two-entry chain exactly.
        inactive_chain = json.loads(inactive_wrapper) + json.loads(inner)
        expected_chain = json.dumps(inactive_chain, separators=(",", ":"))
        self.assertCountEqual(self.candidates(database), [
            ["fallback.nix", "1", "true", "false", wrapper],
            ["inactive.nix", "2", "false", "false", expected_chain],
            ["ordinary.nix", "0", "true", "true", "[]"],
        ])
        self.assertCountEqual(self.priorities(database), [
            ["fallback.nix", "1000"], ["inactive.nix", "10"], ["ordinary.nix", "100"],
        ])
        self.assertEqual(self.selected_links(database), [["ordinary.nix"]])
        self.assertEqual(self.result(database), [["complete", "", "5"]])
        self.assert_anchor_spans(database)
        # Files present in the source root but absent from the collected module list
        # are syntax, not evaluated candidate definitions.
        labels = {row[0] for row in self.candidates(database)}
        self.assertNotIn("fallback-50.nix", labels)
        self.assertNotIn("disabled.nix", labels)

        shutil.copy(OWNER / "ql/test/qlpack.yml", self.root / "qlpack.yml")
        shutil.copy(Path(os.environ["CODEQL_NIX_TEST_QUERIES"]) / "LosingDefinitions.ql",
                    self.root / "LosingDefinitions.ql")
        expected = EXPECTED.read_text().replace("<fallback-wrapper>", wrapper)
        (self.root / "LosingDefinitions.expected").write_text(expected)
        result = self.run_codeql("test", "run", self.root,
            env=self.env | {"CODEQL_EXTRACTOR_NIX_OPTION_INPUTS": json.dumps(self.inputs)})
        print(result.stdout[-6000:] + result.stderr[-6000:], flush=True)

    def test_override_flip_changes_the_only_proven_losing_row(self):
        self.fixture()
        database, _ = self.create_reviewed("baseline")
        self.assertEqual(self.oracle(value=True), 1)
        (self.root / "fallback.nix").write_text((FIXTURE / "fallback-50.nix").read_text())
        oracle = self.oracle()
        self.assertEqual(oracle, {"definitions": [{"file": "fallback.nix"}],
                                  "isDefined": True, "priority": "50"})
        self.assertEqual(self.oracle(value=True), 2)
        database, _ = self.create_reviewed("flip")
        self.assertEqual(self.product(database), [
            ["D", "[]", PATH, "ordinary.nix", "100", "50", "true", "false", "[]"],
        ])
        fallback_wrapper = self.wrapper(database, "fallback.nix", "lib.mkOverride 50 2",
                                        [("override", "50")])
        inactive_wrapper = self.wrapper(
            database, "inactive.nix",
            'lib.mkIf false (lib.mkOverride 10 (throw "M3d inactive"))', [("if", "false")])
        inactive_inner = self.wrapper(database, "inactive.nix",
            'lib.mkOverride 10 (throw "M3d inactive")', [("override", "10")])
        inactive_chain = json.dumps(json.loads(inactive_wrapper) +
                                    json.loads(inactive_inner), separators=(",", ":"))
        self.assertCountEqual(self.candidates(database), [
            ["fallback.nix", "1", "true", "true", fallback_wrapper],
            ["inactive.nix", "2", "false", "false", inactive_chain],
            ["ordinary.nix", "0", "true", "false", "[]"],
        ])
        self.assertEqual(self.selected_links(database), [["fallback.nix"]])
        self.assertEqual(self.result(database), [["complete", "", "5"]])

    def test_equal_priority_and_same_file_ambiguity_do_not_invent_losers(self):
        self.fresh("equal", ("options", "ordinary", "tie"))
        (self.root / "tie.nix").write_text(
            (FIXTURE / "ordinary.nix").read_text().replace("ordinary.nix", "tie.nix").replace("= 1;", "= 2;"))
        oracle = self.oracle()
        self.assertEqual([row["file"] for row in oracle["definitions"]],
                         ["tie.nix", "ordinary.nix"])
        self.assertEqual(oracle["priority"], "100")
        self.oracle(value=True, failure=True)
        database, _ = self.create_reviewed("equal")
        self.assertEqual(self.product(database), [])
        self.assertCountEqual(self.candidates(database), [
            ["ordinary.nix", "0", "true", "true", "[]"],
            ["tie.nix", "1", "true", "true", "[]"],
        ])

        self.fresh("ambiguous", ("options", "ambiguous"))
        oracle = self.oracle()
        self.assertEqual([row["file"] for row in oracle["definitions"]],
                         ["ambiguous.nix", "ambiguous.nix"])
        self.oracle(value=True, failure=True)
        database, _ = self.create_reviewed("ambiguous")
        self.assertEqual(self.product(database), [])
        merge0 = json.loads(self.wrapper(database, "ambiguous.nix", "lib.mkMerge [1 2]",
                                         [("merge", 0)]))
        merge1 = deepcopy(merge0)
        merge1[0]["index"] = 1
        self.assertCountEqual(self.candidates(database), [
            ["ambiguous.nix", "0", "true", "unknown",
             json.dumps(merge0, separators=(",", ":"))],
            ["ambiguous.nix", "1", "true", "unknown",
             json.dumps(merge1, separators=(",", ":"))],
        ])
        self.assertEqual(self.selected_links(database), [])
        self.assertEqual(self.result(database), [["complete", "", "5"]])

    def test_nested_wrappers_preserve_outer_order_and_merge_indexes(self):
        self.fresh("nested", ("list-options", "nested"))
        self.assertEqual(self.oracle(), {"definitions": [{"file": "nested.nix"}],
                                         "isDefined": True, "priority": "100"})
        self.assertEqual(self.oracle(value=True), ["left"])
        database, _ = self.create_reviewed()
        outer = 'lib.mkIf true (lib.mkMerge [\n    (lib.mkOrder 700 ["left"])\n    (lib.mkIf false (lib.mkAfter ["right"]))\n  ])'
        merge_call = 'lib.mkMerge [\n    (lib.mkOrder 700 ["left"])\n    (lib.mkIf false (lib.mkAfter ["right"]))\n  ]'
        first = self.wrapper(database, "nested.nix", outer, [("if", "true")])
        merge = self.wrapper(database, "nested.nix", merge_call, [("merge", 0)])
        first_order = self.wrapper(database, "nested.nix", 'lib.mkOrder 700 ["left"]',
                                   [("order", "700")])
        first_chain = json.dumps(json.loads(first) + json.loads(merge) +
                                 json.loads(first_order), separators=(",", ":"))
        second = self.wrapper(database, "nested.nix",
            "lib.mkIf false (lib.mkAfter [\"right\"])", [("if", "false")])
        second_order = self.wrapper(database, "nested.nix", 'lib.mkAfter ["right"]',
                                    [("order", "1500")])
        merge1 = deepcopy(json.loads(merge))
        merge1[0]["index"] = 1
        second_chain = json.dumps(json.loads(first) + merge1 +
                                  json.loads(second) + json.loads(second_order),
                                  separators=(",", ":"))
        self.assertCountEqual(self.candidates(database), [
            ["nested.nix", "0", "true", "true", first_chain],
            ["nested.nix", "1", "false", "false", second_chain],
        ])
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.selected_links(database), [["nested.nix"]])

    def test_dynamic_guard_is_unknown_until_literal_truth_changes(self):
        self.fresh("dynamic", ("options", "dynamic"))
        oracle = self.oracle()
        self.assertEqual(oracle, {"definitions": [], "isDefined": False, "priority": "9999"})
        database, _ = self.create_reviewed()
        unknown_guard = self.wrapper(database, "dynamic.nix",
                                     "lib.mkIf (builtins.add 0 1 == 2) 3",
                                     [("if", "unknown")])
        self.assertEqual(self.candidates(database),
                         [["dynamic.nix", "0", "unknown", "unknown", unknown_guard]])
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.result(database), [["complete", "", "2"]])
        (self.root / "dynamic.nix").write_text(
            (FIXTURE / "dynamic.nix").read_text().replace("builtins.add 0 1 == 2", "true"))
        oracle = self.oracle()
        self.assertEqual(oracle, {"definitions": [{"file": "dynamic.nix"}],
                                  "isDefined": True, "priority": "100"})
        self.assertEqual(self.oracle(value=True), 3)
        database, _ = self.create_reviewed("dynamic-true")
        true_guard = self.wrapper(database, "dynamic.nix", "lib.mkIf (true) 3",
                                  [("if", "true")])
        self.assertEqual(self.candidates(database),
                         [["dynamic.nix", "0", "true", "true", true_guard]])
        self.assertEqual(self.product(database), [])

    def test_opaque_failure_and_unknown_bodies_are_never_complete_inventory(self):
        self.fresh("opaque", ("options", "opaque"))
        self.oracle(failure=True)
        database, result = self.create_reviewed("opaque", success=False)
        if result.returncode:
            self.run_codeql("database", "finalize", database)
        self.assertEqual(self.candidates(database), [])
        self.assertEqual(self.product(database), [])
        request_result = self.result(database)
        self.assertEqual(len(request_result), 1)
        self.assertEqual(request_result[0][0], "failed")
        self.assertEqual(request_result[0][2], "0")

        for name, module in (("computed-key", "computed-key"),
                             ("custom-property", "custom-property")):
            with self.subTest(case=name):
                self.fresh(name, ("options", module))
                oracle = self.oracle()
                self.assertEqual(oracle["definitions"], [{"file": module + ".nix"}])
                self.assertTrue(oracle["isDefined"])
                self.assertEqual(oracle["priority"], "100")
                database, result = self.create_reviewed(name, success=False)
                if result.returncode:
                    self.run_codeql("database", "finalize", database)
                self.assertEqual(self.candidates(database), [])
                self.assertEqual(self.product(database), [])
                self.assertEqual(self.result(database),
                                 [["partial", "definition-body-opaque", "2"]])

    def test_disabled_occurrence_is_not_an_extra_evaluated_candidate(self):
        self.fresh("disabled", ("options", "ordinary", "disabled"))
        oracle = self.oracle()
        self.assertEqual(oracle, {"definitions": [{"file": "ordinary.nix"}],
                                  "isDefined": True, "priority": "100"})
        self.assertEqual(self.oracle(value=True), 1)
        database, _ = self.create_reviewed()
        self.assertEqual(self.candidates(database),
                         [["ordinary.nix", "0", "true", "true", "[]"]])
        self.assertEqual(self.result(database), [["complete", "", "3"]])

    def test_signed_decimal_comparator_preserves_near_endpoint_precision(self):
        self.fresh("endpoints", ("options", "low", "high"))
        oracle = self.oracle()
        self.assertEqual(oracle, {"definitions": [{"file": "low.nix"}],
                                  "isDefined": True,
                                  "priority": "-9223372036854775807"})
        self.assertEqual(self.oracle(value=True), 1)
        database, _ = self.create_reviewed()
        wrapper = self.wrapper(database, "high.nix", "lib.mkOverride 9223372036854775807 2",
                               [("override", "9223372036854775807")])
        self.assertEqual(self.product(database), [
            ["D", "[]", PATH, "high.nix", "9223372036854775807",
             "-9223372036854775807", "true", "false", wrapper],
        ])

    def test_config_prefixed_literal_binding_is_a_complete_forced_candidate(self):
        self.fresh("config-prefixed", ("options", "config-prefixed"))
        oracle = self.oracle()
        self.assertEqual(oracle, {"definitions": [{"file": "config-prefixed.nix"}],
                                  "isDefined": True, "priority": "50"})
        self.assertEqual(self.oracle(value=True), 7)
        database, _ = self.create_reviewed()
        binding = self.anchor_key(database, "config-prefixed.nix", "config.demo.answer")
        self.assertTrue(binding)
        wrapper = self.wrapper(database, "config-prefixed.nix", "lib.mkForce 7",
                               [("override", "50")])
        self.assertEqual(self.candidates(database), [
            ["config-prefixed.nix", "0", "true", "true", wrapper],
        ])
        self.assertEqual(self.priorities(database),
                         [["config-prefixed.nix", "50"]])
        self.assertEqual(self.selected_links(database), [["config-prefixed.nix"]])
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.result(database), [["complete", "", "3"]])

    def test_computed_leaf_bodies_stay_partial_without_false_losers(self):
        cases = (
            ("if-expression", {"definitions": [{"file": "if-expression.nix"}],
                               "isDefined": True, "priority": "50"}, "2"),
            ("with-expression", {"definitions": [], "isDefined": False,
                                 "priority": "9999"}, "1"),
        )
        for module, metadata, observed in cases:
            with self.subTest(module=module):
                self.fresh(module, ("options", module))
                self.assertEqual(self.oracle(), metadata)
                database, result = self.create_reviewed(module, success=False)
                if result.returncode:
                    self.run_codeql("database", "finalize", database)
                self.assertEqual(self.candidates(database), [])
                self.assertEqual(self.priorities(database), [])
                self.assertEqual(self.selected_links(database), [])
                self.assertEqual(self.product(database), [])
                self.assertEqual(self.result(database),
                                 [["partial", "definition-body-opaque", observed]])

    def test_unshadowed_literal_bool_null_and_negative_values_complete(self):
        cases = (
            ("bool", ("bool-options", "bool"), True),
            ("bool-false", ("bool-options", "bool-false"), False),
            ("null-value", ("null-options", "null-value"), None),
            ("negative", ("options", "negative"), -5),
            ("negative-float", ("float-options", "negative-float"), -5.5),
        )
        for name, modules, value in cases:
            with self.subTest(name=name):
                self.fresh(name, modules)
                self.assertEqual(self.oracle(), {
                    "definitions": [{"file": name + ".nix"}], "isDefined": True,
                    "priority": "100",
                })
                self.assertEqual(self.oracle(value=True), value)
                database, _ = self.create_reviewed(name)
                self.assertEqual(self.candidates(database), [
                    [name + ".nix", "0", "true", "true", "[]"],
                ])
                self.assertEqual(self.priorities(database),
                                 [[name + ".nix", "100"]])
                self.assertEqual(self.selected_links(database), [[name + ".nix"]])
                self.assertEqual(self.product(database), [])
                self.assertEqual(self.result(database), [["complete", "", "3"]])

    def test_lexically_shadowed_builtin_literals_stay_partial(self):
        cases = (
            ("shadowed-bool", ("bool-options", "shadowed-bool")),
            ("shadowed-dotted-bool", ("bool-options", "shadowed-dotted-bool")),
            ("shadowed-formal-bool", ("bool-options", "shadowed-formal-bool")),
            ("shadowed-at-bool", ("bool-options", "shadowed-at-bool")),
            ("shadowed-at-null", ("null-options", "shadowed-at-null")),
        )
        for name, modules in cases:
            with self.subTest(name=name):
                self.fresh(name, modules)
                self.assertEqual(self.oracle(), {
                    "definitions": [{"file": name + ".nix"}],
                    "isDefined": True,
                    "priority": "100",
                })
                database, result = self.create_reviewed(name, success=False)
                self.assertNotEqual(result.returncode, 0)
                self.run_codeql("database", "finalize", database)
                self.assertEqual(self.candidates(database), [])
                self.assertEqual(self.priorities(database), [])
                self.assertEqual(self.selected_links(database), [])
                self.assertEqual(self.product(database), [])
                self.assertEqual(self.result(database),
                                 [["partial", "definition-body-opaque", "2"]])

    def test_guard_beneath_override_is_unknown_and_unselected(self):
        self.fresh("override-over-if", ("options", "override-over-if"))
        oracle = self.oracle()
        self.assertEqual(oracle, {"definitions": [{"file": "override-over-if.nix"}],
                                  "isDefined": True, "priority": "10"})
        database, _ = self.create_reviewed()
        outer = self.wrapper(database, "override-over-if.nix",
                             "lib.mkOverride 10 (lib.mkIf false 1)",
                             [("override", "10")])
        inner = self.wrapper(database, "override-over-if.nix",
                             "lib.mkIf false 1", [("if", "false")])
        chain = json.dumps(json.loads(outer) + json.loads(inner),
                           separators=(",", ":"))
        self.assertEqual(self.candidates(database), [
            ["override-over-if.nix", "0", "unknown", "unknown", chain],
        ])
        self.assertEqual(self.priorities(database), [])
        self.assertEqual(self.selected_links(database), [])
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.result(database), [["complete", "", "3"]])

    def test_private_internal_key_collision_excludes_imported_duplicate(self):
        self.fresh("internal-collision", ("options", "internal-root"))
        declarations = self.oracle(modules=("options",), internalKey=True)
        self.assertEqual(len(declarations), 1)
        internal_key = declarations[0]
        self.assertIsInstance(internal_key, str)
        self.assertTrue(internal_key)
        collision = self.root / "internal-collision.nix"
        collision.write_text(collision.read_text().replace(
            "@@NIXQL_INTERNAL_MODULE_KEY@@", internal_key
        ))
        self.assertEqual(self.oracle(), {"definitions": [{"file": "internal-root.nix"}],
                                         "isDefined": True, "priority": "100"})
        self.assertEqual(self.oracle(value=True), 1)
        database, _ = self.create_reviewed()
        self.assertTrue(self.anchor_key(database, "internal-collision.nix", "demo.answer"))
        self.assertEqual(self.candidates(database), [
            ["internal-root.nix", "0", "true", "true", "[]"],
        ])
        self.assertEqual(self.selected_links(database), [["internal-root.nix"]])
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.result(database), [["complete", "", "3"]])

    def test_regular_duplicate_user_key_keeps_only_the_first_collected_module(self):
        self.fresh("duplicate-key", ("options", "duplicate-root"))
        self.assertEqual(self.oracle(), {"definitions": [{"file": "duplicate-first.nix"}],
                                         "isDefined": True, "priority": "100"})
        self.assertEqual(self.oracle(value=True), 1)
        database, _ = self.create_reviewed()
        self.assertTrue(self.anchor_key(database, "duplicate-second.nix", "demo.answer"))
        self.assertEqual(self.candidates(database), [
            ["duplicate-first.nix", "0", "true", "true", "[]"],
        ])
        self.assertEqual(self.selected_links(database), [["duplicate-first.nix"]])
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.result(database), [["complete", "", "3"]])

    def test_origin_position_uses_one_based_utf8_byte_column(self):
        self.fresh("utf8-position", ("options", "utf8-position"))
        runtime_source = self.root / "utf8-position.nix"
        runtime_source.write_bytes(UTF8_POSITION_SOURCE)
        self.assertEqual(runtime_source.read_bytes(), UTF8_POSITION_SOURCE)
        self.assertEqual(self.oracle(value=True), 1)
        source = UTF8_POSITION_SOURCE
        binding = source.index(b"demo.answer")
        line = source[:binding].count(b"\n") + 1
        line_start = source.rfind(b"\n", 0, binding) + 1
        column = binding - line_start + 1
        database, _ = self.create_reviewed()
        self.assertEqual(self.origin_positions(database, "utf8-position.nix"),
                         [[str(line), str(column)]])

    def test_real_mkDefinition_record_is_opaque_not_ordinary(self):
        self.fresh("real-custom-property", ("options", "real-custom-property"))
        self.assertEqual(self.oracle(), {
            "definitions": [{"file": "definition-origin"}], "isDefined": True,
            "priority": "100",
        })
        self.assertEqual(self.oracle(value=True), 1)
        database, result = self.create_reviewed(success=False)
        if result.returncode:
            self.run_codeql("database", "finalize", database)
        self.assertEqual(self.candidates(database), [])
        self.assertEqual(self.priorities(database), [])
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.result(database),
                         [["partial", "definition-body-opaque", "2"]])

    def test_library_authentication_and_special_lib_suppress_property_candidates(self):
        self.fresh("special-lib", ("options", "fallback"), override_lib=True)
        self.assertEqual(self.oracle(specialLib=True), {
            "definitions": [{"file": "fallback.nix"}], "isDefined": True,
            "priority": "100",
        })
        self.assertEqual(self.oracle(value=True, specialLib=True), 2)
        database, result = self.create_reviewed("special-lib", success=False)
        self.assertNotEqual(result.returncode, 0)
        self.run_codeql("database", "finalize", database)
        self.assertEqual(self.candidates(database), [])
        self.assertEqual(self.priorities(database), [])
        self.assertEqual(self.result(database)[0][:2], ["partial", "definition-body-opaque"])

        self.fresh("legacy-library", ("options", "fallback"), trusted_library=False)
        self.assertEqual(self.oracle(), {
            "definitions": [{"file": "fallback.nix"}], "isDefined": True,
            "priority": "1000",
        })
        database, result = self.create_reviewed("legacy-library", success=False)
        self.assertNotEqual(result.returncode, 0)
        self.run_codeql("database", "finalize", database)
        self.assertEqual(self.candidates(database), [])
        self.assertEqual(self.priorities(database), [])
        self.assertEqual(self.result(database)[0][:2], ["partial", "definition-body-opaque"])

    def test_depth_zero_all_definitions_refuses_option_and_children_atomically(self):
        self.fixture(depth=0)
        self.assertEqual(self.oracle(value=True), 1)
        database, result = self.create_reviewed("depth-zero", success=False)
        self.assertNotEqual(result.returncode, 0)
        self.run_codeql("database", "finalize", database)
        self.assertEqual(self.result(database), [["failed", "depth-limit", "0"]])
        self.assertEqual(self.candidates(database), [])
        self.assertEqual(self.selected_links(database), [])
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.query(database, "NoDepthZeroOptionChildren", '''select
          count(@nx_option o | nx_options(o, _, _) | o),
          count(@nx_definition d | nx_definitions(d, _, _, _) | d)'''), [["0", "0"]])

    def test_shared_ql_comparator_reaches_exact_signed_minimum(self):
        self.fixture()
        database, _ = self.create_reviewed("signed-minimum")
        self.assertEqual(sorted(self.exact_signed_minimum(database)), [
            ["equal-minimum-not-less"], ["minimum-below-maximum"],
            ["minimum-below-near-minimum"],
        ])


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(InstalledAllDefinitionsTests(name)
                              for name in sorted(InstalledAllDefinitionsTests.__dict__)
                              if name.startswith("test_"))


if __name__ == "__main__":
    unittest.main()

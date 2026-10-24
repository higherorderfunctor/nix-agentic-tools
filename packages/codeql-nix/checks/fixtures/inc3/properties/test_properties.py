"""M3p RESUME contract tests; expectations come from the contract and Nix.

The direct oracle imports only the pinned upstream library. Synthetic _file
labels deliberately prove reported origins, never authenticated source points.
"""

import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "installed"))
import test_installed

OWNER = Path(__file__).resolve().parents[4]
PATH = '["demo","items"]'
BASE_MODULES = ("options", "before", "normal", "after", "off")
SOURCES = {
    "after": '{lib,...}: { _file="after.nix"; demo.items=lib.mkAfter ["a"]; }',
    "alias": '{lib,...}: let before=lib.mkBefore; in { _file="alias.nix"; demo.items=before ["alias"]; }',
    "before": '{lib,...}: { _file="before.nix"; demo.items=lib.mkBefore ["b"]; }',
    "computed": 'let make=module: module; in make (import ./alias.nix)',
    "forwarded": 'import ./alias.nix',
    "merge": '{lib,...}: { _file="merge.nix"; demo.items=lib.mkMerge [(lib.mkIf true ["x"]) (lib.mkIf false (throw "M3p inactive"))]; }',
    "nested": Path(__file__).with_name("nested.nix.in").read_text(),
    "normal": '{...}: { _file="normal.nix"; demo.items=["n"]; }',
    "off": '{lib,...}: { _file="off.nix"; demo.items=lib.mkIf false (throw "M3p inactive"); }',
    "options": '{lib,...}: { _file="options.nix"; options.demo.items=lib.mkOption { type=lib.types.listOf lib.types.str; }; }',
    "override": '{lib,...}: { _file="override.nix"; demo.items=lib.mkOverride 50 ["force"]; }',
    "shadow": '{lib,...}: let lib={mkBefore=x: x;}; in { _file="shadow.nix"; demo.items=lib.mkBefore ["shadow"]; }',
}


class PropertyTests(test_installed.InstalledTests):
    def fixture(self, modules=BASE_MODULES, *, override_lib=False, nodes=100, depth=1, facet="selection"):
        super().fixture()
        self.modules = modules
        self.override_lib = override_lib
        for name, source in SOURCES.items():
            (self.root / (name + ".nix")).write_text(source)
        projection = self.root / "projection.nix"
        text = projection.read_text().replace("inherit job;", "library = job.moduleArguments.nixpkgs; inherit job;").replace(
            "[ ./options.nix ./ordinary.nix ./default.nix ]",
            "[ " + " ".join("./" + name + ".nix" for name in modules) + " ]",
        )
        if override_lib:
            text = text.replace("inherit job;", '''specialArguments = {
              lib = (import (libraryTree.outPath + "/lib")) // {
                mkBefore = _: ["override-sentinel"];
              };
            }; inherit job;''')
        projection.write_text(text)
        target = self.root / ".nixql/targets.nix"
        target.write_text(target.read_text()
            .replace('"literal.[name].with.dots"', '"P"')
            .replace('libVersion = "pinned-test"', 'libVersion = ' + json.dumps(self.inputs["nixpkgs"]["narHash"]))
            .replace('"demo" "answer"', '"demo" "items"')
            .replace('[ "declarations" "definitions" "priority" ]', '[ "' + facet + '" ]')
            .replace("maxDepth = 0", "maxDepth = " + str(depth))
            .replace("maxNodes = 100", "maxNodes = " + str(nodes)))

    def oracle(self, *, value=False, failure=False):
        arguments = {
            "forceValue": value, "modules": self.modules,
            "nixpkgs": self.inputs["nixpkgs"]["path"],
            "overrideLib": self.override_lib, "source": str(self.root),
        }
        encoded = json.dumps(json.dumps(arguments))
        result = subprocess.run([
            self.nix, "--extra-experimental-features", "nix-command", "eval", "--json", "--impure",
            "--file", str(Path(__file__).with_name("oracle.nix")),
            "--apply", "oracle: oracle (builtins.fromJSON " + encoded + ")",
        ], env=self.env, capture_output=True, text=True)
        if failure:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("M3p", result.stderr)
            return
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def product(self, database):
        return self.installed_query(database, "ModuleSelection")

    def selected(self, database, expected, *, priority="100", value=None):
        oracle = self.oracle()
        self.assertEqual(oracle, {
            "definitions": [{"file": file, "order": order} for file, order in expected],
            "isDefined": bool(expected), "priority": priority if expected else None,
        })
        rows = [["P", "[]", PATH, str(index), file, priority, json.dumps(order)]
                for index, (file, order) in enumerate(expected)]
        self.assertCountEqual(self.product(database), rows)
        if value is not None:
            self.assertEqual(self.oracle(value=True), value)

    def kinds(self, database):
        return self.query(database, "PropertyKinds", '''import nix.Modules
          from Modules::PropertyApplication application
          select application.getKind()''')

    def bindings(self, database):
        return self.query(database, "LibraryBindings", '''from @nx_request request,
          @nx_anchor functionAnchor, @nx_anchor formalAnchor, @nx_file file,
          string libHash, string modelHash, string path
          where nx_module_lib_bindings(request, functionAnchor, formalAnchor, libHash, modelHash)
            and nx_anchors(functionAnchor, file, _, _, _, _)
            and nx_files(file, _, path, _, _)
          select path, libHash, modelHash''')

    def test_exact_p_rows_and_synthetic_origins_are_labels_only(self):
        self.fixture(nodes=4)
        database, _ = self.create()
        expected = [line.strip()[2:-2].split(" | ") for line in
                    (OWNER / "ql/test/inc3/properties/ModuleSelection.expected").read_text().splitlines()]
        self.assertCountEqual(self.product(database), expected)
        self.selected(database, [("before.nix", "500"), ("normal.nix", None), ("after.nix", "1500")], value=["b", "n", "a"])
        self.assertCountEqual(self.kinds(database), [["if"], ["order"]])
        # _file is synthetic: source admission and library-formal authentication
        # cannot upgrade these labels to file/point or expression causation.
        rows = self.query(database, "SyntheticOrigins", '''from @nx_origin origin, string label
          where nx_definitions(_, _, _, origin) and nx_origin_files(origin, _)
            and nx_origins(origin, label, _)
          select label''')
        self.assertEqual(rows, [])
        bindings = self.bindings(database)
        self.assertTrue({"before.nix", "after.nix", "off.nix", "options.nix"} <= {row[0] for row in bindings})
        for _, lib_hash, model_hash in bindings:
            self.assertEqual(lib_hash, self.inputs["nixpkgs"]["narHash"])
            model = json.loads((self.library / "models/modules.json").read_text())
            self.assertEqual(model_hash, model["bundleHash"])

    def test_installed_qltest_runs_reviewed_p_expected(self):
        self.fixture()
        shutil.copy(OWNER / "ql/test/qlpack.yml", self.root / "qlpack.yml")
        shutil.copy(Path(os.environ["CODEQL_NIX_TEST_QUERIES"]) / "ModuleSelection.ql", self.root / "ModuleSelection.ql")
        shutil.copy(OWNER / "ql/test/inc3/properties/ModuleSelection.expected", self.root / "ModuleSelection.expected")
        result = self.run_codeql("test", "run", self.root,
            env=self.env | {"CODEQL_EXTRACTOR_NIX_OPTION_INPUTS": json.dumps(self.inputs)})
        print(result.stdout[-6000:] + result.stderr[-6000:], flush=True)

    def test_merge_discharge_two_occurrences_and_guard_value_failure(self):
        self.fixture(("options", "merge"))
        database, _ = self.create()
        self.selected(database, [("merge.nix", None)], value=["x"])
        self.assertCountEqual(self.query(database, "MergeGroups", """import nix.Modules
          from Modules::PropertyGroup group select group.getIndex()"""), [["0"], ["1"]])
        self.assertCountEqual(self.kinds(database), [["if"], ["merge"]])
        merge = self.root / "merge.nix"
        merge.write_text(merge.read_text().replace('(lib.mkIf false (throw "M3p inactive"))', '(lib.mkIf true ["y"])'))
        database, _ = self.create("two-groups")
        self.selected(database, [("merge.nix", None), ("merge.nix", None)], value=["x", "y"])
        merge.write_text(SOURCES["merge"].replace("mkIf false", "mkIf true"))
        self.oracle(value=True, failure=True)
        # Metadata may succeed without forcing a retained throwing value. Only
        # the independent value oracle above is required to fail.

    def test_order_swap_override_and_decimal_endpoint(self):
        self.fixture()
        before, after = self.root / "before.nix", self.root / "after.nix"
        before.write_text(before.read_text().replace("lib.mkBefore", "lib.mkOrder 1500"))
        after.write_text(after.read_text().replace("lib.mkAfter", "lib.mkOrder 500"))
        database, _ = self.create("swapped")
        self.selected(database, [("after.nix", "500"), ("normal.nix", None), ("before.nix", "1500")], value=["a", "n", "b"])
        before.write_text(SOURCES["before"].replace("lib.mkBefore", "lib.mkOrder 9223372036854775807"))
        database, _ = self.create("endpoint")
        self.selected(database, [("after.nix", "500"), ("normal.nix", None), ("before.nix", "9223372036854775807")], value=["a", "n", "b"])
        self.modules += ("override",)
        projection = self.root / "projection.nix"
        projection.write_text(projection.read_text().replace("./off.nix ]", "./off.nix ./override.nix ]"))
        database, _ = self.create("override")
        self.selected(database, [("override.nix", None)], priority="50", value=["force"])

    def test_alias_shadow_and_special_argument_sentinels(self):
        for module, order, value, recognized in (
            ("alias", "500", ["alias"], True),
            ("shadow", None, ["shadow"], False),
        ):
            with self.subTest(module=module):
                self.fixture(("options", module))
                database, _ = self.create(module)
                self.selected(database, [(module + ".nix", order)], value=value)
                self.assertEqual(self.kinds(database), [["order"]] if recognized else [])
                # Separate source roots for the next fixture invocation.
                self.root = self.scratch / (module + "-next")
                self.root.mkdir()
        self.fixture(("options", "before"), override_lib=True)
        database, _ = self.create("special-lib")
        self.selected(database, [("before.nix", None)], value=["override-sentinel"])
        self.assertEqual(self.bindings(database), [])
        self.assertEqual(self.kinds(database), [])

    def test_parenthesized_helper_and_library_aliases(self):
        for name, source in (
            ("helper", SOURCES["alias"].replace("before=lib.mkBefore", "before=((lib.mkBefore))")),
            ("library", SOURCES["alias"].replace("before=lib.mkBefore", "aliased=((lib)); before=aliased.mkBefore")),
        ):
            with self.subTest(alias=name):
                self.fixture(("options", "alias"))
                (self.root / "alias.nix").write_text(source)
                database, _ = self.create(name)
                self.selected(database, [("alias.nix", "500")], value=["alias"])
                self.assertEqual(self.kinds(database), [["order"]])
                self.root = self.scratch / (name + "-next")
                self.root.mkdir()

    def test_repeated_root_preserves_upstream_selection_and_unique_binding(self):
        self.fixture(("options", "before", "before"))
        oracle = self.oracle()
        value = self.oracle(value=True)
        database, _ = self.create("repeated-root")
        self.selected(database, [(row["file"], row["order"]) for row in oracle["definitions"]],
                      priority=oracle["priority"], value=value)
        self.assertTrue(oracle["isDefined"])
        print("M3p repeated roots upstream: " + json.dumps(oracle, sort_keys=True) +
              "; value=" + json.dumps(value), flush=True)
        self.assertEqual(self.query(database, "RepeatedBinding", '''select count(@nx_request request,
          @nx_anchor functionAnchor, @nx_anchor formalAnchor, @nx_file file |
          nx_module_lib_bindings(request, functionAnchor, formalAnchor, _, _)
            and nx_anchors(functionAnchor, file, _, _, _, _)
            and nx_files(file, _, "before.nix", _, _)
          | formalAnchor)'''), [["1"]])

    def test_parameter_priorities_have_exact_source_sets(self):
        for name, override, order, expected in (
            ("literal", "50", "700", [["order", "700"], ["override", "50"]]),
            ("zero", "0", "0", [["order", "0"], ["override", "0"]]),
            ("computed", "(builtins.add 25 25)", "(builtins.add 350 350)", []),
        ):
            with self.subTest(priority=name):
                self.fixture(("options", "nested"))
                (self.root / "nested.nix").write_text(SOURCES["nested"]
                    .replace("mkOverride 50", "mkOverride " + override)
                    .replace("mkOrder 700", "mkOrder " + order))
                database, _ = self.create(name)
                self.selected(database, [("nested.nix", "0" if name == "zero" else "700")],
                              priority="0" if name == "zero" else "50", value=["left"])
                parameters = '''import nix.Modules
                  from Modules::PropertyApplication application
                  where application.getAnchor().getRelativePath() = "nested.nix"
                    and application.getKind() in ["order", "override"]
                    and application.getArgumentSpecJson() = "{\\"arity\\":2,\\"content\\":1}"'''
                self.assertCountEqual(self.query(database, "ParameterKinds", parameters +
                    " select application.getKind()"), [["order"], ["override"]])
                self.assertCountEqual(self.query(database, "SourcePriorities", parameters +
                    " select application.getKind(), application.getPriorityText()"), expected)
                self.root = self.scratch / (name + "-next")
                self.root.mkdir()

    def test_returned_functions_have_unknown_bindings(self):
        for module in ("forwarded", "computed"):
            with self.subTest(module=module):
                self.fixture(("options", module))
                database, _ = self.create(module)
                self.selected(database, [("alias.nix", "500")], value=["alias"])
                self.assertFalse({"alias.nix", module + ".nix"} & {row[0] for row in self.bindings(database)})
                self.assertEqual(self.kinds(database), [])
                self.root = self.scratch / (module + "-next")
                self.root.mkdir()

    def test_descriptor_supplies_actual_library_and_legacy_route_is_unknown(self):
        self.fixture(("options", "before"))
        projection = self.root / "projection.nix"
        trusted = projection.read_text()
        projection.write_text(trusted.replace('lib = import (libraryTree.outPath + "/lib");',
          'lib = throw "M3p caller lib must not be used";'))
        database, _ = self.create("trusted-library")
        self.selected(database, [("before.nix", "500")], value=["b"])
        self.assertIn("before.nix", {row[0] for row in self.bindings(database)})
        projection.write_text(trusted.replace("library = job.moduleArguments.nixpkgs; ", ""))
        database, _ = self.create("legacy-library")
        self.selected(database, [("before.nix", "500")], value=["b"])
        self.assertEqual(self.bindings(database), [])
        self.assertEqual(self.kinds(database), [])

    def test_unproven_target_library_pin_never_authenticates_helpers(self):
        self.fixture(("options", "before"))
        target = self.root / ".nixql/targets.nix"
        target.write_text(target.read_text().replace(json.dumps(self.inputs["nixpkgs"]["narHash"]),
            '"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="', 1))
        self.assertEqual(self.oracle(value=True), ["b"])
        database, result = self.create("unproven-pin", success=False)
        if result.returncode:
            self.run_codeql("database", "finalize", database)
        self.assertEqual(self.bindings(database), [])
        self.assertEqual(self.kinds(database), [])

    def test_nested_source_wrappers_preserve_parent_and_group_content(self):
        self.fixture(("options", "nested"))
        database, _ = self.create("nested-source")
        self.selected(database, [("nested.nix", "700")], priority="50", value=["left"])
        rows = self.query(database, "PropertyStructure", """import nix.Modules
          from Modules::PropertyApplication application, string parentKind,
            int parentStart, int parentEnd
          where application.getAnchor().getRelativePath() = "nested.nix" and
            (exists(Modules::PropertyApplication parent |
               parent = application.getEnclosingProperty() and
               parentKind = parent.getKind() and
               parentStart = parent.getAnchor().getStartByte() and
               parentEnd = parent.getAnchor().getEndByte())
             or not exists(application.getEnclosingProperty()) and
               parentKind = "none" and parentStart = 0 and parentEnd = 0)
          select application.getKind(), application.getAnchor().getStartByte(),
            application.getAnchor().getEndByte(), parentKind, parentStart, parentEnd""")
        expected = [line.strip()[2:-2].split(" | ") for line in
                    (OWNER / "ql/test/inc3/properties/PropertyStructure.expected").read_text().splitlines()]
        self.assertCountEqual(rows, expected)
        groups = self.query(database, "PropertyGroupContents", """import nix.Modules
          from Modules::PropertyGroup group
          where group.getApplication().getAnchor().getRelativePath() = "nested.nix"
            and group.getAnchor().getUniqueNode() = group.getContent()
          select group.getApplication().getAnchor().getStartByte(),
            group.getApplication().getAnchor().getEndByte(), group.getIndex(),
            group.getAnchor().getStartByte(), group.getAnchor().getEndByte()""")
        expected = [line.strip()[2:-2].split(" | ") for line in
                    (OWNER / "ql/test/inc3/properties/PropertyGroups.expected").read_text().splitlines()]
        self.assertCountEqual(groups, expected)
        # The golden encodes concrete content identity, not just index presence.
        source = (self.root / "nested.nix").read_bytes()
        content = {int(row[2]): source[int(row[3]):int(row[4])].decode() for row in groups}
        self.assertEqual(content, {
            0: '(lib.mkOverride 50 (lib.mkOrder 700 ["left"]))',
            1: '(lib.mkIf false (lib.mkAfter ["right"]))',
        })

    def test_supported_root_metadata_survives_a_valid_unsupported_library_pin(self):
        # Copy only the upstream library, preserving its relative imports. The
        # private root is fully admitted and genuinely differs from the model pin.
        alternate = self.scratch / "alternate-library"
        shutil.copytree(Path(self.inputs["nixpkgs"]["path"]) / "lib", alternate / "lib")
        for path in (alternate, *alternate.rglob("*")):
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | 0o200)
        (alternate / "pin-marker").write_text("independently admitted alternative root\n")
        hashed = subprocess.run([self.nix, "--extra-experimental-features", "nix-command",
            "hash", "path", alternate], env=self.env, capture_output=True, text=True, check=True).stdout.strip()
        self.assertNotEqual(hashed, self.inputs["nixpkgs"]["narHash"])
        self.inputs = self.inputs | {"nixpkgs": {"path": str(alternate), "narHash": hashed}}
        self.fixture(("options", "before"))
        target = self.root / ".nixql/targets.nix"
        target.write_text(target.read_text()
            .replace('[ "selection" ]', '[ "selection" "priority" ]')
            .replace("maxDepth = 1", 'maxDepth = if facet == "priority" then 0 else 1'))
        self.assertEqual(self.oracle(value=True), ["b"])
        database, result = self.create("unsupported-library", success=False)
        if result.returncode:
            self.run_codeql("database", "finalize", database)
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.bindings(database), [])
        self.assertEqual(self.kinds(database), [])
        self.assertEqual(self.query(database, "UnsupportedProperties", """from @nx_target target
          where nx_capabilities(target, "module-properties", "unsupported", _)
          select count(target)"""), [["1"]])
        self.assertEqual(self.query(database, "UnsupportedSelection", """from @nx_request request
          where nx_requests(request, _, _, "option-metadata", _, "selection", _, _, _, _, _)
            and nx_request_results(request, "unsupported", _, _)
          select count(request)"""), [["1"]])
        self.assertEqual(self.query(database, "UsableRootPriority", """from @nx_request request,
          @nx_option option, @nx_observation observation
          where nx_requests(request, _, _, "option-metadata", _, "priority", _, _, _, _, _)
            and nx_request_results(request, "complete", _, _)
            and nx_observations(observation, request, "pre-apply-metadata", "observed")
            and nx_observation_options(observation, option)
            and nx_option_metadata(option, "isDefined", "true") and nx_option_priority(option, "100")
          select count(option)"""), [["1"]])
        self.assertEqual(self.oracle()["priority"], "100")

    def test_generated_helper_constants_and_source_evidence_match_upstream(self):
        self.fixture(("options", "normal"))
        model = json.loads((self.library / "models/modules.json").read_text())
        self.assertEqual(model["libHash"], self.inputs["nixpkgs"]["narHash"])
        payload = {key: value for key, value in model.items() if key not in {"bundleHash", "modelVersion"}}
        expected = "sha256:" + hashlib.sha256(json.dumps(payload, ensure_ascii=False,
            sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.assertEqual(model["modelVersion"], expected)
        expression = "let lib=import " + json.dumps(self.inputs["nixpkgs"]["path"] + "/lib") + "; in builtins.mapAttrs (_: wrapper: toString wrapper.priority) {" + " ".join(
            name + "=lib." + name + " null;" for name in ("mkAfter", "mkBefore", "mkDefault", "mkForce")) + "}"
        result = subprocess.run([self.nix, "--extra-experimental-features", "nix-command",
            "eval", "--json", "--impure", "--expr", expression], env=self.env,
            capture_output=True, text=True, check=True)
        priorities = json.loads(result.stdout)
        helpers = {helper["name"]: helper for helper in model["helpers"]}
        self.assertTrue({"mkAfter", "mkBefore", "mkDefault", "mkForce", "mkIf", "mkMerge", "mkOrder", "mkOverride"} <= set(helpers))
        for name, priority in priorities.items():
            self.assertEqual(helpers[name]["priority"], priority)
        for name in ("mkOrder", "mkOverride"):
            self.assertIsNone(helpers[name]["priority"])
        self.assertEqual(self.query(self.create("model-constants")[0], "ParameterizedConstants",
            '''import nix.internal.generated.Modules as ModuleModels
              from string name, string priority
              where name in ["mkOrder", "mkOverride"] and ModuleModels::constant(name, priority)
              select name, priority'''), [])
        ordinary = self.oracle()["priority"]
        self.assertEqual(model["constants"]["ordinaryOverridePriority"], ordinary)
        root = Path(self.inputs["nixpkgs"]["path"])
        def checked_evidence(records):
            self.assertTrue(records)
            texts = []
            for record in records:
                relative = Path(record["file"])
                self.assertFalse(relative.is_absolute())
                self.assertNotIn("..", relative.parts)
                self.assertEqual(relative.parts[0], "lib")
                lines = (root / relative).read_text().splitlines()
                self.assertGreater(record["line"], 0)
                self.assertLessEqual(record["line"], len(lines))
                actual = lines[record["line"] - 1]
                self.assertEqual(record["lineText"], actual)
                self.assertGreater(record["column"], 0)
                self.assertLessEqual(record["column"], len(actual.encode()) + 1)
                texts.append(actual)
            return texts
        for name, helper in helpers.items():
            self.assertTrue(helper["exportIdentity"])
            self.assertIn(name, " ".join(checked_evidence(helper["evidence"])))
            self.assertEqual(json.dumps(json.loads(helper["argumentSpecJson"]), ensure_ascii=False,
                sort_keys=True, separators=(",", ":")), helper["argumentSpecJson"])
        self.assertIn(ordinary, " ".join(checked_evidence(model["constantEvidence"]["ordinaryOverridePriority"])))

    def test_selection_metadata_precedes_apply(self):
        self.fixture()
        options = self.root / "options.nix"
        options.write_text(options.read_text().replace("type=lib.types.listOf lib.types.str;",
          'type=lib.types.listOf lib.types.str; apply=_: throw "M3p apply";'))
        database, _ = self.create()
        self.selected(database, [("before.nix", "500"), ("normal.nix", None), ("after.nix", "1500")])
        self.oracle(value=True, failure=True)

    def test_complete_undefined_has_option_witness_no_priority(self):
        self.fixture(("options",), nodes=1, depth=0)
        database, _ = self.create()
        self.selected(database, [])
        self.assertEqual(self.query(database, "Undefined", '''from @nx_option option,
          @nx_observation observation, @nx_request request
          where nx_option_metadata(option, "isDefined", "false")
            and nx_observation_options(observation, option)
            and nx_observations(observation, request, "pre-apply-metadata", "observed")
            and nx_request_results(request, "complete", _, 1)
          select count(option)'''), [["1"]])
        self.assertEqual(self.query(database, "NoUndefinedPriority", "select count(@nx_option o | nx_option_priority(o, _) | o)"), [["0"]])

    def test_selection_budgets_refuse_atomically_and_step0_stays_separate(self):
        for name, nodes, depth in (("nodes", 3, 1), ("depth", 100, 0)):
            with self.subTest(budget=name):
                self.fixture(nodes=nodes, depth=depth)
                self.assertEqual(self.oracle(value=True), ["b", "n", "a"])
                database, result = self.create(name, success=False)
                self.assertNotEqual(result.returncode, 0)
                self.run_codeql("database", "finalize", database)
                self.assertEqual(self.product(database), [])
                self.assertEqual(self.bindings(database), [])
                self.assertEqual(self.query(database, "NoPartialDefinitions", "select count(@nx_definition d | nx_definitions(d, _, _, _) | d)"), [["0"]])
                self.root = self.scratch / (name + "-next")
                self.root.mkdir()
        self.fixture(facet="definitions", depth=0)
        database, _ = self.create("step0")
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.bindings(database), [])


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(PropertyTests(name) for name in sorted(PropertyTests.__dict__) if name.startswith("test_"))

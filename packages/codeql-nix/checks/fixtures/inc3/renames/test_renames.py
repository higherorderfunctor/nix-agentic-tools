# cspell:ignore targetless unfinalized uninvoked
"""M3r rename contract tests; expectations come from the contract and Nix.

The direct oracle imports only the pinned upstream library. Every expected
row is computed from the fixture's own bytes, never from extractor output,
and the reviewed ql/test rows must equal the same computed values.
"""

import gzip
import hashlib
import importlib.util
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "installed"))
import test_installed

OWNER = Path(__file__).resolve().parents[4]
CALL = 'lib.mkRenamedOptionModule ["old"] ["new"]'
PATH = '["new"]'
BASE_MODULES = ("warnings", "options", "rename", "old")
SOURCES = {
    "alias": '{lib,...}: { _file="alias.nix"; imports=[ (lib.mkAliasOptionModule ["old"] ["new"]) ]; }',
    "custom": '{lib,...}: { _file="custom.nix"; imports=[ (lib.mkRenamedOptionModuleWith { from=["old"]; to=["new"]; sinceRelease=9999; }) ]; }',
    "dotted": '{lib,...}: { _file="dotted.nix"; options.c=lib.mkOption { type=lib.types.int; }; imports=[ (lib.mkRenamedOptionModule ["a.b"] ["c"]) ]; }',
    "dynamic": '{lib,...}: { _file="dynamic.nix"; imports=[ (lib.mkRenamedOptionModule [("o" + "ld")] ["new"]) ]; }',
    "inactive": '{lib,...}: { _file="inactive.nix"; imports=[ (lib.mkRenamedOptionModule ["old"] ["new"]) ]; config.new=lib.mkIf false (lib.mkRenamedOptionModule ["never"] ["new"]); }',
    "inherited": '{lib,...}: let inherit (lib) mkAliasOptionModule; in { _file="inherited.nix"; imports=[ (mkAliasOptionModule ["old"] ["new"]) ]; }',
    "interpolated": '{lib,...}: let old="old"; in { _file="interpolated.nix"; imports=[ (lib.mkAliasOptionModule ["${old}"] ["new"]) ]; }',
    "legacy": '{...}: { _file="legacy.nix"; config."a.b"=7; }',
    "library": '{lib,...}: { _file="library.nix"; imports=[ (let l=lib; in l.mkAliasOptionModule ["old"] ["new"]) ]; }',
    "literals": r"""{lib,...}: {
      # é𝄞 before the calls makes their UTF-8 byte offsets differ from character offsets.
      _file="literals.nix";
      options.new=lib.genAttrs ["blank" "dotted" "escaped" "leading" "multiline" "single" "split" "é" "𝄞new"]
        (_: lib.mkOption { type=lib.types.int; });
      config."a.b"=7;
      config.a.b=8;
      config."o\"ld"."é\t\\end"."\${x}\r"=9;
      config.single=10;
      config."multi\n  line\n"=11;
      config."esc\n  next''\${x}"=12;
      config."\nz\n"=13;
      config."é𝄞\n"=14;
      config."a\n  \n"=15;
      imports=[
        (lib.mkRenamedOptionModule ["a.b"] ["new" "dotted"])
        (lib.mkRenamedOptionModule ["a" "b"] ["new" "split"])
        (lib.mkRenamedOptionModule ["o\"ld" "é\t\\end" "\${x}\r"] ["new" "é"])
        (lib.mkAliasOptionModule [''single''] ["new" "single"])
        (lib.mkAliasOptionModule [''
    multi
      line
        ''] ["new" "multiline"])
        (lib.mkAliasOptionModule [''esc''\n  next'''''${x}''] ["new" "escaped"])
        (lib.mkAliasOptionModule [''
    ''\n  z
  ''] ["new" "leading"])
        (lib.mkAliasOptionModule [''
    é𝄞
  ''] ["new" "𝄞new"])
        (lib.mkAliasOptionModule [''
    a
@blank-line@
''] ["new" "blank"])
      ];
    }""".replace("@blank-line@", "      "),
    "local": '{lib,...}: { _file="local.nix"; imports=[ (let f=lib.mkAliasOptionModule; in f ["old"] ["new"]) ]; }',
    "old": '{...}: { _file="old.nix"; config.old=7; }',
    "options": '{lib,...}: { _file="options.nix"; options.new=lib.mkOption { type=lib.types.int; }; }',
    "outward": '{lib,...}: let f=lib.mkAliasOptionModule; in { _file="outward.nix"; imports=[ (let inherit f; in f ["old"] ["new"]) ]; }',
    "rename": Path(__file__).with_name("rename.nix.in").read_text(),
    "shadow": '{lib,...}: { _file="shadow.nix"; imports=[ (let mkAliasOptionModule=from: to: { config.new=77; }; in mkAliasOptionModule ["old"] ["new"]) ]; }',
    "stray": '{lib,...}: { _file="stray.nix"; imports=[ (lib.mkRenamedOptionModule ["stray"] ["new"]) ]; }',
    "warnings": '{lib,...}: { _file="warnings.nix"; options.warnings=lib.mkOption { type=lib.types.listOf lib.types.str; default=[]; }; }',
}


class RenameTests(test_installed.InstalledTests):
    def fixture(self, modules=BASE_MODULES, *, path=("new",), override_lib=False):
        super().fixture()
        self.modules = modules
        self.path = path
        self.override_lib = override_lib
        for name, source in SOURCES.items():
            (self.root / (name + ".nix")).write_text(source, encoding="utf-8")
        projection = self.root / "projection.nix"
        text = projection.read_text().replace("inherit job;", "library = job.moduleArguments.nixpkgs; inherit job;").replace(
            "[ ./options.nix ./ordinary.nix ./default.nix ]",
            "[ " + " ".join("./" + name + ".nix" for name in modules) + " ]",
        )
        if override_lib:
            text = text.replace("inherit job;", '''specialArguments = {
              lib = (import (libraryTree.outPath + "/lib")) // {
                mkRenamedOptionModule = _from: _to: { config.new = 111; };
              };
            }; inherit job;''')
        projection.write_text(text)
        target = self.root / ".nixql/targets.nix"
        target.write_text(target.read_text()
            .replace('"literal.[name].with.dots"', '"R"')
            .replace('libVersion = "pinned-test"', 'libVersion = ' + json.dumps(self.inputs["nixpkgs"]["narHash"]))
            .replace('"demo" "answer"', " ".join(json.dumps(segment, ensure_ascii=False) for segment in path))
            .replace('[ "declarations" "definitions" "priority" ]', '[ "selection" ]')
            .replace("maxDepth = 0", "maxDepth = 1"))

    def oracle(self, *, witness_paths=()):
        arguments = {
            "modules": self.modules, "nixpkgs": self.inputs["nixpkgs"]["path"],
            "path": self.path, "specialLib": self.override_lib, "source": str(self.root),
            "witnessPaths": witness_paths,
        }
        encoded = json.dumps(json.dumps(arguments))
        result = subprocess.run([
            self.nix, "--extra-experimental-features", "nix-command", "eval", "--json", "--impure",
            "--file", str(Path(__file__).with_name("oracle.nix")),
            "--apply", "oracle: oracle (builtins.fromJSON " + encoded + ")",
        ], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def product(self, database):
        return self.installed_query(database, "RenamedOptions")

    def selected(self, database):
        return self.installed_query(database, "ModuleSelection")

    def health(self, database):
        return self.installed_query(database, "ExtractionHealth")

    def bindings(self, database):
        return self.query(database, "LibraryBindings", '''from @nx_request request,
          @nx_anchor functionAnchor, @nx_anchor formalAnchor, @nx_file file,
          string libHash, string modelHash, string path
          where nx_module_lib_bindings(request, functionAnchor, formalAnchor, libHash, modelHash)
            and nx_anchors(functionAnchor, file, _, _, _, _)
            and nx_files(file, _, path, _, _)
          select path, libHash, modelHash''')

    def capability(self, database, name):
        return self.query(database, "Capability" + name.replace("-", ""), '''from @nx_target target, string state
          where nx_capabilities(target, "''' + name + '''", state, _)
          select state''')

    def health_row(self, rows, kind, facet, target="R"):
        matching = [row for row in rows if row[:4] == [kind, target, "", facet]]
        self.assertEqual(len(matching), 1, rows)
        return matching[0]

    def row(self, name, kind, call, from_path, to_path):
        source = SOURCES[name].encode("utf-8")
        encoded = call.encode("utf-8")
        start = source.index(encoded)
        return ["R", name + ".nix", str(start), str(start + len(encoded)), kind,
                json.dumps(from_path, ensure_ascii=False, separators=(",", ":")),
                json.dumps(to_path, ensure_ascii=False, separators=(",", ":"))]

    def alias_count(self, database):
        return self.query(database, "AliasView", """import nix.Modules
          select count(Modules::AliasOption alias)""")

    def test_exact_r_row_upstream_value_and_forwarded_origin(self):
        self.fixture()
        database, _ = self.create()
        expected = self.row("rename", "rename", CALL, ["old"], ["new"])
        # The admitted stray source is uninvoked and must supply no extra edge.
        self.assertEqual(self.product(database), [expected])
        self.assertEqual(self.alias_count(database), [["0"]])
        frozen = [line.strip()[2:-2].split(" | ") for line in
                  (OWNER / "ql/test/inc3/renames/RenamedOptions.expected").read_text().splitlines()]
        self.assertEqual(frozen, [expected])
        oracle = self.oracle()
        print("M3r destination definition labels: " + json.dumps(oracle["destinationFiles"]), flush=True)
        self.assertEqual(oracle["value"], 7)
        self.assertEqual(len(oracle["warnings"]), 1)
        self.assertIn("old", oracle["warnings"][0])
        self.assertIn("new", oracle["warnings"][0])
        # The generated forwarding definition keeps its upstream origin; neither
        # the alias edge nor the equal value relocates it to the old assignment.
        self.assertNotIn("old.nix", oracle["destinationFiles"])
        self.assertEqual(self.selected(database),
                         [["R", "[]", PATH, "0", oracle["destinationFiles"][0], "100", "null"]])
        self.assertEqual(self.capability(database, "rename-models"), [["supported"]])
        # Health must state both halves of availability for the exact pin: the
        # supported model and the independently known three invoked lib formals,
        # without claiming exhaustive function coverage.
        health = self.health(database)
        self.assertEqual(self.health_row(health, "capability", "rename-models")[4], "supported")
        binding = self.health_row(health, "binding", "module-library-bindings")
        self.assertEqual((binding[4], binding[6]), ("partial", "3"))
        self.assertEqual({row[0] for row in self.bindings(database)},
                         {"options.nix", "rename.nix", "warnings.nix"})
        self.assertTrue(binding[5])

    def test_installed_qltest_runs_reviewed_r_expected(self):
        self.fixture()
        shutil.copy(OWNER / "ql/test/qlpack.yml", self.root / "qlpack.yml")
        shutil.copy(Path(os.environ["CODEQL_NIX_TEST_QUERIES"]) / "RenamedOptions.ql", self.root / "RenamedOptions.ql")
        shutil.copy(OWNER / "ql/test/inc3/renames/RenamedOptions.expected", self.root / "RenamedOptions.expected")
        result = self.run_codeql("test", "run", self.root,
            env=self.env | {"CODEQL_EXTRACTOR_NIX_OPTION_INPUTS": json.dumps(self.inputs)})
        print(result.stdout[-6000:] + result.stderr[-6000:], flush=True)

    def test_alias_module_aliases_without_the_rename_warning(self):
        self.fixture(("warnings", "options", "alias", "old"))
        database, _ = self.create()
        self.assertEqual(self.product(database),
                         [self.row("alias", "alias", 'lib.mkAliasOptionModule ["old"] ["new"]', ["old"], ["new"])])
        self.assertEqual(self.alias_count(database), [["1"]])
        oracle = self.oracle()
        self.assertEqual(oracle["value"], 7)
        self.assertEqual(oracle["warnings"], [])

    def test_local_aliases_preserve_helper_identity(self):
        for name, call in (("local", 'f ["old"] ["new"]'),
                           ("library", 'l.mkAliasOptionModule ["old"] ["new"]'),
                           ("inherited", 'mkAliasOptionModule ["old"] ["new"]'),
                           ("outward", 'f ["old"] ["new"]')):
            with self.subTest(alias=name):
                self.fixture(("warnings", "options", name, "old"))
                database, _ = self.create(name)
                self.assertEqual(self.product(database),
                                 [self.row(name, "alias", call, ["old"], ["new"])])
                self.assertEqual(self.oracle()["value"], 7)
                self.root = self.scratch / (name + "-next")
                self.root.mkdir()

    def test_shadowed_helper_is_not_recognized_and_the_sentinel_wins(self):
        self.fixture(("warnings", "options", "shadow"))
        database, _ = self.create()
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.oracle()["value"], 77)

    def test_dotted_segments_stay_exact_in_paths_and_direct_results(self):
        self.fixture(("warnings", "dotted", "legacy"), path=("c",))
        database, _ = self.create()
        self.assertEqual(self.product(database),
                         [self.row("dotted", "rename", 'lib.mkRenamedOptionModule ["a.b"] ["c"]', ["a.b"], ["c"])])
        oracle = self.oracle()
        self.assertEqual(oracle["value"], 7)
        self.assertEqual(len(oracle["warnings"]), 1)
        self.assertIn("a.b", oracle["warnings"][0])
        self.assertEqual(self.selected(database),
                         [["R", "[]", '["c"]', "0", oracle["destinationFiles"][0], "100", "null"]])

    def test_dynamic_and_deferred_argument_paths_have_no_proven_edge(self):
        for name in ("custom", "dynamic", "interpolated"):
            with self.subTest(module=name):
                self.fixture(("warnings", "options", name, "old"))
                database, _ = self.create(name)
                self.assertEqual(self.product(database), [])
                self.assertEqual(self.oracle()["value"], 7)
                self.root = self.scratch / (name + "-next")
                self.root.mkdir()

    def test_literal_paths_preserve_unicode_escapes_indentation_and_segment_boundaries(self):
        self.fixture(("warnings", "literals"), path=("new", "dotted"))
        database, _ = self.create()
        cases = [
            ("rename", 'lib.mkRenamedOptionModule ["a.b"] ["new" "dotted"]', ["a.b"], "dotted", 7),
            ("rename", 'lib.mkRenamedOptionModule ["a" "b"] ["new" "split"]', ["a", "b"], "split", 8),
            ("rename", r'lib.mkRenamedOptionModule ["o\"ld" "é\t\\end" "\${x}\r"] ["new" "é"]', ['o"ld', "é\t\\end", "${x}\r"], "é", 9),
            ("alias", "lib.mkAliasOptionModule [''single''] [\"new\" \"single\"]", ["single"], "single", 10),
            ("alias", "lib.mkAliasOptionModule [''\n    multi\n      line\n        ''] [\"new\" \"multiline\"]", ["multi\n  line\n"], "multiline", 11),
            ("alias", "lib.mkAliasOptionModule [''esc''\\n  next'''''${x}''] [\"new\" \"escaped\"]", ["esc\n  next''${x}"], "escaped", 12),
            ("alias", "lib.mkAliasOptionModule [''\n    ''\\n  z\n  ''] [\"new\" \"leading\"]", ["\nz\n"], "leading", 13),
            ("alias", "lib.mkAliasOptionModule [''\n    é𝄞\n  ''] [\"new\" \"𝄞new\"]", ["é𝄞\n"], "𝄞new", 14),
            ("alias", "lib.mkAliasOptionModule [''\n    a\n      \n''] [\"new\" \"blank\"]", ["a\n  \n"], "blank", 15),
        ]
        self.assertCountEqual(self.product(database), [
            self.row("literals", kind, call, old, ["new", destination])
            for kind, call, old, destination, _ in cases
        ])
        oracle = self.oracle(witness_paths=[["new", destination] for _, _, _, destination, _ in cases])
        self.assertEqual(oracle["values"], [value for _, _, _, _, value in cases])
        self.assertEqual(len(oracle["warnings"]), 3)

    def unfinalized_fixture(self, name):
        self.fixture()
        database = self.scratch / name
        self.run_codeql("database", "init", database, "--language=nix", "--source-root=" + str(self.root))
        self.run_codeql("database", "index-files", database, "--language=nix",
                        "--working-dir=" + str(self.root), "--include-extension=.nix",
                        "--extractor-option", "inputs=" + json.dumps(self.inputs))
        return database

    def filter_facts(self, database, keep):
        removed = 0
        # Transform only controlled F1 fixture rows; preserve raw syntax, UTF-8
        # and newlines byte-for-byte, including multiline string tokens.
        for path in sorted(database.rglob("*.trap")) + sorted(database.rglob("*.trap.gz")):
            opener = gzip.open if path.suffix == ".gz" else open
            with opener(path, "rt", encoding="utf-8", newline="") as stream:
                lines = stream.readlines()
            kept = [line for line in lines
                    if not (match := re.match(r"^(nx_[a-z_]+)\(", line)) or keep(match[1])]
            removed += len(lines) - len(kept)
            if len(lines) != len(kept):
                with opener(path, "wt", encoding="utf-8", newline="") as stream:
                    stream.writelines(kept)
        return removed

    def test_valid_target_without_capability_row_reports_missing_evidence(self):
        database = self.unfinalized_fixture("without-capability")
        removed = self.filter_facts(database, lambda relation: relation != "nx_capabilities")
        self.assertGreater(removed, 0)
        print(f"M3r absent-capability fixture: removed {removed} capability rows before import", flush=True)
        self.run_codeql("database", "finalize", database)
        health = self.health(database)
        self.assertEqual(self.health_row(health, "capability", "rename-models")[4:6],
                         ["unavailable", "rename helper model availability was not recorded"])

    def test_synthetic_targetless_syntax_run_reports_unavailable_health(self):
        retained = {"nx_anchors", "nx_files", "nx_runs", "nx_syntax_results"}
        # Validate this targetless source-only ABI shape with the independent
        # reviewed graph and the existing authority before transforming TRAP.
        loaded = {}
        for name, relative in (("abi", "schema/abi.py"), ("golden", "checks/fixtures/abi/golden.py")):
            spec = importlib.util.spec_from_file_location("targetless_" + name, OWNER / relative)
            loaded[name] = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(loaded[name])
        loaded["abi"].validate([row for row in loaded["golden"].GRAPH if row[0] in retained])
        database = self.unfinalized_fixture("targetless-syntax")
        removed = self.filter_facts(database, lambda relation: relation in retained)
        self.assertGreater(removed, 0)
        print(f"M3r targetless syntax fixture: removed {removed} evaluation facts before import", flush=True)
        self.run_codeql("database", "finalize", database)
        authenticated = self.query(database, "TargetlessSyntax", """select count(RawBridge::Node node)""")
        self.assertGreater(int(authenticated[0][0]), 0)
        health = self.health(database)
        self.assertEqual(self.health_row(health, "capability", "rename-models", target="")[4:],
                         ["unavailable", "no selected targets", ""])
        self.assertEqual(self.health_row(health, "binding", "module-library-bindings", target="")[4:],
                         ["unavailable", "no selected targets", "0"])

    def test_syntax_only_without_selection_request_states_binding_unavailable(self):
        # The contract's syntax-only shape: the helper call is extracted as
        # authenticated syntax, but no selection request publishes invocation
        # binding evidence, so no rename edge is proven. Health
        # states the supported exact-pin model beside unavailable, explained
        # bindings — absence is never a complete no-renames claim.
        self.fixture()
        target = self.root / ".nixql/targets.nix"
        target.write_text(target.read_text()
            .replace('[ "selection" ]', '[ "declarations" ]')
            .replace("maxDepth = 1", "maxDepth = 0"))
        database, _ = self.create()
        # The call's file is in the database as authenticated syntax, so the
        # empty product below is a real no-proven-edge outcome, not an empty run.
        anchors = self.query(database, "RenameSyntax", '''select count(@nx_anchor anchor |
          exists(@nx_file file | nx_files(file, _, "rename.nix", _, _)
            and nx_anchors(anchor, file, _, _, _, _)) | anchor)''')
        self.assertGreaterEqual(int(anchors[0][0]), 1)
        self.assertEqual(self.bindings(database), [])
        self.assertEqual(self.product(database), [])
        health = self.health(database)
        self.assertFalse([row for row in health if row[0] == "request" and row[3] == "selection"])
        self.assertEqual(self.health_row(health, "capability", "rename-models")[4], "supported")
        binding = self.health_row(health, "binding", "module-library-bindings")
        self.assertEqual((binding[4], binding[6]), ("unavailable", "0"))
        self.assertTrue(binding[5])

    def test_inactive_branches_are_source_claims(self):
        self.fixture(("warnings", "options", "inactive", "old"))
        database, _ = self.create("inactive")
        self.assertCountEqual(self.product(database), [
            self.row("inactive", "rename", 'lib.mkRenamedOptionModule ["old"] ["new"]', ["old"], ["new"]),
            self.row("inactive", "rename", 'lib.mkRenamedOptionModule ["never"] ["new"]', ["never"], ["new"]),
        ])
        self.assertEqual(self.oracle()["value"], 7)

    def test_special_arguments_lib_override_disables_helper_recognition(self):
        self.fixture(("options", "rename"), override_lib=True)
        database, _ = self.create()
        self.assertEqual(self.bindings(database), [])
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.oracle()["value"], 111)
        self.assertEqual(self.capability(database, "rename-models"), [["supported"]])
        # The override disables bindings, not the model pin: health states the
        # supported model beside unavailable, explained bindings, so the empty
        # product is an availability statement rather than a no-renames claim.
        health = self.health(database)
        self.assertEqual(self.health_row(health, "capability", "rename-models")[4], "supported")
        binding = self.health_row(health, "binding", "module-library-bindings")
        self.assertEqual((binding[4], binding[6]), ("unavailable", "0"))
        self.assertTrue(binding[5])

    def test_unproven_pin_states_unsupported_and_keeps_root_metadata(self):
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
        self.fixture()
        target = self.root / ".nixql/targets.nix"
        target.write_text(target.read_text()
            .replace('[ "selection" ]', '[ "selection" "priority" ]')
            .replace("maxDepth = 1", 'maxDepth = if facet == "priority" then 0 else 1'))
        self.assertEqual(self.oracle()["value"], 7)
        database, result = self.create("unproven-pin", success=False)
        if result.returncode:
            self.run_codeql("database", "finalize", database)
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.bindings(database), [])
        self.assertEqual(self.capability(database, "rename-models"), [["unsupported"]])
        # Health states the refused pin as an unsupported model beside
        # unavailable, explained bindings; the surviving root metadata above is
        # what keeps the refusal from reading as a no-renames claim.
        health = self.health(database)
        self.assertEqual(self.health_row(health, "capability", "rename-models")[4], "unsupported")
        binding = self.health_row(health, "binding", "module-library-bindings")
        self.assertEqual((binding[4], binding[6]), ("unavailable", "0"))
        self.assertTrue(binding[5])
        self.assertEqual(self.query(database, "UsableRootMetadata", '''from @nx_request request,
          @nx_option option, @nx_observation observation
          where nx_requests(request, _, _, "option-metadata", _, "priority", _, _, _, _, _)
            and nx_request_results(request, "complete", _, _)
            and nx_observations(observation, request, "pre-apply-metadata", "observed")
            and nx_observation_options(observation, option)
            and nx_option_metadata(option, "isDefined", "true") and nx_option_priority(option, "100")
          select count(option)'''), [["1"]])

    def test_generated_rename_identities_match_the_pinned_library(self):
        root = Path(self.inputs["nixpkgs"]["path"])
        model = json.loads((self.library / "models/modules.json").read_text())
        self.assertEqual(model["libHash"], self.inputs["nixpkgs"]["narHash"])
        payload = {key: value for key, value in model.items() if key not in {"bundleHash", "modelVersion"}}
        expected = "sha256:" + hashlib.sha256(json.dumps(payload, ensure_ascii=False,
            sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.assertEqual(model["modelVersion"], expected)
        helpers = {helper["name"]: helper for helper in model["helpers"]}
        # One generator owns property and rename identities in one shared bundle.
        self.assertTrue({"mkAfter", "mkAliasOptionModule", "mkBefore", "mkDefault", "mkForce",
                         "mkIf", "mkMerge", "mkOrder", "mkOverride", "mkRenamedOptionModule"}
                        <= set(helpers))
        for name, kind in (("mkRenamedOptionModule", "rename"), ("mkAliasOptionModule", "alias")):
            helper = helpers[name]
            self.assertEqual(helper["kind"], kind)
            self.assertTrue(helper["exportIdentity"])
            spec = json.loads(helper["argumentSpecJson"])
            self.assertEqual(spec["arity"], 2)
            self.assertEqual(json.dumps(spec, ensure_ascii=False, sort_keys=True,
                                        separators=(",", ":")), helper["argumentSpecJson"])
            self.assertIn(name, " ".join(self.checked_evidence(helper["evidence"], root)))

    def checked_evidence(self, records, root):
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


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(RenameTests(name) for name in sorted(RenameTests.__dict__) if name.startswith("test_"))

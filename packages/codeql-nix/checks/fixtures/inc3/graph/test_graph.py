"""M3g installed query tests frozen from the contract and independent Nix."""

import csv
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

from jsonschema import ValidationError

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "installed"))
import test_installed
from facts import complete

OWNER = Path(__file__).resolve().parents[4]
FIXTURE = Path(__file__).parent
EXPECTED = OWNER / "ql/test/inc3/graph/DisabledModules.expected"


class GraphTests(test_installed.InstalledTests):
    def run_codeql(self, *args, **kwargs):
        if args[:2] in (("dataset", "import"), ("dataset", "check")):
            original = self.command
            self.command = "flock"
            try:
                return super().run_codeql(os.environ["CODEQL_NIX_TEST_LOCK"], original, *args, **kwargs)
            finally:
                self.command = original
        return super().run_codeql(*args, **kwargs)

    def fixture(self, variant="G", *, nodes=5, depth=1, roots=("root.nix",)):
        super().fixture()
        self.roots = list(roots)
        for name in ("fixture.nix", "path-child.nix"):
            shutil.copy(FIXTURE / name, self.root / name)
        for name in self.roots:
            (self.root / name).write_text((FIXTURE / 'root.nix').read_text().replace('{}', '{ variant = ' + json.dumps(variant) + '; }'))
        projection = self.root / "projection.nix"
        projection.write_text(projection.read_text().replace(
            '[ ./options.nix ./ordinary.nix ./default.nix ]',
            '[ ' + ' '.join('./' + name for name in self.roots) + ' ]').replace(
            'inherit job;', 'specialArguments = { modulesPath = toString ./.; }; inherit job;'))
        target = self.root / ".nixql/targets.nix"
        target.write_text(target.read_text()
            .replace('"literal.[name].with.dots"', '"G"')
            .replace('domain = "option-metadata"', 'domain = "module-graph"')
            .replace('path = [ "demo" "answer" ]', 'path = []')
            .replace('[ "declarations" "definitions" "priority" ]', '[ "closure" ]')
            .replace('maxDepth = 0', 'maxDepth = ' + str(depth))
            .replace('maxNodes = 100', 'maxNodes = ' + str(nodes)))

    def oracle(self, *, collect=False, failure=False):
        arguments = {"collect": collect, "nixpkgs": self.inputs["nixpkgs"]["path"],
                     "roots": self.roots, "source": str(self.root)}
        result = subprocess.run([
            self.nix, "--extra-experimental-features", "nix-command", "eval", "--json", "--impure",
            "--file", str(FIXTURE / "oracle.nix"),
            "--apply", 'oracle: oracle (builtins.fromJSON ' + json.dumps(json.dumps(arguments)) + ')',
        ], env=self.env, capture_output=True, text=True, timeout=30)
        if failure:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("M3g disabled import sentinel", result.stderr)
            return
        self.assertEqual(result.returncode, 0, result.stderr)
        return [["G", "[]", row["occurrencePathJson"], row["key"], row["file"],
                 "true" if row["disabled"] else "false"] for row in json.loads(result.stdout)]

    def product(self, database):
        bqrs = self.scratch / "graph.bqrs"
        self.run_codeql("query", "run", Path(os.environ["CODEQL_NIX_TEST_QUERIES"]) / "DisabledModules.ql",
                        "--database=" + str(database), "--output=" + str(bqrs))
        result = self.run_codeql("bqrs", "decode", bqrs, "--format=csv", "--no-titles")
        bqrs.unlink()
        return list(csv.reader(io.StringIO(result.stdout)))

    def expected_g(self):
        return [line.strip()[2:-2].split(" | ") for line in EXPECTED.read_text().splitlines()]

    def assert_oracles(self, expected):
        self.assertEqual(self.oracle(), expected)
        self.assertEqual(self.oracle(collect=True), expected)

    def test_exact_g_rows_duplicates_typed_witnesses_and_synthetic_labels(self):
        self.fixture()
        expected = self.expected_g()
        self.assert_oracles(expected)
        database, _ = self.create()
        self.assertCountEqual(self.product(database), expected)
        self.assertEqual(self.query(database, "GraphWitnesses", '''select
          count(@nx_module m | nx_modules(m, _, _, _, _) | m),
          count(@nx_observation o | nx_observation_contexts(o, _) | o),
          count(@nx_observation o | nx_observation_modules(o, _) | o),
          count(@nx_option o | nx_options(o, _, _) | o),
          count(@nx_definition d | nx_definitions(d, _, _, _) | d),
          count(@nx_request q | nx_request_results(q, "complete", _, 5) | q)'''), [["4", "1", "4", "0", "0", "1"]])
        self.assertEqual(self.query(database, "GraphSyntheticOrigins", '''select count(@nx_origin o |
          nx_modules(_, _, _, o, _) and nx_origin_files(o, _) | o)'''), [["0"]])

    def test_disabled_flag_mutations_preserve_occurrences_and_support_root(self):
        for variant in ("no-disabling", "disable-root", "other-key", "anon-key", "anon-disable"):
            with self.subTest(variant=variant):
                self.fixture(variant)
                expected = self.expected_g()
                if variant == "no-disabling":
                    expected[1][5] = expected[2][5] = "false"
                elif variant == "disable-root":
                    expected[0][5] = "true"
                    expected[1][5] = expected[2][5] = "false"
                elif variant == "other-key":
                    expected[2][3], expected[2][5] = "other", "false"
                elif variant == "anon-key":
                    expected[0][3] = ":anon-2"
                    expected[1][5] = expected[2][5] = "false"
                else:
                    expected[1][5] = expected[2][5] = "false"
                    expected[3][5] = "true"
                self.assert_oracles(expected)
                database, _ = self.create(variant)
                self.assertCountEqual(self.product(database), expected)
                self.root = self.scratch / (variant + "-next")
                self.root.mkdir()

    def test_duplicate_root_keys_keep_ordered_occurrence_trees(self):
        self.fixture(roots=("root.nix", "second.nix"), nodes=8)
        expected = self.expected_g()[:3]
        expected += [[row[0], row[1], row[2].replace("[0", "[1", 1), *row[3:]] for row in expected[:3]]
        expected += [["G", "[]", "[2]", ":anon-3", "<unknown-file>", "false"]]
        self.assert_oracles(expected)
        database, _ = self.create()
        self.assertCountEqual(self.product(database), expected)
        # Distinguishable roots make a root-order reversal observable too.
        (self.root / "second.nix").write_text('(import ./fixture.nix {}).root // { key="second"; _file="second.nix"; }')
        expected[3][3:5] = ["second", "second.nix"]
        self.assert_oracles(expected)
        database, _ = self.create("distinct-roots")
        self.assertCountEqual(self.product(database), expected)

    def test_path_and_relative_disabling_use_modules_path_without_causal_edges(self):
        for variant in ("path-disable", "relative-disable"):
            with self.subTest(variant=variant):
                self.fixture(variant, nodes=4)
                expected = [["G", "[]", "[0]", "root", "root.nix", "false"],
                            ["G", "[]", "[0,0]", str(self.root / "path-child.nix"), "path-child.nix", "true"],
                            ["G", "[]", "[1]", ":anon-2", "<unknown-file>", "false"]]
                self.assert_oracles(expected)
                database, _ = self.create(variant)
                actual = self.product(database)
                # Evaluation uses an admitted Nix copy, so the absolute source
                # prefix differs. Assert every literal component and the flag;
                # only the authenticated snapshot location is relocated.
                child = next(row for row in actual if row[2] == "[0,0]")
                self.assertTrue(child[3].startswith("/nix/store/"), child)
                self.assertTrue(child[3].endswith("/path-child.nix"), child)
                child[3] = str(self.root / "path-child.nix")
                self.assertCountEqual(actual, expected)
                self.root = self.scratch / (variant + "-next")
                self.root.mkdir()

    def test_depth_zero_root_leaves_and_budget_refusal_are_atomic(self):
        self.fixture("roots-only", nodes=3, depth=0)
        expected = [self.expected_g()[0], self.expected_g()[3]]
        self.assert_oracles(expected)
        database, _ = self.create("root-leaves")
        self.assertCountEqual(self.product(database), expected)
        for name, nodes, depth in (("nodes", 4, 1), ("depth", 5, 0)):
            self.root = self.scratch / name
            self.root.mkdir()
            self.fixture(nodes=nodes, depth=depth)
            self.assert_oracles(self.expected_g())
            database, result = self.create(name + "-db", success=False)
            self.assertNotEqual(result.returncode, 0)
            self.run_codeql("database", "finalize", database)
            self.assertEqual(self.product(database), [])
            self.assertEqual(self.query(database, "NoGraphPartial", '''select count(@nx_module m |
              nx_modules(m, _, _, _, _) | m)'''), [["0"]])

    def test_disabled_import_throw_fails_instead_of_empty_complete(self):
        self.fixture("disabled-throw")
        self.oracle(failure=True)
        self.oracle(collect=True, failure=True)
        database, result = self.create(success=False)
        self.assertNotEqual(result.returncode, 0)
        self.run_codeql("database", "finalize", database)
        self.assertEqual(self.product(database), [])
        self.assertEqual(self.query(database, "ThrowFailed", '''select count(@nx_request q |
          nx_requests(q, _, _, "module-graph", _, _, _, _, _, _, _)
          and nx_request_results(q, "failed", _, 0) | q)'''), [["1"]])

    def test_second_identical_target_is_isolated(self):
        self.fixture()
        target = self.root / ".nixql/targets.nix"
        text = target.read_text()
        text = text.replace('manifest = {', 'manifest = rec {')
        text = text.replace('targets."G" = {', 'targets = { "H" = targets."G"; "G" = {')
        text = text.replace('syntaxOnlyFallback = false; system = "x86_64-linux";\n            };',
                            'syntaxOnlyFallback = false; system = "x86_64-linux";\n            }; };')
        target.write_text(text)
        self.assert_oracles(self.expected_g())
        database, _ = self.create()
        expected = self.expected_g()
        self.assertCountEqual(self.product(database), expected + [["H", *row[1:]] for row in expected])
        self.assertEqual(self.query(database, "TargetModuleCount", '''select count(@nx_module m |
          nx_modules(m, _, _, _, _) | m)'''), [["8"]])

    def test_installed_qltest_consumes_reviewed_g_expected(self):
        self.fixture()
        self.assert_oracles(self.expected_g())
        shutil.copy(OWNER / "ql/test/qlpack.yml", self.root / "qlpack.yml")
        shutil.copy(Path(os.environ["CODEQL_NIX_TEST_QUERIES"]) / "DisabledModules.ql", self.root / "DisabledModules.ql")
        qltest_expected = "\n".join(sorted(EXPECTED.read_text().splitlines())) + "\n"
        (self.root / "DisabledModules.expected").write_text(qltest_expected)
        result = self.run_codeql("test", "run", self.root,
            env=self.env | {"CODEQL_EXTRACTOR_NIX_OPTION_INPUTS": json.dumps(self.inputs)})
        print(result.stdout[-6000:] + result.stderr[-6000:], flush=True)

    def test_native_booleans_import_into_real_schema_and_invalid_packets_refuse(self):
        sys.path.insert(0, str(OWNER / "src/eval"))
        import protocol
        packet = complete()
        protocol.envelope(packet["facts"])
        trap = self.scratch / "graph.trap"
        trap.write_text(protocol.trap(packet["facts"]))
        dataset = self.scratch / "typed-dataset"
        self.run_codeql("dataset", "import", "--threads=4", "--dbscheme=" + str(self.extractor / "nix.dbscheme"),
                        "--fail-on-trap-errors", dataset, trap)
        self.run_codeql("dataset", "check", dataset)
        for invalid in (0, 1, "true", "false"):
            malformed = complete()
            next(args for table, args in malformed["facts"] if table == "nx_modules")[4] = invalid
            with self.subTest(invalid=invalid), self.assertRaises((ValueError, ValidationError)):
                protocol.envelope(malformed["facts"])


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(GraphTests(name) for name in sorted(GraphTests.__dict__) if name.startswith("test_"))

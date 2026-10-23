"""I2a contract oracles: expected rows precede the import implementation."""

import csv
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

OWNER = Path(__file__).resolve().parents[3]
FIXTURE = OWNER / "ql/test/imports"


def materialize(destination):
    for source in FIXTURE.rglob("*.nix.in"):
        target = destination / source.relative_to(FIXTURE).with_suffix("")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(source, target)
    (destination / "sub").mkdir()
    # The file exists but lies outside the extractor's admitted source root.
    (destination.parent / "external.nix").write_text("157\n")


class ImportTests(unittest.TestCase):
    def test_real_nix_shadowing_relative_missing_and_isolated_scope(self):
        with tempfile.TemporaryDirectory(prefix="i2a-oracle-") as temporary:
            root = Path(temporary) / "source"
            root.mkdir()
            materialize(root)
            expressions = (root / "imports.nix").read_text().splitlines()[1:-1]
            expected = [149, 149, 149, 127, 131, "missing", 149,
                        "undefined variable", 149, 151, 157, 163]
            self.assertEqual(len(expressions), len(expected))
            for line, (expression, value) in enumerate(zip(expressions, expected), 2):
                with self.subTest(line=line):
                    # A file supplies the logical base; the process cwd differs.
                    probe = root / "oracle.nix"
                    probe.write_text(expression)
                    self.evaluate(probe, value, root.parent)
            self.evaluate(root / "nested/relative.nix", 149, root.parent)
        print("I2a Nix witnesses: builtin/local/namespace/argument shadowing, relative parent paths, missing input, applied import and isolated scope passed", flush=True)

    def evaluate(self, source, expected, cwd):
        result = subprocess.run([os.environ.get("CODEQL_NIX_TEST_NIX", "nix"),
            "--extra-experimental-features", "nix-command", "eval", "--json",
            "--impure", "--file", str(source)], cwd=cwd,
            capture_output=True, text=True, timeout=30)
        if isinstance(expected, str):
            self.assertNotEqual(result.returncode, 0)
            self.assertRegex(result.stderr, "No such file|does not exist" if expected == "missing" else expected)
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), expected)

    def installed_harness(self):
        spec = importlib.util.spec_from_file_location("i2a_installed", OWNER / "checks/fixtures/installed/test_installed.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.InstalledTests.setUpClass()
        harness = module.InstalledTests()
        harness.setUp()
        self.addCleanup(harness.doCleanups)
        return harness

    def test_import_graph_expected_rows_and_installed_query(self):
        harness = self.installed_harness()
        harness.fixture()
        materialize(harness.root)
        shutil.copy(OWNER / "ql/test/qlpack.yml", harness.root / "qlpack.yml")
        for name in ("ImportGraph.ql", "ImportGraph.expected"):
            shutil.copy(FIXTURE / name, harness.root / name)
        result = harness.run_codeql("test", "run", harness.root,
            env=harness.env | {"CODEQL_EXTRACTOR_NIX_OPTION_INPUTS": json.dumps(harness.inputs)})
        print(result.stdout[-2000:] + result.stderr[-2000:], flush=True)
        database, _ = harness.create()
        output = harness.scratch / "imports.bqrs"
        harness.run_codeql("query", "run", OWNER / "ql/queries/ImportGraph.ql",
            "--database=" + str(database), "--output=" + str(output))
        decoded = harness.run_codeql("bqrs", "decode", output, "--format=csv", "--no-titles")
        expected = [line[2:-2].split(" | ") for line in
                    (FIXTURE / "ImportGraph.expected").read_text().splitlines()]
        # The existing evalModules fixture contributes imports in projection.nix.
        rows = [row for row in csv.reader(io.StringIO(decoded.stdout))
                if row[0] in ("imports.nix", "nested/relative.nix")]
        self.assertCountEqual(rows, expected)
        output.unlink()
        print("I2a ImportGraph frozen rows and production query: proven builtin sites, shadow exclusion, admitted literal targets and unavailable dynamic/missing roots passed", flush=True)
        alternate = harness.scratch / "incompatible-library"
        shutil.copytree(harness.library, alternate)
        generated = alternate / "nix/internal/generated/Builtins.qll"
        fingerprint = json.loads((harness.library / "models/builtins.json").read_text())["modelVersion"]
        generated.chmod(0o644)
        generated.write_text(generated.read_text().replace(fingerprint, "sha256:" + "0" * 64))
        harness.command = os.environ["CODEQL_NIX_TEST_BARE_COMMAND"]
        harness.run_codeql("query", "run", harness.root / "ImportGraph.ql",
            "--database=" + str(database), "--output=" + str(output),
            "--search-path=" + str(alternate))
        decoded = harness.run_codeql("bqrs", "decode", output, "--format=csv", "--no-titles")
        self.assertEqual(list(csv.reader(io.StringIO(decoded.stdout))), [])
        output.unlink()
        print("I2a incompatible M3 identity: no builtin import sites or edges inferred from spelling passed", flush=True)

    def test_source_map_targets_and_exact_source_identity_correlation(self):
        harness = self.installed_harness()
        base = harness.root
        absolute = base / "dep/target.nix"
        main = ("[\n  (import ../dep/target.nix)\n  (import ./target.nix)\n"
                f"  (import {absolute})\n"
                '  (let name = "target"; in import ./${name}.nix)\n'
                "  (import ../outside/target.nix)\n]\n")
        link_main = f"[\n  (import ./link.nix)\n  (import {base / 'links/link.nix'})\n]\n"
        source_main = "import ./target.nix"
        sources = {"a": {".nix": "191", "main.nix": main, "target.nix": "167"},
                   "b": {".nix": "193", "main.nix": main, "target.nix": "173"},
                   "decoy": {"target.nix": "181"}, "dep": {"target.nix": "157"},
                   "links": {"main.nix": link_main, "real.nix": "181"},
                   "outside": {"target.nix": "197"},
                   "source-link": {"sub/main.nix": source_main, "sub/target.nix": "173", "target.nix": "167"}}
        for directory, files in sources.items():
            (base / directory).mkdir()
            for name, content in files.items():
                (base / directory / name).parent.mkdir(parents=True, exist_ok=True)
                (base / directory / name).write_text(content)
        (base / "links/link.nix").symlink_to("real.nix")
        (base / "source-link/main.nix").symlink_to("sub/main.nix")
        # Root aliases share bytes, but separate physical source bases differ.
        selected = {"a": ("a", [".nix", "main.nix", "target.nix"]),
                    "alias": ("a", ["main.nix"]), "b": ("b", [".nix", "main.nix"]),
                    "decoy": ("decoy", ["target.nix"]), "dep": ("dep", ["target.nix"]),
                    "links": ("links", ["link.nix", "main.nix"]),
                    "source-link": ("source-link", ["main.nix", "sub/target.nix", "target.nix"])}
        digest = lambda text: hashlib.sha256(text.encode()).hexdigest()
        roots = [{"files": [{"contentHash": digest((base / directory / name).read_text()), "path": name}
                            for name in names], "logicalName": logical, "path": str(base / directory),
                  "rootContentIdentity": "map-test", "sourceKind": "project"}
                 for logical, (directory, names) in selected.items()]
        manifest = harness.scratch / "map.json"
        manifest.write_text(json.dumps({"roots": roots}))
        for directory, values in (("a", [157, 167, 157, 167, 197]), ("b", [157, 173, 157, 173, 197]),
                                  ("links", [181, 181]), ("source-link", 173)):
            self.evaluate(base / directory / "main.nix", values, harness.scratch)
        print("I2a source-map Nix witnesses: sibling/absolute imports, physical bases, interpolation, files outside the admitted set and target/source symlinks passed", flush=True)
        database = harness.scratch / "map-db"
        harness.run_codeql("database", "init", database, "--language=nix", "--source-root=" + str(base))
        extracted = subprocess.run([os.environ["NIXQL_SYNTAX_DRIVER"], str(manifest),
                                   str(harness.scratch / "map-output")], env=harness.env | {
            "CODEQL_EXTRACTOR_NIX_TRAP_DIR": str(database / "trap/nix"),
            "CODEQL_EXTRACTOR_NIX_SOURCE_ARCHIVE_DIR": str(database / "src")},
            capture_output=True, text=True, timeout=120)
        self.assertEqual(extracted.returncode, 0, extracted.stderr)
        harness.run_codeql("database", "finalize", database)
        output = harness.scratch / "identity.bqrs"
        harness.run_codeql("query", "run", FIXTURE / "Identity.ql",
                          "--database=" + str(database), "--output=" + str(output))
        decoded = harness.run_codeql("bqrs", "decode", output, "--format=csv", "--no-titles")
        # Full root/path/hash tuples uniquely identify @nx_file, even aliases.
        root_key = lambda name: f"nixql:v1:root:{len(name)}:{name}8:map-test"
        expected = []
        for source in ("a", "alias", "b"):
            for line in range(2, 7):
                prefix = [root_key(source), digest(main), str(line)]
                if line in (2, 4) or line == 3 and source != "b":
                    target, value = ("a", "167") if line == 3 else ("dep", "157")
                    expected.append(prefix + ["resolved", root_key(target), "target.nix", digest(value), ""])
                else:
                    expected.append(prefix + ["unavailable", "", "", "",
                                              "dynamic-path" if line == 5 else "missing-input"])
        for root, content, line, target, value in (
                ("links", link_main, 2, "link.nix", "181"),
                ("links", link_main, 3, "link.nix", "181"),
                ("source-link", source_main, 1, "sub/target.nix", "173")):
            expected.append([root_key(root), digest(content), str(line), "resolved",
                             root_key(root), target, digest(value), ""])
        self.assertCountEqual(list(csv.reader(io.StringIO(decoded.stdout))), expected)
        output.unlink()
        print("I2a source-map identity: 18 exact source/target pairs; admitted sibling/absolute/symlink targets, canonical source directory, decoys, aliases, interpolation and targets outside the admitted set passed", flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)

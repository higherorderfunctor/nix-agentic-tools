"""P2a installed-path acceptance, frozen before the coordinator is written.

Oracles: F1 relation meanings, F2 descriptors, direct lib.evalModules metadata,
and SHA-256 of installed schema bytes. Never bless implementation query output.
"""

import csv
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from installed_session import Session, tree_digest, variant_key


class InstalledTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.command = os.environ["CODEQL_NIX_TEST_COMMAND"]
        cls.extractor = Path(os.environ["CODEQL_NIX_TEST_EXTRACTOR"])
        cls.library = Path(os.environ["CODEQL_NIX_TEST_LIBRARY"])
        cls.nix = os.environ["CODEQL_NIX_TEST_NIX"]
        cls.inputs = {}
        for name, variable in (("nixpkgs", "CODEQL_NIX_TEST_NIXPKGS"), ("nixql", "CODEQL_NIX_TEST_OWNER")):
            path = os.environ[variable]
            result = subprocess.run([cls.nix, "--extra-experimental-features", "nix-command", "hash", "path", path], capture_output=True, text=True, check=True)
            cls.inputs[name] = {"path": path, "narHash": result.stdout.strip()}

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="p2a-", dir=os.environ.get("CODEQL_NIX_TEST_SCRATCH"))
        self.addCleanup(self.temp.cleanup)
        self.scratch = Path(self.temp.name)
        self.root = self.scratch / "source"
        self.root.mkdir()
        self.env = os.environ | {"HOME": str(self.scratch / "home"), "CODEQL_CONFIG_FILE": "/dev/null", "NIX_PATH": "", "NIX_CONFIG": "substitute = false\nbuilders =\nmax-jobs = 0\n"}
        self.session = Session(Path(os.environ.get("CODEQL_NIX_TEST_SESSION", self.scratch / "session")))
        Path(self.env["HOME"]).mkdir()

    def run_codeql(self, *args, success=True, env=None):
        argv = [self.command, *map(str, args)]
        if args[:2] in (("database", "create"), ("database", "index-files"), ("database", "finalize"), ("query", "run"), ("test", "run")):
            argv = ["flock", os.environ["CODEQL_NIX_TEST_LOCK"], *argv, "--threads=4", "--ram=6000"]
        result = subprocess.run(argv, cwd=self.scratch, env=self.env if env is None else env, capture_output=True, text=True, timeout=900)
        if success:
            self.assertEqual(result.returncode, 0, " ".join(argv) + "\n" + result.stdout[-12000:] + result.stderr[-12000:])
        return result

    def fixture(self):
        (self.root / ".nixql").mkdir()
        for name, text in {
            "default.nix": "{lib,...}: { demo.answer = lib.mkDefault 23; }",
            "options.nix": "{lib,...}: { options.demo.answer = lib.mkOption { type = lib.types.int; apply = _: throw \"post-apply poison\"; }; }",
            "ordinary.nix": "{...}: let answer = 17; in { demo.answer = answer; }",
            "projection.nix": '''{job}: let
              adapterTree = builtins.fetchTree (job.moduleArguments.nixql // { type = "path"; });
              libraryTree = builtins.fetchTree (job.moduleArguments.nixpkgs // { type = "path"; });
            in import (adapterTree.outPath + "/src/eval/nix/modules.nix") {
              lib = import (libraryTree.outPath + "/lib");
              modules = [ ./options.nix ./ordinary.nix ./default.nix ];
              inherit job;
            }''',
        }.items():
            (self.root / name).write_text(text)
        target = '''{ inputs, source }: {
          manifest = {
            manifestVersion = 1;
            targets."literal.[name].with.dots" = {
              adapter = "evalModules"; adapterVersion = "1";
              argumentDescription = { hash = "fixture-arguments"; moduleArgumentsRef = "module:1"; specialArgumentsRef = "special:1"; };
              evaluation = { kind = "rich-result"; reference = "eval:1"; };
              fingerprint = { evaluatorVersion = "pinned-test"; libVersion = "pinned-test"; modelVersion = "not-requested"; policyHash = "offline"; sourceSnapshotHash = "coordinator-admitted"; };
              inputIdentities = { project = "fixture-project"; };
              observationModes = [ "metadata" ];
              requests = map (facet: { domain = "option-metadata"; inherit facet;
                path = [ "demo" "answer" ]; maxBytes = 1048576; maxDepth = 0;
                maxMemoryMiB = 1024; maxNodes = 100; maxSeconds = 30;
              }) [ "declarations" "definitions" "priority" ];
              sourceRoots = map (entry: { inherit (entry) logicalName path; rootContentIdentity = "fixture-admitted"; }) [
                { logicalName = "project"; path = toString source; }
                { logicalName = "nixpkgs"; path = NIXPKGS_PATH; }
                { logicalName = "nixql"; path = NIXQL_PATH; }
              ];
              syntaxOnlyFallback = false; system = "x86_64-linux";
            };
          };
          bindings = {
            "eval:1" = { expression = toString source + "/projection.nix"; };
            "module:1" = {
              nixpkgs = { path = NIXPKGS_PATH; narHash = NIXPKGS_HASH; };
              nixql = { path = NIXQL_PATH; narHash = NIXQL_HASH; };
            };
            "special:1" = {};
          };
        }'''
        for name, descriptor in self.inputs.items():
            target = target.replace(name.upper() + "_PATH", json.dumps(descriptor["path"]))
            target = target.replace(name.upper() + "_HASH", json.dumps(descriptor["narHash"]))
        (self.root / ".nixql/targets.nix").write_text(target)

    def installed_authority(self):
        if not hasattr(self, "_installed_authority"):
            wrapper = (self.extractor / "tools/autobuild.sh").resolve().read_text()
            invocation = shlex.split(next(line for line in wrapper.splitlines() if line.startswith("exec ")))
            if len(invocation) != 8:
                raise AssertionError("incomplete installed coordinator invocation")
            extract_spec = importlib.util.spec_from_file_location("nixql_installed_extract", invocation[2])
            extract = importlib.util.module_from_spec(extract_spec)
            extract_spec.loader.exec_module(extract)
            abi_path = Path(invocation[4]) / "abi.py"
            abi_spec = importlib.util.spec_from_file_location("nixql_installed_abi", abi_path)
            abi = importlib.util.module_from_spec(abi_spec)
            abi_spec.loader.exec_module(abi)
            self._installed_authority = (invocation, extract.RunIdentity, abi)
        return self._installed_authority

    def installed_identities(self, expected_run):
        if not hasattr(self, "_installed_identities"):
            invocation, _, _ = self.installed_authority()
            model = (self.library / "models/modules.json").read_bytes()
            versions = json.loads(Path(invocation[6]).read_text())
            row = expected_run.row[1]
            self._installed_identities = {
                "extractor": row[2], "grammar": versions["grammar"], "model": row[4],
                "modelFile": hashlib.sha256(model).hexdigest(), "schema": row[1],
            }
            self._installed_identities["product"] = hashlib.sha256(
                Path(self.command).resolve().read_bytes() + json.dumps(
                    self._installed_identities, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        return self._installed_identities | {"snapshot": tree_digest(self.root)}

    def requested_run_identity(self, targets, inputs):
        invocation, run_identity, abi = self.installed_authority()
        handles = "".join("${" + json.dumps(name) + "} = { outPath = " + json.dumps(entry["path"]) +
                          "; narHash = " + json.dumps(entry["narHash"]) + "; };"
                          for name, entry in sorted(inputs.items()))
        expression = ("let source = { outPath = " + json.dumps(str(self.root)) + "; }; inputs = { " +
                      handles + " }; in import " + json.dumps(str(Path(targets).resolve())) +
                      " { inherit inputs source; }")
        result = subprocess.run(
            [self.nix, "--extra-experimental-features", "nix-command", "eval", "--json", "--impure", "--expr", expression],
            env=self.env, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout[-4096:] + result.stderr[-4096:])
        manifest = json.loads(result.stdout)["manifest"]
        project_roots = {abi.canonical(root): root for target in manifest["targets"].values()
                         for root in target["sourceRoots"] if Path(root["path"]).resolve() == self.root.resolve()}
        result = subprocess.run(
            [self.nix, "--extra-experimental-features", "nix-command", "hash", "path", str(self.root)],
            env=self.env, capture_output=True, text=True, check=True)
        project_hash = result.stdout.strip()
        files = [{"path": path.relative_to(self.root).as_posix(), "contentHash": hashlib.sha256(path.read_bytes()).hexdigest()}
                 for path in sorted(self.root.rglob("*.nix")) if path.is_file()]
        roots = [root | {"path": str(self.root), "rootContentIdentity": project_hash, "files": files}
                 for root in project_roots.values()]
        roots += [{"logicalName": name, "rootContentIdentity": entry["narHash"], "files": []}
                  for name, entry in sorted(inputs.items())]
        return run_identity.syntax(abi, Path(invocation[3]), Path(invocation[5]), Path(invocation[6]), {"roots": roots})

    def validate_session_database(self, database, key, identities, expected_run):
        marker = json.dumps({"identities": identities, "key": key}, sort_keys=True, separators=(",", ":"))
        if not (database / "ready").is_file() or (database / "ready").read_text() != marker:
            raise ValueError("installed session identity mismatch")
        runs = self.query(database, "SessionRun", """from @nx_run run, string schema, string extractor,
              string grammar, string model, string snapshot
            where nx_runs(run, schema, extractor, grammar, model, snapshot)
            select count(@nx_run r | nx_runs(r, _, _, _, _, _) | r),
              schema, extractor, grammar, model, snapshot""")
        self.assertEqual(len(runs), 1)
        self.assertEqual(tuple(runs[0]), tuple(["1", *expected_run.row[1][1:]]))
        phases = self.query(database, "SessionPhases", """from @nx_run run, string phase, string state, string reason
            where nx_phases(run, phase, state, reason) select phase, state""")
        self.assertTrue(phases)
        self.assertTrue(all(row[1] == "complete" for row in phases), phases)

    def create(self, name="db", *, inputs=None, targets=None, success=True):
        selected_inputs = self.inputs if inputs is None else inputs
        selected_targets = self.root / ".nixql/targets.nix" if targets is None else Path(targets)
        options = {"inputs": selected_inputs}
        if targets is not None:
            options["targets"] = str(targets)
        arguments = ["--extractor-option", "inputs=" + json.dumps(selected_inputs)]
        if targets is not None:
            arguments += ["--extractor-option", "targets=" + str(targets)]
        if not success:
            database = self.scratch / name
            return database, self.run_codeql("database", "create", database, "--language=nix",
                                             "--source-root=" + str(self.root), *arguments, success=False)
        expected_run = self.requested_run_identity(selected_targets, selected_inputs)
        identities = self.installed_identities(expected_run)
        manifest = selected_targets.read_bytes() if selected_targets.exists() else b""
        key = variant_key(self.root, inputs=selected_inputs, manifest=manifest,
                          options=options, identities=identities)
        marker = json.dumps({"identities": identities, "key": key}, sort_keys=True, separators=(",", ":"))
        built = []

        def build(database):
            built.append(self.run_codeql("database", "create", database, "--language=nix",
                                         "--source-root=" + str(self.root), *arguments))
            (database / "ready").write_text(marker)

        database = self.session.database(
            key, build,
            lambda database: self.validate_session_database(database, key, identities, expected_run))
        return database, built[0] if built else None

    def query(self, database, name, body):
        pack = self.scratch / "queries"
        pack.mkdir(exist_ok=True)
        (pack / "qlpack.yml").write_text('name: nix-agentic-tools/p2a-acceptance\nversion: 0.0.0\ndependencies:\n  nix-agentic-tools/nix-all: "*"\n')
        query = pack / (name + ".ql")
        query.write_text("import nix.internal.RawBridge\n" + body + "\n")
        bqrs = self.scratch / (name + ".bqrs")
        self.run_codeql("query", "run", query, "--database=" + str(database), "--output=" + str(bqrs))
        result = self.run_codeql("bqrs", "decode", bqrs, "--format=csv", "--no-titles")
        rows = list(csv.reader(io.StringIO(result.stdout)))
        bqrs.unlink()
        return rows

    def installed_query(self, database, name):
        bqrs = self.scratch / (name + ".bqrs")
        self.run_codeql("query", "run", Path(os.environ["CODEQL_NIX_TEST_QUERIES"]) / (name + ".ql"),
                        "--database=" + str(database), "--output=" + str(bqrs))
        decoded = self.run_codeql("bqrs", "decode", bqrs, "--format=csv", "--no-titles")
        bqrs.unlink()
        return list(csv.reader(io.StringIO(decoded.stdout)))

    def test_installed_suites_compile_without_database(self):
        suites = Path(os.environ["CODEQL_NIX_TEST_QUERIES"])
        for name in ("metadata.qls", "source.qls", "values.qls"):
            suite = suites / name
            self.assertTrue(suite.is_file(), name)
            self.run_codeql("query", "compile", "--check-only", "--threads=2", suite)

    def test_offline_resolution_and_schema_equality(self):
        result = self.run_codeql("resolve", "languages", "--format=json")
        self.assertIn('"nix"', result.stdout)
        result = self.run_codeql("resolve", "qlpacks", "--format=json")
        self.assertIn("nix-agentic-tools/nix-all", result.stdout)
        self.assertEqual((self.extractor / "nix.dbscheme").read_bytes(), (self.library / "nix.dbscheme").read_bytes())
        for name in ("autobuild.sh", "index-files.sh", "qltest.sh"):
            self.assertTrue(os.access(self.extractor / "tools" / name, os.X_OK), name)

    def test_database_contains_syntax_and_real_module_metadata_one_run(self):
        self.fixture()
        database, _ = self.create()
        metrics = self.query(database, "Counts", '''select
          count(@nx_run r | nx_runs(r, _, _, _, _, _) | r),
          count(@nx_anchor a | nx_anchors(a, _, _, _, _, _) | a),
          count(@nx_definition d | nx_definitions(d, _, _, _) | d),
          count(@nx_option o | nx_options(o, _, _) | o),
          count(@nx_request q | nx_request_results(q, "complete", _, _) | q)''')
        self.assertEqual(len(metrics), 1)
        runs, anchors, definitions, options, complete = map(int, metrics[0])
        self.assertEqual((runs, definitions, options, complete), (1, 1, 3, 3))
        self.assertGreater(anchors, 0)
        schema_hash = hashlib.sha256((self.extractor / "nix.dbscheme").read_bytes()).hexdigest()
        identity = self.query(database, "Identity", '''from @nx_run r, string schema, string model, string snapshot
          where nx_runs(r, schema, _, _, model, snapshot)
          select schema, model, snapshot''')
        self.assertEqual(identity[0][0], schema_hash)
        self.assertEqual(identity[0][1], json.loads((self.library / "models/modules.json").read_text())["bundleHash"])
        self.assertNotIn(identity[0][2], ("", "not-admitted"))
        self.assertCountEqual(self.query(database, "Phases", '''from @nx_run r, string phase, string state
          where nx_phases(r, phase, state, _) select phase, state'''), [["discovery", "complete"], ["evaluation", "complete"], ["syntax", "complete"]])
        self.assert_metadata(database, "100")
        (self.root / "default.nix").write_text("{lib,...}: { demo.answer = lib.mkOverride 50 23; }")
        changed, _ = self.create("override-db")
        self.assert_metadata(changed, "50")

    def assert_metadata(self, database, expected):
        setup = 'lib = import ' + json.dumps(self.inputs["nixpkgs"]["path"] + "/lib") + '; result = lib.evalModules { modules = [ ' + " ".join(str(self.root / name) for name in ("options.nix", "ordinary.nix", "default.nix")) + ' ]; };'
        oracle = subprocess.run([self.nix, "--extra-experimental-features", "nix-command", "eval", "--json", "--impure", "--expr", "let " + setup + " in toString result.options.demo.answer.highestPrio"], env=self.env, capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(oracle.stdout), expected)
        rows = self.query(database, "Priority" + expected, '''from @nx_target t, @nx_context c, @nx_option o, string name, string path, string priority
          where nx_targets(t, _, name, "evalModules", _, _, _, _, _, "complete") and
            nx_contexts(c, t, "root", "[]") and nx_options(o, c, path) and
            nx_option_priority(o, priority) and nx_option_metadata(o, "isDefined", "true")
          select name, path, priority''')
        self.assertEqual(rows, [["literal.[name].with.dots", '["demo","answer"]', expected]])

    def test_explicit_target_file_uses_same_installed_path(self):
        self.fixture()
        explicit = self.root / ".nixql/explicit.nix"
        (self.root / ".nixql/targets.nix").rename(explicit)
        database, _ = self.create(targets=explicit)
        self.assert_metadata(database, "100")

    def test_query_test_hook_extracts_syntax_and_module_metadata(self):
        self.fixture()
        (self.root / "qlpack.yml").write_text('name: nix-agentic-tools/p2a-qltest\nversion: 0.0.0\nextractor: nix\ndependencies:\n  nix-agentic-tools/nix-all: "*"\n')
        (self.root / "Installed.ql").write_text('''import nix.internal.RawBridge
          select count(@nx_run r | nx_runs(r, _, _, _, _, _) | r),
            count(@nx_definition d | nx_definitions(d, _, _, _) | d),
            count(@nx_option o | nx_options(o, _, _) | o),
            count(@nx_request q | nx_request_results(q, "complete", _, _) | q)
        ''')
        (self.root / "Installed.expected").write_text("| 1 | 1 | 3 | 3 |\n")
        self.run_codeql("test", "run", self.root,
                        env=self.env | {"CODEQL_EXTRACTOR_NIX_OPTION_INPUTS": json.dumps(self.inputs)})

    def test_missing_throwing_invalid_and_network_discovery_are_not_empty_success(self):
        for name, source in (("missing", None), ("throw", '{inputs,source}: throw "P2a discovery sentinel"'), ("invalid", "{inputs,source}: { manifest = {}; bindings = {}; }"), ("network", '{inputs,source}: builtins.fetchTarball "https://example.invalid/p2a-forbidden.tar.gz"')):
            with self.subTest(name=name):
                target_dir = self.root / ".nixql"
                target_dir.mkdir(exist_ok=True)
                target = target_dir / "targets.nix"
                if target.exists():
                    target.unlink()
                if source is not None:
                    target.write_text(source)
                (self.root / "literal.nix").write_text("41")
                database, result = self.create(name, success=False)
                self.assertNotEqual(result.returncode, 0, "discovery must fail closed")
                traps = list(database.rglob("*.trap"))
                traps += list(database.rglob("*.trap.gz"))
                import gzip
                text = "\n".join((gzip.open(path, "rt") if path.suffix == ".gz" else path.open()).read() for path in traps)
                self.assertIn("nx_phases(", text)
                self.assertIn('"failed"', text)
                self.assertIn("nx_diagnostics(", text)
                self.assertNotIn("nx_option_priority(", text)

    def test_changed_pinned_input_is_refused(self):
        self.fixture()
        dependency = self.scratch / "dependency"
        dependency.mkdir()
        (dependency / "value.nix").write_text("17")
        hashed = subprocess.run([self.nix, "--extra-experimental-features", "nix-command", "hash", "path", str(dependency)], capture_output=True, text=True, check=True).stdout.strip()
        (dependency / "value.nix").write_text("23")
        inputs = self.inputs | {"changed": {"path": str(dependency), "narHash": hashed}}
        _, result = self.create(inputs=inputs, success=False)
        self.assertNotEqual(result.returncode, 0, "stale input pin must refuse extraction")


if __name__ == "__main__":
    unittest.main()

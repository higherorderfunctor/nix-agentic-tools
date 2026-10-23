"""M3 expectations from design-final section 7, frozen before implementation."""

from copy import deepcopy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


OWNER = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BuiltinModelsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.nix = os.environ["CODEQL_NIX_TEST_NIX"]
        cls.source = Path(os.environ["CODEQL_NIX_TEST_BUILTIN_SOURCE"])
        cls.asset = Path(os.environ["CODEQL_NIX_TEST_MODEL"])
        cls.model = json.loads(cls.asset.read_text())

    def nix_run(self, *args):
        # Independent policy oracle: do not import the generator's policy.
        env = os.environ | {"NIX_CONFIG": "", "NIX_CONF_DIR": "/m3/no-config", "NIX_USER_CONF_FILES": ""}
        result = subprocess.run([self.nix, "--store", "dummy://", "--option", "experimental-features", "flakes nix-command", "--option", "pure-eval", "true", "--option", "plugin-files", "", *args], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def nix_json(self, expression):
        return json.loads(self.nix_run("eval", "--json", "--expr", expression))

    def exports(self):
        result = {}
        for record in self.model["builtins"]:
            for export in record["exports"]:
                key = (export["namespace"], export["name"])
                self.assertNotIn(key, result, "each export has exactly one identity")
                result[key] = record
        return result

    def test_actual_runtime_inventory_and_distinct_alias_identities(self):
        exports = self.exports()
        self.assertEqual(sorted(name for namespace, name in exports if namespace == "builtins"), self.nix_json("builtins.attrNames builtins"))
        ids = [record["identity"] for record in self.model["builtins"]]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertTrue(all(ids))
        for name in ("import", "map", "toString"):
            self.assertEqual(exports[("", name)]["identity"], exports[("builtins", name)]["identity"])
        self.assertEqual(len({exports[("builtins", name)]["identity"] for name in ("import", "map", "toString")}), 3)
        self.assertNotIn(("builtins", "m3DefinitelyNotABuiltin"), exports)
        self.assertIn(("builtins", "fetchTree"), exports)
        for name in ("currentSystem", "currentTime"):
            self.assertNotIn(("builtins", name), exports)
            self.assertNotIn(("", "__" + name), exports)
        self.assertEqual(self.nix_json("[ (builtins ? fetchTree) (builtins ? currentSystem) (builtins ? currentTime) ]"), [True, False, False])
        print("M3 pure policy oracle: fetchTree present; currentSystem/currentTime absent", flush=True)

    def test_source_backed_map_parameters_documentation_and_opaque_behavior(self):
        record = self.exports()[("builtins", "map")]
        self.assertEqual(record["parameters"], ["f", "list"])
        self.assertEqual(record["confidence"], "source")
        evidence = record["evidence"]
        path = Path(evidence["path"])
        self.assertFalse(path.is_absolute())
        self.assertNotIn("..", path.parts)
        lines = (self.source / path).read_text().splitlines()
        self.assertGreaterEqual(evidence["startLine"], 1)
        self.assertGreaterEqual(evidence["endLine"], evidence["startLine"])
        span = "\n".join(lines[evidence["startLine"] - 1:evidence["endLine"]])
        self.assertIn('"map"', span)
        self.assertIn('"f"', span)
        self.assertIn('"list"', span)
        self.assertTrue(record["documentation"].strip())
        self.assertIn(record["documentation"].strip(), span)
        for item in self.model["builtins"]:
            self.assertEqual(item["behavior"], "opaque")
            if item["evidence"] is None:
                self.assertEqual(item["confidence"], "unknown")
                self.assertIsNone(item["documentation"])
                self.assertIsNone(item["parameters"])

    def test_runtime_source_and_model_content_fingerprints(self):
        version = self.nix_run("--version").strip()
        source_hash = self.nix_run("hash", "path", str(self.source)).strip()
        self.assertEqual(self.model["runtime"], {"identity": version, "sourceHash": source_hash})
        self.assertTrue(self.model["generatorVersion"])
        self.assertTrue(self.model["policy"])
        payload = deepcopy(self.model)
        actual = payload.pop("modelVersion")
        expected = "sha256:" + hashlib.sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.assertEqual(actual, expected)

    def test_regeneration_is_deterministic_and_installed_bytes_match_committed(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("CODEQL_NIX_TEST_SCRATCH")) as temporary:
            root = Path(temporary)
            settings = ("experimental-features =\npure-eval = false\nplugin-files = /m3/no-such-plugin.so\n", "experimental-features = flakes nix-command\npure-eval = true\nplugin-files =\n")
            for name, config in zip(("first", "second"), settings):
                ambient = root / (name + "-config")
                ambient.mkdir()
                (ambient / "nix.conf").write_text(config)
                env = os.environ | {"NIX_CONFIG": config, "NIX_CONF_DIR": str(ambient), "NIX_USER_CONF_FILES": str(ambient / "nix.conf")}
                subprocess.run([os.sys.executable, str(OWNER / "models/builtins/generate.py"), "--nix", self.nix, "--source", str(self.source), "--output", str(root / name)], env=env, check=True)
                subprocess.run([os.environ["CODEQL_NIX_TEST_FORMATTER"], "--config-file", os.environ["CODEQL_NIX_TEST_FORMATTER_CONFIG"], "--tree-root", ".", "--walk", "filesystem", "--no-cache", "--on-unmatched=fatal", "builtins.json"], cwd=root / name, check=True)
            for name in ("builtins.json", "builtins.qll"):
                expected = (OWNER / "generated/models" / name).read_bytes()
                self.assertEqual((root / "first" / name).read_bytes(), expected)
                self.assertEqual((root / "second" / name).read_bytes(), expected)
            self.assertEqual(self.asset.read_bytes(), (root / "first/builtins.json").read_bytes())
            print("M3 opposing ambient feature/purity/plugin configs: final model bytes identical", flush=True)

    def test_model_fingerprint_activates_existing_f2_and_run_identity(self):
        examples = load("m3_examples", OWNER / "checks/fixtures/protocol/examples.py")
        import jsonschema
        manifest = deepcopy(examples.MANIFEST)
        manifest["targets"]["host.workstation"]["fingerprint"]["modelVersion"] = self.model["modelVersion"]
        jsonschema.Draft202012Validator(json.loads((OWNER / "schema/target-manifest.json").read_text())).validate(manifest)
        abi = load("m3_abi", OWNER / "schema/abi.py")
        coordinator = load("m3_coordinator", OWNER / "src/extract.py")
        with tempfile.TemporaryDirectory() as temporary:
            pins = Path(temporary) / "pins.json"
            rows = []
            for model in (self.model["modelVersion"], "sha256:" + "0" * 64):
                pins.write_text(json.dumps({"grammar": "fixture-grammar", "model": model}))
                row = coordinator.RunIdentity.syntax(abi, OWNER / "src/extract.py", OWNER / "generated/nix.dbscheme", pins, {"roots": []}).row
                self.assertEqual(row[1][4], model)
                rows.append(row)
            self.assertNotEqual(rows[0][1][0], rows[1][1][0], "different model facts cannot share a run identity")
            identity = coordinator.RunIdentity(rows[0])
            fingerprint = manifest["targets"]["host.workstation"]["fingerprint"]
            fingerprint["sourceSnapshotHash"] = identity.row[1][-1]
            for requested in (self.model["modelVersion"], "not-requested"):
                with self.subTest(requested=requested):
                    fingerprint["modelVersion"] = requested
                    identity.check_targets(abi, manifest)
            fingerprint["modelVersion"] = "sha256:" + "0" * 64
            with self.assertRaisesRegex(ValueError, "^unsupported-model$"):
                identity.check_targets(abi, manifest)
            fingerprint["modelVersion"] = self.model["modelVersion"]
            fingerprint["sourceSnapshotHash"] = "sha256:" + "0" * 64
            with self.assertRaisesRegex(ValueError, "^mixed-source-snapshot$"):
                identity.check_targets(abi, manifest)
            print("M3 target admission: matching/legacy accepted; mismatching model and stale snapshot refused", flush=True)

    def test_named_ql_rows_and_json_consumer_agree_on_installed_model(self):
        installed = load("m3_installed", OWNER / "checks/fixtures/installed/test_installed.py")
        installed.InstalledTests.setUpClass()
        harness = installed.InstalledTests()
        harness.setUp()
        self.addCleanup(harness.doCleanups)
        harness.fixture()
        target = harness.root / ".nixql/targets.nix"
        target.write_text(target.read_text().replace('"not-requested"', json.dumps(self.model["modelVersion"])))
        shutil.copy(OWNER / "ql/test/qlpack.yml", harness.root / "qlpack.yml")
        for path in (OWNER / "ql/test/builtin-models").iterdir():
            shutil.copy(path, harness.root / path.name)
        result = harness.run_codeql("test", "run", harness.root, env=harness.env | {"CODEQL_EXTRACTOR_NIX_OPTION_INPUTS": json.dumps(harness.inputs)})
        print(result.stdout[-6000:] + result.stderr[-6000:], flush=True)
        database, _ = harness.create()
        rows = harness.query(database, "ModelFingerprint", 'import nix.internal.BuiltinModels\nfrom string version where modelFingerprint(version) select version')
        self.assertEqual(rows, [[self.model["modelVersion"]]])
        alternate = harness.scratch / "incompatible-library"
        shutil.copytree(harness.library, alternate)
        generated = alternate / "nix/internal/generated/Builtins.qll"
        model_text = generated.read_text()
        self.assertIn(self.model["modelVersion"], model_text)
        generated.chmod(0o644)
        generated.write_text(model_text.replace(self.model["modelVersion"], "sha256:" + "0" * 64))
        query = harness.scratch / "queries/IncompatibleModel.ql"
        query.write_text('import nix.internal.BuiltinModels\nselect count(string ns, string name, string identity | builtinIdentity(ns, name, identity) | identity)\n')
        bqrs = harness.scratch / "incompatible.bqrs"
        harness.command = os.environ["CODEQL_NIX_TEST_BARE_COMMAND"]
        harness.run_codeql("query", "run", query, "--database=" + str(database), "--output=" + str(bqrs), "--search-path=" + str(alternate))
        result = harness.run_codeql("bqrs", "decode", bqrs, "--format=csv", "--no-titles")
        self.assertEqual(result.stdout.strip(), "0", "a mismatched model must expose zero builtin identities")
        print("M3 mismatched model fingerprint: zero builtin identities", flush=True)
        bqrs.unlink()

    def test_real_nix_global_aliases_competing_sentinels_and_safe_rename(self):
        result = self.nix_json('''[
          (builtins.typeOf import) (builtins.typeOf builtins.import)
          (let import = _: 31; in import null)
          (let renamed = _: 31; in renamed null)
          (with { import = 99; }; builtins.isFunction import)
          (map (x: x + 1) [ 1 2 ])
        ]''')
        self.assertEqual(result, ["lambda", "lambda", 31, 31, True, [2, 3]])


if __name__ == "__main__":
    unittest.main()

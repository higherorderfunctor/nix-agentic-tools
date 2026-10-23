"""N2 binding maps are authored from the contract, never QL output."""

import csv
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

OWNER = Path(__file__).resolve().parents[3]
FIXTURE = OWNER / "ql/test/implicit-scope"
VALUES = [11, 13, 11, 17, 17, 23, 29, 31, 37, 41, 43, 47, 53, 59, None, 61, 67, 79, 83, 89, 151, 163, 173, 181, 193, 211]


class ImplicitScopeTests(unittest.TestCase):
    def evaluate(self, expression, expected=None, error=None):
        result = subprocess.run([os.environ.get("CODEQL_NIX_TEST_NIX", "nix"),
            "--extra-experimental-features", "nix-command", "eval", "--json", "--expr", expression],
            capture_output=True, text=True, timeout=30)
        if error:
            self.assertNotEqual(result.returncode, 0)
            self.assertRegex(result.stderr, error)
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), expected)

    def test_independent_nix_values_and_unknown_environment_witnesses(self):
        expressions = (FIXTURE / "scope.nix.in").read_text().splitlines()[1:-1]
        self.assertEqual(len(expressions), len(VALUES))
        for line, (source, expected) in enumerate(zip(expressions, VALUES), 2):
            with self.subTest(line=line):
                self.evaluate(source, expected, "undefined variable" if expected is None else None)
        unknown = expressions[12]
        self.evaluate(unknown.replace("{})", "{ x = 113; })"), 113)
        self.evaluate(expressions[13].replace("{})", "{ x = 127; })"), 59)
        self.evaluate(expressions[15].replace("{})", "{ x = 131; })"), 61)
        print("N2 Nix oracle: 26 inheritance/with rules; inherited known names, excluded own frame including a computed parent, and uncertainty from an outer frame that is not excluded; unknown membership capture, dynamic keys, inner-known and lexical precedence passed", flush=True)

    def test_negative_name_controls_and_binding_rename(self):
        expressions = (FIXTURE / "negative.nix.in").read_text().splitlines()[1:-1]
        for source, error in zip(expressions, ["undefined variable", "undefined variable", "already defined|duplicate", "undefined variable"]):
            self.evaluate(source, error=error)
        original = '(let x = 137; in (rec { inherit x; y = x; }).y)'
        self.evaluate(original, 137)
        self.evaluate(original.replace("let x", "let renamed").replace("inherit x", "x = renamed"), 137)
        self.evaluate(original.replace("inherit x", "x = 139"), 139)
        print("N2 Nix oracle: four negative controls; safe outer rename and redirected inheritance sentinel passed", flush=True)

    def test_compatible_builtin_outer_frame_through_installed_extractor(self):
        spec = importlib.util.spec_from_file_location("n2_installed", OWNER / "checks/fixtures/installed/test_installed.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.InstalledTests.setUpClass()
        harness = module.InstalledTests()
        harness.setUp()
        self.addCleanup(harness.doCleanups)
        harness.fixture()
        shutil.copy(OWNER / "ql/test/qlpack.yml", harness.root / "qlpack.yml")
        for path in (OWNER / "ql/test/implicit-builtins").iterdir():
            shutil.copy(path, harness.root / path.name.removesuffix(".in"))
        result = harness.run_codeql("test", "run", harness.root, env=harness.env | {"CODEQL_EXTRACTOR_NIX_OPTION_INPUTS": json.dumps(harness.inputs)})
        print(result.stdout[-4000:] + result.stderr[-4000:], flush=True)
        self.evaluate('[ (with { import = 97; }; builtins.isFunction import) (with { builtins = 101; }; builtins.isAttrs builtins) (let import = 103; in with { import = 107; }; import) (let builtins = 109; in builtins) ((s: with s; builtins.isFunction import) { import = 149; }) ]', [True, True, 103, 109, True])
        print("N2 installed builtin NameBindings: compatible import/builtins identities, with precedence and local shadowing passed", flush=True)
        database, _ = harness.create()
        alternate = harness.scratch / "incompatible-library"
        shutil.copytree(harness.library, alternate)
        generated = alternate / "nix/internal/generated/Builtins.qll"
        fingerprint = json.loads((harness.library / "models/builtins.json").read_text())["modelVersion"]
        generated.chmod(0o644)
        generated.write_text(generated.read_text().replace(fingerprint, "sha256:" + "0" * 64))
        harness.command = os.environ["CODEQL_NIX_TEST_BARE_COMMAND"]
        output = harness.scratch / "incompatible.bqrs"
        harness.run_codeql("query", "run", harness.root / "NameBindings.ql", "--database=" + str(database), "--output=" + str(output), "--search-path=" + str(alternate))
        result = harness.run_codeql("bqrs", "decode", output, "--format=csv", "--no-titles")
        expected = [row.strip()[2:-2].split(" | ") for row in (OWNER / "ql/test/implicit-builtins/Unavailable.expected").read_text().splitlines()]
        self.assertCountEqual(list(csv.reader(io.StringIO(result.stdout))), expected)
        output.unlink()
        print("N2 incompatible builtin model: unavailable globals cannot fall through to with; locals still resolve", flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""Real Nix dynamic suffix values; binding expected rows separately preserve uncertainty."""
import json
import os
from pathlib import Path
import subprocess
import unittest

FIXTURE = Path(__file__).resolve().parents[3] / "ql/test/lexical-dynamic"
VALUES = [2, {"inner": 3, "x": "inner"}, 2, 2, 2, 3, 4, 4, 99, 99, 99, 4,
          99, 2, 3, 2, 3, 4, 4, 99, 4, 2, 3]

SIBLING_VALUES = [7, 7, 7, 7, 7, 7, 7, 7, 99, None, 99, None, 99, None, 99, None, 99, 99, 2, 3, 2, 7, 4, 4, 7, 3, 3, 3, 3, 3, 3, 3, 99, 3, 3, 3]


class DynamicScopeTests(unittest.TestCase):
    def evaluate(self, expression):
        return subprocess.run([os.environ.get("CODEQL_NIX_TEST_NIX", "nix"),
            "--extra-experimental-features", "nix-command", "eval", "--json", "--expr", expression],
            capture_output=True, text=True, timeout=30)

    def test_structural_suffix_matrix_and_capture_controls(self):
        result = self.evaluate((FIXTURE / "valid.nix.in").read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), VALUES)
        print("N1 dynamic oracle: 23 suffix/order/nearest-frame/rename/unknown-prefix witnesses passed", flush=True)

    def test_unknown_sibling_names_and_preserved_frames(self):
        fixture = FIXTURE.parent / "lexical-siblings/siblings.nix.in"
        expressions = fixture.read_text().splitlines()[1:-1]
        self.assertEqual(len(expressions), len(SIBLING_VALUES))
        for line, (expression, expected) in enumerate(zip(expressions, SIBLING_VALUES), 2):
            result = self.evaluate(expression)
            if expected is None:
                self.assertNotEqual(result.returncode, 0, f"line {line}")
                self.assertIn("undefined variable", result.stderr, f"line {line}")
            else:
                self.assertEqual(result.returncode, 0, f"line {line}: {result.stderr}")
                self.assertEqual(json.loads(result.stdout), expected, f"line {line}")
        print("N1 J1 sibling oracle: 36 scalar/function/nested/key/order/preserved-frame/may-retention witnesses passed", flush=True)

    def test_unknown_prefix_values_and_nonbinding_suffix(self):
        expressions = (FIXTURE / "negative.nix.in").read_text().splitlines()[1:-1]
        for index in (0, 2):
            result = self.evaluate(expressions[index])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {"d": 7})
        result = self.evaluate(expressions[1])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("undefined variable", result.stderr)
        result = self.evaluate(expressions[3])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("infinite recursion", result.stderr)
        print("N1 dynamic oracle: two unavailable-name values, one suffix-name refusal and one own-RHS capture recursion passed", flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)

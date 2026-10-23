"""Independent Nix oracle for statically merged bindings and source-order rec."""
import json
import os
from pathlib import Path
import subprocess
import unittest

FIXTURE = Path(__file__).resolve().parents[3] / "ql/test/lexical-merged"


class MergedScopeTests(unittest.TestCase):
    def evaluate(self, expression):
        return subprocess.run([os.environ.get("CODEQL_NIX_TEST_NIX", "nix"),
            "--extra-experimental-features", "nix-command", "eval", "--json", "--expr", expression],
            capture_output=True, text=True, timeout=30)

    def test_disjoint_static_merges_and_source_order(self):
        result = self.evaluate((FIXTURE / "valid.nix.in").read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout),
            [[1, 2], [3, 4], [5, 6], [7, 8], [9, 10], 2, 99, 99, 2,
             99, 99, 2, {"b": 1, "c": 2}, {"b": {"c": 1, "d": 2}}])
        print("N1 merge oracle: seven disjoint merges, five scope witnesses and two rename controls passed", flush=True)

    def test_overlapping_leaves_are_invalid(self):
        for expression in (FIXTURE / "overlap.nix.in").read_text().splitlines()[1:-1]:
            with self.subTest(expression=expression):
                result = self.evaluate(expression)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("already defined", result.stderr)
        result = self.evaluate("(" + (FIXTURE / "inventory.nix.in").read_text() + ") 101")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), 101)
        print("N1 merge oracle: six overlapping-leaf refusals and inventory value passed", flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)

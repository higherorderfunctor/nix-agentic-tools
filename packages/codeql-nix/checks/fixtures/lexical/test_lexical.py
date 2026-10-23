# cspell:ignore keepends
"""N1 binding expected rows are fixed independently of QL implementation output."""

import json
import os
from pathlib import Path
import subprocess
import unittest

OWNER = Path(__file__).resolve().parents[3]
FIXTURE = OWNER / "ql/test/lexical"
VALUES = [11, 13, 17, 19, 29, 68, 41, [{}, 43], 47, 59, 61, 67, 71, 73, 79, 89]


class LexicalOracleTests(unittest.TestCase):
    def evaluate(self, source, success=True):
        result = subprocess.run([os.environ.get("CODEQL_NIX_TEST_NIX", "nix"),
            "--extra-experimental-features", "nix-command", "eval", "--json", "--expr", source],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stderr[-4000:])
        return json.loads(result.stdout) if success else result.stderr

    def rows(self):
        return [line.strip()[2:-2].split(" | ") for line in
            (FIXTURE / "NameBindings.expected").read_text().splitlines()]

    def test_closed_values_and_independent_binding_alpha_renames(self):
        source = (FIXTURE / "positive.nix.in").read_text()
        self.assertEqual(self.evaluate(source), VALUES)
        lines = source.splitlines(keepends=True)
        groups = {}
        for file, line, column, name, status, binder_line, binder_column in self.rows():
            if file != "positive.nix" or status != "resolved":
                continue
            key = (int(binder_line), int(binder_column), name)
            groups.setdefault(key, set()).update([(int(line), int(column)), key[:2]])
        checked = 0
        for (binder_line, binder_column, name), positions in groups.items():
            # Renaming a supplied formal key changes the function's interface;
            # the independent value witness still covers this pattern.
            if binder_line == 13:
                continue
            changed = list(lines)
            for line, column in sorted(positions, reverse=True):
                text = changed[line - 1]
                self.assertEqual(text[column - 1:column - 1 + len(name)], name)
                changed[line - 1] = text[:column - 1] + "n1Renamed" + text[column - 1 + len(name):]
            with self.subTest(binder=(binder_line, binder_column, name)):
                self.assertEqual(self.evaluate("".join(changed)), VALUES)
            checked += 1
        self.assertGreaterEqual(checked, 20)
        # A use redirected to another actual binder must change the witness.
        mutant = source.replace("y = 83; in x", "y = 83; in y")
        expected = list(VALUES)
        expected[14] = 83
        self.assertEqual(self.evaluate(mutant), expected)
        print(f"N1 oracle: closed values, {checked} binding alpha-renames and capture mutant passed", flush=True)

    def test_rejected_names_and_invalid_duplicates_are_real_nix_controls(self):
        negative = (FIXTURE / "negative.nix.in").read_text().splitlines()
        for line in (2, 3, 4, 5):
            error = self.evaluate(negative[line - 1], success=False)
            self.assertIn("undefined variable", error)
        error = self.evaluate(negative[7], success=False)
        self.assertIn("infinite recursion", error)
        duplicates = (FIXTURE / "duplicates.nix.in").read_text().splitlines()[1:-1]
        for source in duplicates:
            with self.subTest(source=source):
                error = self.evaluate(source, success=False)
                self.assertRegex(error, "already defined|duplicate")
        print("N1 oracle: four unavailable-name controls, recursive self binding and four duplicate refusals passed", flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""F3 black-box acceptance for explicitly selected unittest files."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).resolve().parents[2] / "run-domain-tests.py"


class DomainEntrypointTests(unittest.TestCase):
    def run_files(self, *bodies):
        with tempfile.TemporaryDirectory() as directory:
            # Unselected siblings must never be collected by discovery.
            (Path(directory) / "test_unselected.py").write_text("raise AssertionError('not selected')\n")
            paths = []
            for index, body in enumerate(bodies):
                path = Path(directory) / f"test_{index}.py"
                path.write_text(body)
                paths.append(str(path))
            return subprocess.run(
                [sys.executable, str(RUNNER), *paths],
                capture_output=True, text=True, timeout=30,
            )

    def accepted(self, *bodies):
        result = self.run_files(*bodies)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def rejected(self, *bodies):
        result = self.run_files(*bodies)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_explicit_files_and_sibling_imports(self):
        # A companion module is not a discovered test; it is imported explicitly.
        self.accepted(
            "import unittest\nclass Cases(unittest.TestCase):\n"
            " def test_value(self):\n  from test_1 import VALUE\n  self.assertEqual(VALUE, 41)\n",
            "import unittest\nVALUE = 41\nclass Other(unittest.TestCase):\n"
            " def test_value(self): self.assertEqual(VALUE, 41)\n",
        )

    def test_no_paths_or_empty_file_cannot_pass(self):
        self.rejected()
        self.rejected("")

    def test_empty_second_file_cannot_hide_behind_passing_first(self):
        self.rejected(
            "import unittest\nclass Cases(unittest.TestCase):\n"
            " def test_value(self): self.assertEqual(2 + 3, 5)\n",
            "",
        )

    def test_all_skipped_cannot_pass(self):
        self.rejected(
            "import unittest\nclass Cases(unittest.TestCase):\n"
            " @unittest.skip('unavailable')\n def test_value(self): pass\n"
        )

    def test_failure_error_and_import_failure_propagate(self):
        for statement in ("self.fail('oracle mismatch')", "raise RuntimeError('broken')"):
            with self.subTest(statement=statement):
                self.rejected(
                    "import unittest\nclass Cases(unittest.TestCase):\n"
                    f" def test_value(self): {statement}\n"
                )
        self.rejected("raise ImportError('missing dependency')\n")

    def test_successful_exit_during_import_cannot_pass(self):
        self.rejected("import sys\nsys.exit(0)\n")

    def test_missing_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, str(RUNNER), str(Path(directory) / "missing.py")],
                capture_output=True, text=True, timeout=30,
            )
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)

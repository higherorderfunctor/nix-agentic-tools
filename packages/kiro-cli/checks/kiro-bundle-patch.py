"""Check exact matching, selected byte preservation, and strict build refusal."""

import importlib.util
import itertools
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PATCHER = sys.argv.pop(1)
spec = importlib.util.spec_from_file_location("patcher", PATCHER)
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
BUNDLE = (b"var steering='Before\\n\\n"
          + patcher.WORKTREE_PARAGRAPH + b"After';\nvar workflow='"
          + patcher.FILE_CHECK_PARAGRAPH + b"';\n")


class PatchTests(unittest.TestCase):
    def test_selected_patches_preserve_other_bytes_and_execute(self):
        subsets = [names for r in range(len(patcher.FIXED) + 1) for names in itertools.combinations(patcher.FIXED, r)]
        for names in subsets:
            strip = "stripVendorWorktreeSteering" in names
            relative = "relativeFileCheckPaths" in names
            with self.subTest(names=names):
                result, errors = patcher.patch(BUNDLE, patcher.replacements(names))
                self.assertEqual(errors, [])
                expected = BUNDLE
                for name in names:
                    expected = expected.replace(*patcher.FIXED[name])
                self.assertEqual(result, expected)
                output = subprocess.check_output([
                    "node", "-e", result.decode() + "console.log(steering);console.log(workflow);"
                ])
                self.assertIn(b"After", output)
                self.assertEqual(b"Do not create the worktree yourself" in output, not strip)
                # The stop-condition file is written and checked at one path.
                self.assertEqual(b"at the same relative path" in output, relative)
                self.assertEqual(b"Every path is absolute**" in output, not relative)

    def test_drift_refuses_the_entire_selected_patch(self):
        selected = patcher.replacements(patcher.FIXED)
        for name, source, _ in selected:
            for data, count in ((BUNDLE.replace(source, b"changed"), 0), (BUNDLE + source, 2)):
                with self.subTest(name=name, count=count):
                    result, errors = patcher.patch(data, selected)
                    self.assertEqual(errors, [f"{name}: expected exact source text once, found {count}; bundle drift"])
                    self.assertIsNone(result)
        result, errors = patcher.patch(b"all changed", selected)
        self.assertIsNone(result)
        self.assertEqual(len(errors), len(selected))

    def test_check_fails_closed_for_each_source(self):
        selected = patcher.replacements(patcher.FIXED)
        for name, source, _ in selected:
            for count in (0, 1, 2):
                with self.subTest(name=name, count=count), tempfile.TemporaryDirectory() as tmp:
                    path = Path(tmp) / "bundle.js"
                    data = BUNDLE.replace(source, b"changed") if count == 0 else BUNDLE + source if count == 2 else BUNDLE
                    path.write_bytes(data)
                    result = subprocess.run([sys.executable, PATCHER, str(path), "--check"], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0 if count == 1 else 1, result.stderr)
                    if count != 1:
                        self.assertIn(f"FAIL: kiro-bundle-patch: {name}: expected exact source text once, found {count}", result.stderr)

    def test_application_fails_without_writing_partial_output(self):
        selected = patcher.replacements(patcher.FIXED)
        for name, source, _ in selected:
            for count in (0, 2):
                with self.subTest(name=name, count=count), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    src, dst = (root / n for n in ("in.js", "out.js"))
                    src.write_bytes(BUNDLE.replace(source, b"changed") if count == 0 else BUNDLE + source)
                    dst.write_bytes(b"untouched")
                    args = [sys.executable, PATCHER, str(src), str(dst)]
                    for key in patcher.FIXED:
                        args += ["--replace", key]
                    result = subprocess.run(args, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn(f"{name}: expected exact source text once, found {count}", result.stderr)
                    self.assertEqual(dst.read_bytes(), b"untouched")


if __name__ == "__main__":
    unittest.main()

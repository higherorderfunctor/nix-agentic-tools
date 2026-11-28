"""Check exact matching, selected byte preservation, and strict build refusal."""

import importlib.util
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
          + b" ".join(source for source, _ in patcher.FIXED["relativeFileCheckPaths"]) + b"';\n")


SELECTIONS = (
    ("relative selection leaves vendor worktree guidance alone", ("relativeFileCheckPaths",), True, False),
    ("strip selection leaves vendor file-check guidance alone", ("stripVendorWorktreeSteering",), False, True),
    ("both selections compose rather than the last one winning",
     ("relativeFileCheckPaths", "stripVendorWorktreeSteering"), True, True),
)


class PatchTests(unittest.TestCase):
    def test_selected_patches_execute_with_the_requested_guidance(self):
        for regression, names, relative, strip in SELECTIONS:
            with self.subTest(regression=regression):
                result, errors = patcher.patch(BUNDLE, patcher.replacements(names))
                self.assertEqual(errors, [])
                output = subprocess.check_output([
                    "node", "-e", result.decode() + "console.log(steering);console.log(workflow);"
                ])
                self.assertTrue(output.startswith(b"Before\n\n"))
                self.assertIn(b"After\n", output)
                self.assertEqual(b"Do not create the worktree yourself" in output, not strip)
                # The written and checked paths must agree at all four example sites.
                self.assertEqual(b"at the same relative path" in output, relative)
                self.assertEqual(b"Every path is absolute**" in output, not relative)
                self.assertEqual(b"names the gate file's absolute path" in output, not relative)
                self.assertEqual(b"names the gate file's workspace-relative path" in output, relative)
                self.assertEqual(output.count(b"/repo/.agents/tasks/fix-throttle/review.json"), 0 if relative else 4)
                if relative:
                    self.assertEqual(output.count(b".agents/tasks/fix-throttle/review.json"), 4)

    def test_substitution_preserves_unselected_bytes_exactly(self):
        # Substituting one anchor must not normalize line endings or touch a sibling.
        result, errors = patcher.patch(b"before\r\nanchor\x00sibling", [("chosen", b"anchor", b"new")])
        self.assertEqual(errors, [])
        self.assertEqual(result, b"before\r\nnew\x00sibling")

    def test_reports_all_failed_anchors(self):
        selected = [("absent", b"missing", b"new"), ("repeated", b"twice", b"new")]
        _, errors = patcher.patch(b"twice twice", selected)
        self.assertEqual(errors, [
            "absent: expected exact source text once, found 0; bundle drift: b'missing'",
            "repeated: expected exact source text once, found 2; bundle drift: b'twice'",
        ])

    def test_cli_refuses_each_missing_or_repeated_anchor(self):
        selected = patcher.replacements(patcher.FIXED)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src, dst = root / "in.js", root / "out.js"
            command = [sys.executable, PATCHER, str(src)]
            apply = [str(dst), "--replace", "relativeFileCheckPaths", "--replace", "stripVendorWorktreeSteering"]
            src.write_bytes(BUNDLE)
            # The vendor check covers acceptance; this input is writable.
            subprocess.run(command + ["--check"], capture_output=True)
            self.assertEqual(src.read_bytes(), BUNDLE)
            for name, source, _ in selected:
                for regression, data, count in (
                    ("missing anchor cannot be silently skipped", BUNDLE.replace(source, b"changed"), 0),
                    ("repeated anchor cannot be resolved by patching the first", BUNDLE + source, 2),
                ):
                    src.write_bytes(data)
                    diagnostic = f"FAIL: kiro-bundle-patch: {name}: expected exact source text once, found {count}; bundle drift: {source[:80]!r}"
                    for mode, arguments in (("check", ["--check"]), ("apply without partial write", apply)):
                        with self.subTest(mode=mode, regression=regression, name=name, source=source[:80]):
                            if arguments == apply:
                                dst.write_bytes(b"untouched")
                            result = subprocess.run(command + arguments, capture_output=True, text=True)
                            self.assertEqual(result.returncode, 1, result.stderr)
                            self.assertIn(diagnostic, result.stderr.splitlines())
                            if arguments == apply:
                                self.assertEqual(dst.read_bytes(), b"untouched")
                            self.assertEqual(src.read_bytes(), data)


if __name__ == "__main__":
    unittest.main()

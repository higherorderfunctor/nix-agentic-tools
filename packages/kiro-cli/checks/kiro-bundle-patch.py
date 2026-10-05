"""Check exact matching, byte preservation, and fail-open launch warnings."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("patcher", sys.argv.pop(1))
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
LAUNCHERS = json.loads(Path(sys.argv.pop(1)).read_text())
IDENTITY = b"Custom identity. Another sentence!"
BUNDLE = (b"function identity(){return `" + patcher.IDENTITY_SENTENCE
          + b" Terminal guidance.`}\nvar steering='Before\\n\\n"
          + patcher.WORKTREE_PARAGRAPH + b"After';\n")


class PatchTests(unittest.TestCase):
    def test_selected_patches_preserve_other_bytes_and_execute(self):
        for identity, strip in ((IDENTITY, True), (IDENTITY, False), (None, True)):
            with self.subTest(identity=identity, strip=strip):
                result = patcher.patch(BUNDLE, patcher.replacements(identity, strip))
                expected = BUNDLE
                if identity is not None:
                    expected = expected.replace(patcher.IDENTITY_SENTENCE, identity)
                if strip:
                    expected = expected.replace(patcher.WORKTREE_PARAGRAPH, b"")
                self.assertEqual(result, expected)
                output = subprocess.check_output([
                    "node", "-e", result.decode() + "console.log(identity());console.log(steering);"
                ])
                self.assertIn((identity or patcher.IDENTITY_SENTENCE) + b" Terminal guidance.", output)
                self.assertIn(b"After", output)
                self.assertEqual(b"workflow owns the worktree setup" in output, not strip)

    def test_default_selects_no_replacement(self):
        self.assertEqual(patcher.replacements(), [])

    def test_missing_and_duplicate_sources_fail_for_each_replacement(self):
        for name, source, _ in patcher.replacements(IDENTITY, True):
            for data, count in ((BUNDLE.replace(source, b"changed"), 0), (BUNDLE + source, 2)):
                with self.subTest(name=name, count=count):
                    with self.assertRaisesRegex(ValueError, f"{name}: .*found {count}"):
                        patcher.patch(data, patcher.replacements(IDENTITY, True))
        with self.assertRaisesRegex(ValueError, "identity:.*worktree:"):
            patcher.patch(b"both changed", patcher.replacements(IDENTITY, True))

    def test_invalid_identity_is_rejected(self):
        for identity in (b"", b"no punctuation", b"Bad `identity`.", b"Bad ${identity}."):
            with self.subTest(identity=identity), self.assertRaisesRegex(ValueError, "identity:"):
                patcher.replacements(identity)

    def test_materializer_and_both_launch_entry_points(self):
        for mode, launchers in LAUNCHERS.items():
            identity = launchers["identity"] and launchers["identity"].encode()
            selected = patcher.replacements(identity, launchers["strip"])
            for name, source, _ in selected:
                for count in (0, 1, 2):
                    with self.subTest(mode=mode, name=name, count=count), tempfile.TemporaryDirectory() as tmp:
                        root = Path(tmp)
                        bundle = root / "data/kas/1.0.0-probe/node_modules/@kiro/agent/dist/server/acp-server.js"
                        bundle.parent.mkdir(parents=True)
                        sibling = root / "data/kas/1.0.0-probe/node_modules/vendor/probe.txt"
                        sibling.parent.mkdir()
                        sibling.write_text("sibling")
                        data = BUNDLE.replace(source, b"changed") if count == 0 else BUNDLE + source if count == 2 else BUNDLE
                        bundle.write_bytes(data)
                        env = os.environ | {"HOME": tmp, "XDG_CACHE_HOME": str(root / "cache"), "KIRO_DATA_DIR": str(root / "data")}
                        env.pop("KIRO_KAS_SERVER_PATH", None)
                        result = subprocess.run([launchers["materializer"]], env=env, capture_output=True, text=True)
                        self.assertEqual(result.returncode, 0 if count == 1 else 1, result.stderr)
                        if count == 1:
                            patched = Path(result.stdout)
                            self.assertEqual(patched.read_bytes(), patcher.patch(data, selected))
                            self.assertEqual((patched.parents[4] / "vendor/probe.txt").read_text(), "sibling")
                            repeat = subprocess.run([launchers["materializer"]], env=env, capture_output=True, text=True)
                            self.assertEqual((repeat.returncode, repeat.stdout, repeat.stderr), (0, result.stdout, ""))
                        else:
                            self.assertIn(f"WARNING: kiro-bundle-patch: {name}:", result.stderr)
                            self.assertEqual(result.stdout, "")
                            self.assertEqual(list(root.rglob(".ready")), [])
                        for binary in ("kiro-cli", "kiro-cli-chat"):
                            launched = subprocess.run([f"{launchers['wrapper']}/bin/{binary}"], env=env, capture_output=True, text=True)
                            self.assertEqual(launched.returncode, 0, launched.stderr)
                            if count == 1:
                                self.assertEqual(launched.stdout, f"launched:{result.stdout}\n")
                            else:
                                self.assertEqual(launched.stdout, "launched:stock\n")
                                self.assertIn(f"WARNING: kiro-bundle-patch: {name}:", launched.stderr)
                        self.assertEqual(bundle.read_bytes(), data)


if __name__ == "__main__":
    unittest.main()

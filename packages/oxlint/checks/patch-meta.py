"""Name-only patch metadata follows resolved versions and covers every peer."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv.pop(1))


def workspace(version):
    return f'''catalog:
  "@napi-rs/cli": {version}
overrides:
  other: 1.0.0
packages:
  - apps/*
'''


def lock(version):
    return f'''---
packageManagerDependencies: {{}}
---
lockfileVersion: '9.0'
overrides:
  other: 1.0.0
importers:
  apps/first:
    devDependencies:
      '@napi-rs/cli':
        specifier: 'catalog:'
        version: {version}(peer@1.0.0)
  apps/second:
    devDependencies:
      '@napi-rs/cli':
        specifier: 'catalog:'
        version: {version}(peer@2.0.0)
snapshots:
  '@napi-rs/cli@{version}(peer@1.0.0)': {{}}
  '@napi-rs/cli@{version}(peer@2.0.0)': {{}}
'''


class PatchMetadata(unittest.TestCase):
    def run_meta(self, target, *, is_lock=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "target").write_text(target)
            quote = "'" if is_lock else '"'
            return subprocess.run(
                ["awk", "-v", "pkg=@napi-rs/cli", "-v", "ph=abcdef0123456789",
                 "-v", f"q={quote}",
                 "-v", f"tag={'stamp' if is_lock else ''}",
                 "-v", f"val={'abcdef0123456789' if is_lock else 'patches/napi.patch'}",
                 "-f", str(SCRIPT), str(root / "target")],
                capture_output=True, text=True,
            )

    def test_repins_and_multiple_peers(self):
        for version in ["3.10.1", "3.10.4", "3.10.10", "99.0.0"]:
            with self.subTest(version=version):
                source = workspace(version)
                result = self.run_meta(source)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('"@napi-rs/cli": patches/napi.patch', result.stdout)
                result = self.run_meta(lock(version), is_lock=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.count("(patch_hash=abcdef0123456789)"), 4)
                self.assertIn("'@napi-rs/cli': abcdef0123456789", result.stdout)

    def test_catalog_is_not_an_importer(self):
        target = lock("3.10.4").replace("importers:", "catalogs:\n  default:\n    '@napi-rs/cli':\n      version: 3.10.4\nimporters:")
        result = self.run_meta(target, is_lock=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("(patch_hash=abcdef0123456789)"), 4)

    def test_peerless_and_mixed_versions(self):
        target = lock("3.10.4").replace("3.10.4(peer@2.0.0)", "3.11.0")
        result = self.run_meta(target, is_lock=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("version: 3.11.0(patch_hash=abcdef0123456789)", result.stdout)
        self.assertIn("'@napi-rs/cli@3.11.0(patch_hash=abcdef0123456789)':", result.stdout)
        self.assertEqual(result.stdout.count("(patch_hash=abcdef0123456789)"), 4)

    def test_existing_patch_metadata(self):
        for is_lock in [False, True]:
            target = lock("3.10.4") if is_lock else workspace("3.10.4")
            result = self.run_meta(target + "patchedDependencies:\n  other: patch\n", is_lock=is_lock)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already declares", result.stderr)

    def test_missing_or_partial_lock(self):
        for target in [lock("3.10.4").replace("@napi-rs/cli", "other"),
                       lock("3.10.4").replace("version: 3.10.4", "version: link:../local", 1),
                       lock("3.10.4").split("snapshots:")[0]]:
            with self.subTest(target=target):
                result = self.run_meta(target, is_lock=True)
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()

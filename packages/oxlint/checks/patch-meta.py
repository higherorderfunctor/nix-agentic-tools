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


# Copied from oxc 7c39be07f2. The workspace block is that file's last key; the
# lock block sits between packageExtensionsChecksum and importers.
UPSTREAM_WORKSPACE_BLOCK = """
patchedDependencies:
  # Babel 8 removed the internal traversal context scope used by FBT 1.0.0.
  babel-plugin-fbt@1.0.0: patches/babel-plugin-fbt@1.0.0.patch
"""
UPSTREAM_LOCK_CHECKSUM = "packageExtensionsChecksum: sha256-WlkiKBAt7r2UlrZsFUO1bnxo4IcnuMc2XFz6stV9WiY="
UPSTREAM_LOCK_ENTRY = "  babel-plugin-fbt@1.0.0: e748e7f8d950e1106d80d5b4a4440f76e6465c570a8178450017d12ccd53a491\n"
UPSTREAM_LOCK_BLOCK = "patchedDependencies:\n" + UPSTREAM_LOCK_ENTRY + "\n"


def upstream_lock(block):
    return lock("3.10.4").replace("importers:", f"\n{UPSTREAM_LOCK_CHECKSUM}\n\n{block}importers:")


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

    # A second top-level key, a dropped babel-plugin-fbt entry, or a lock left
    # without our entry each fails the hand-written output below.
    def test_merges_upstream_patch_metadata(self):
        source = workspace("3.10.4") + UPSTREAM_WORKSPACE_BLOCK
        result = self.run_meta(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, source + '  "@napi-rs/cli": patches/napi.patch\n')
        result = self.run_meta(upstream_lock(UPSTREAM_LOCK_BLOCK), is_lock=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"""
{UPSTREAM_LOCK_CHECKSUM}

patchedDependencies:
  babel-plugin-fbt@1.0.0: e748e7f8d950e1106d80d5b4a4440f76e6465c570a8178450017d12ccd53a491
  '@napi-rs/cli': abcdef0123456789

importers:
""", result.stdout)
        self.assertEqual(result.stdout.count("patchedDependencies:"), 1)
        self.assertEqual(result.stdout.count("(patch_hash=abcdef0123456789)"), 4)

    def test_refuses_upstream_metadata_it_cannot_merge(self):
        cases = [
            ("already names", "patchedDependencies:\n" + UPSTREAM_LOCK_ENTRY + "  '@napi-rs/cli': 0123\n\n"),
            ("already names", "patchedDependencies:\n  '@napi-rs/cli@3.10.4': 0123\n\n"),
            ("cannot parse", "patchedDependencies:\n  babel-plugin-fbt@1.0.0:\n    hash: 0123\n\n"),
            ("not a block mapping", "patchedDependencies: {}\n\n"),
            ("declares patchedDependencies 2 times", UPSTREAM_LOCK_BLOCK * 2),
        ]
        for message, block in cases:
            with self.subTest(block=block):
                result = self.run_meta(upstream_lock(block), is_lock=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_transitive_references(self):
        parents = """  parent@1.0.0:
    dependencies:
      '@napi-rs/cli': 3.10.4(peer@1.0.0)
    optionalDependencies:
      '@napi-rs/cli': 3.10.4
"""
        target = lock("3.10.4").replace("3.10.4(peer@2.0.0)", "3.10.4") + parents
        for direct in [True, False]:
            with self.subTest(direct=direct):
                source = target if direct else target.split("importers:")[0] + "importers: {}\nsnapshots:" + target.split("snapshots:")[1]
                result = self.run_meta(source, is_lock=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("'@napi-rs/cli': 3.10.4(patch_hash=abcdef0123456789)(peer@1.0.0)", result.stdout)
                self.assertIn("'@napi-rs/cli': 3.10.4(patch_hash=abcdef0123456789)\n", result.stdout)
                self.assertEqual(result.stdout.count("(patch_hash=abcdef0123456789)"), 6 if direct else 4)

    def test_missing_or_partial_lock(self):
        for target in [lock("3.10.4").replace("@napi-rs/cli", "other"),
                       lock("3.10.4").replace("version: 3.10.4", "version: link:../local", 1),
                       lock("3.10.4").split("snapshots:")[0]]:
            with self.subTest(target=target):
                result = self.run_meta(target, is_lock=True)
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()

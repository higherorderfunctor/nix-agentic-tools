"""Name-only patch metadata follows resolved versions and covers every peer."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv.pop(1))

WORKSPACE = '''catalog:
  "@napi-rs/cli": 99.0.0
overrides:
  other: 1.0.0
'''
WORKSPACE_PACKAGES = "packages:\n  - apps/*\n"

LOCK_HEADER = '''---
packageManagerDependencies: {}
---
lockfileVersion: '9.0'
overrides:
  other: 1.0.0
'''
IMPORTERS = '''importers:
  apps/first:
    devDependencies:
      '@napi-rs/cli':
        specifier: 'catalog:'
        version: 3.10.10(peer@1.0.0)
  apps/second:
    devDependencies:
      '@napi-rs/cli':
        specifier: 'catalog:'
        version: 3.10.10(peer@2.0.0)
  apps/third:
    devDependencies:
      '@napi-rs/cli':
        specifier: 99.0.0
        version: 99.0.0
'''
SNAPSHOTS = '''snapshots:
  '@napi-rs/cli@3.10.10(peer@1.0.0)': {}
  '@napi-rs/cli@3.10.10(peer@2.0.0)': {}
  '@napi-rs/cli@99.0.0': {}
  parent@1.0.0:
    dependencies:
      '@napi-rs/cli': 3.10.10(peer@1.0.0)
    optionalDependencies:
      '@napi-rs/cli': 99.0.0
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


def lock(*, before_importers="", importers=IMPORTERS, snapshots=SNAPSHOTS):
    return LOCK_HEADER + before_importers + importers + snapshots


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

    def assert_rejects_lock(self, source, message):
        result = self.run_meta(source, is_lock=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)

    def assert_stamped(self, result, expected):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([line for line in result.stdout.splitlines() if "(patch_hash=" in line], expected)

    def test_workspace_inserts_name_only_entry_before_next_key(self):
        # A versioned key would stop following upstream's catalog repins.
        result = self.run_meta(WORKSPACE + WORKSPACE_PACKAGES)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, WORKSPACE + '''patchedDependencies:
  "@napi-rs/cli": patches/napi.patch

''' + WORKSPACE_PACKAGES)

    def test_lock_stamps_resolved_references_but_not_catalog_or_package_keys(self):
        # The two peers share a version but need separate stamps; a different
        # peerless version has no suffix to insert before. Transitive references
        # still need stamps when direct importers exist. Catalog and package
        # declarations must not be stamped even when their versions match.
        catalogs = '''catalogs:
  default:
    '@napi-rs/cli':
      version: 3.10.10
'''
        packages = '''packages:
  '@napi-rs/cli@3.10.10': {}
  '@napi-rs/cli@99.0.0': {}
'''
        expected_stamps = [
            "        version: 3.10.10(patch_hash=abcdef0123456789)(peer@1.0.0)",
            "        version: 3.10.10(patch_hash=abcdef0123456789)(peer@2.0.0)",
            "        version: 99.0.0(patch_hash=abcdef0123456789)",
            "  '@napi-rs/cli@3.10.10(patch_hash=abcdef0123456789)(peer@1.0.0)': {}",
            "  '@napi-rs/cli@3.10.10(patch_hash=abcdef0123456789)(peer@2.0.0)': {}",
            "  '@napi-rs/cli@99.0.0(patch_hash=abcdef0123456789)': {}",
            "      '@napi-rs/cli': 3.10.10(patch_hash=abcdef0123456789)(peer@1.0.0)",
            "      '@napi-rs/cli': 99.0.0(patch_hash=abcdef0123456789)",
        ]
        # Both inserting a block and joining upstream's block must stamp the
        # same resolved members. In the latter case keep the foreign entry.
        upstream_prefix = f"\n{UPSTREAM_LOCK_CHECKSUM}\n\n"
        cases = [
            ("insert before next key", catalogs,
             "patchedDependencies:\n  '@napi-rs/cli': abcdef0123456789\n\n" + catalogs),
            ("join without dropping upstream entry", catalogs + upstream_prefix + UPSTREAM_LOCK_BLOCK,
             catalogs + upstream_prefix + """patchedDependencies:
  babel-plugin-fbt@1.0.0: e748e7f8d950e1106d80d5b4a4440f76e6465c570a8178450017d12ccd53a491
  '@napi-rs/cli': abcdef0123456789

"""),
        ]
        for name, before_importers, expected_prefix in cases:
            with self.subTest(name=name):
                result = self.run_meta(lock(before_importers=before_importers, snapshots=packages + SNAPSHOTS), is_lock=True)
                self.assert_stamped(result, expected_stamps)
                prefix = LOCK_HEADER + expected_prefix + "importers:\n"
                self.assertEqual(result.stdout[:len(prefix)], prefix)
                self.assertIn(packages, result.stdout)
                self.assertEqual(result.stdout.count("patchedDependencies:"), 1)

    def test_no_direct_importer_accepts_transitive_only_reference(self):
        # Requiring a direct importer would reject a lock that only uses the
        # patched package transitively. Pin both reference types and their snapshots.
        snapshots = '''snapshots:
  '@napi-rs/cli@3.10.4': {}
  '@napi-rs/cli@3.10.4(peer@1.0.0)': {}
  parent@1.0.0:
    dependencies:
      '@napi-rs/cli': 3.10.4(peer@1.0.0)
    optionalDependencies:
      '@napi-rs/cli': 3.10.4
'''
        result = self.run_meta(lock(importers="importers: {}\n", snapshots=snapshots), is_lock=True)
        self.assert_stamped(result, [
            "  '@napi-rs/cli@3.10.4(patch_hash=abcdef0123456789)': {}",
            "  '@napi-rs/cli@3.10.4(patch_hash=abcdef0123456789)(peer@1.0.0)': {}",
            "      '@napi-rs/cli': 3.10.4(patch_hash=abcdef0123456789)(peer@1.0.0)",
            "      '@napi-rs/cli': 3.10.4(patch_hash=abcdef0123456789)",
        ])

    def test_workspace_joins_upstream_patch_metadata_at_eof(self):
        # With no following key to close the mapping, the EOF path must append
        # our entry without dropping the foreign one or creating a second key.
        source = WORKSPACE + WORKSPACE_PACKAGES + UPSTREAM_WORKSPACE_BLOCK
        result = self.run_meta(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, source + '  "@napi-rs/cli": patches/napi.patch\n')

    def test_refuses_upstream_metadata_it_cannot_merge(self):
        cases = [
            ("duplicate mapping keys would drop entries", UPSTREAM_LOCK_BLOCK * 2,
             "declares patchedDependencies 2 times"),
            ("flow mapping cannot be joined as a block", "patchedDependencies: {}\n\n",
             "not a block mapping"),
            ("name-only key competes with our entry", "patchedDependencies:\n" + UPSTREAM_LOCK_ENTRY + "  '@napi-rs/cli': 0123\n\n",
             "already names @napi-rs/cli"),
            ("nested mapping is not a scalar entry", "patchedDependencies:\n  babel-plugin-fbt@1.0.0:\n    hash: 0123\n\n",
             "cannot parse patchedDependencies entry"),
            ("versioned key also competes with our entry", "patchedDependencies:\n  '@napi-rs/cli@3.10.4': 0123\n\n",
             "already names @napi-rs/cli"),
        ]
        for name, block, message in cases:
            with self.subTest(name=name):
                self.assert_rejects_lock(lock(before_importers=block), message)

    def test_refuses_missing_or_partial_lock(self):
        cases = [
            ("no matching reference", lock().replace("@napi-rs/cli", "other"),
             "not every importer of @napi-rs/cli was patched"),
            ("no matching snapshot despite resolved importers", lock(snapshots=""),
             "no snapshot entry for @napi-rs/cli"),
            ("unpatchable importer among valid resolutions", lock().replace("version: 3.10.10(peer@1.0.0)", "version: link:../local", 1),
             "not every importer of @napi-rs/cli was patched"),
        ]
        for name, source, message in cases:
            with self.subTest(name=name):
                self.assert_rejects_lock(source, message)


if __name__ == "__main__":
    unittest.main()

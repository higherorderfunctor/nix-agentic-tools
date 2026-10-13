"""Refresh model docs without a release, and refuse invalid upstream changes."""

import base64
import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, sys.argv.pop(1))
from update import refresh

recipe = Path(sys.argv.pop(1)).read_text()
document = Path(sys.argv.pop(1)).read_text()
synthetic = "## Quick comparison\n\n| Model | Context |\n| --- | --- |\n| Auto | 1M |\n| Claude Opus 99.1 | 1M |\n"


class ModelRefresh(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.recipe = Path(self.work.name) / "package.nix"
        self.document = Path(self.work.name) / "models.md"
        self.recipe.write_text(recipe)
        self.document.write_text(document)

    def test_same_content_preserves_pin_and_mtime(self):
        before = self.recipe.stat().st_mtime_ns
        self.assertFalse(refresh(self.recipe, self.document, "2099-01-01"))
        self.assertEqual(self.recipe.read_text(), recipe)
        self.assertEqual(self.recipe.stat().st_mtime_ns, before)

    def test_new_models_advance_only_catalog_pin(self):
        # A new public row needs no change to the proprietary CLI release.
        changed = synthetic
        self.assertNotEqual(changed, document)
        self.document.write_text(changed)
        self.assertTrue(refresh(self.recipe, self.document, "2099-01-01"))
        digest = base64.b64encode(hashlib.sha256(changed.encode()).digest()).decode()
        updated = self.recipe.read_text()
        self.assertIn('snapshotDate = "2099-01-01";', updated)
        self.assertIn(f'hash = "sha256-{digest}";', updated)
        self.assertIn('url = "https://kiro.dev/docs/models.md";', updated)

    def test_changed_table_is_rejected_before_pin_write(self):
        self.document.write_text("<html>upstream login</html>")
        with self.assertRaisesRegex(ValueError, "Quick comparison"):
            refresh(self.recipe, self.document, "2099-01-01")
        self.assertEqual(self.recipe.read_text(), recipe)

    def test_unknown_model_name_is_rejected_before_pin_write(self):
        self.document.write_text(synthetic.replace("Claude Opus 99.1", "Mystery 99"))
        with self.assertRaisesRegex(ValueError, "unrecognized"):
            refresh(self.recipe, self.document, "2099-01-01")
        self.assertEqual(self.recipe.read_text(), recipe)


unittest.main()

#!/usr/bin/env python3
"""Check Hestia pins without Nix or GHA."""

import importlib.util
import re
import unittest
from pathlib import Path


class HestiaPinTest(unittest.TestCase):
    def test_action_and_matrix_use_packaged_release(self):
        root = Path(__file__).parents[2]
        package = (root / "dev/ci-hestia.nix").read_text()
        rev = re.search(r'rev = "([0-9a-f]{40})";', package).group(1)
        version = re.search(r'version = "([^"]+)";', package).group(1)
        pins = []
        for path in (root / ".github/actions/check-cache/action.yml",
                     root / ".github/workflows/ci.yml"):
            pins.extend(re.findall(r"uses: Mic92/hestia(?:/matrix)?@([0-9a-f]{40}) # v([^\s]+)",
                                   path.read_text()))
        self.assertEqual(pins, [(rev, version), (rev, version)])

    def test_coordinated_update_rewrites_every_pin(self):
        root = Path(__file__).parents[2]
        script = root / "dev/scripts/update-ci-hestia.py"
        spec = importlib.util.spec_from_file_location("update_ci_hestia", script)
        updater = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(updater)
        files = {path: (root / path).read_text() for path in (updater.RECIPE, *updater.ACTIONS)}
        revision = "a" * 40
        updated = updater.updated_files(files, "3.2.0", revision, "sha256-new")
        self.assertIn(f'rev = "{revision}";', updated[updater.RECIPE])
        self.assertIn('version = "3.2.0";', updated[updater.RECIPE])
        self.assertIn('hash = "sha256-new";', updated[updater.RECIPE])
        for path in updater.ACTIONS:
            self.assertIn(f"@{revision} # v3.2.0", updated[path])


if __name__ == "__main__":
    unittest.main()

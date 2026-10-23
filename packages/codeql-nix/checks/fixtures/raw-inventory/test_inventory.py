"""S1 artifact inventory checks; expectations come from F1 and pinned kit syntax."""

import hashlib
import json
from pathlib import Path
import re
import sys
import unittest


GENERATED = Path(sys.argv.pop(1))
CONTRACT = json.loads(Path(sys.argv.pop(1)).read_text())


def uncomment(text):
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)


class Inventory(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = (GENERATED / "nix.dbscheme").read_bytes()
        cls.classes = sorted(set(re.findall(
            r"\bclass\s+(\w+)\s+(?:extends|=)",
            uncomment((GENERATED / "nix/internal/generated/Ast.qll").read_text()),
        )))
        cls.tables = sorted(set(re.findall(
            r"^(\w+)\s*\(", uncomment(cls.schema.decode()), flags=re.M,
        )))
        cls.manifest = json.loads((GENERATED / "schema-manifest.json").read_text())

    def validate(self, manifest):
        self.assertEqual(manifest["classes"], self.classes)
        self.assertEqual(manifest["tables"], self.tables)
        self.assertEqual(manifest["schemaSha256"], hashlib.sha256(self.schema).hexdigest())

    def test_real_manifest_and_combined_schema(self):
        self.validate(self.manifest)
        self.assertTrue({"AstNode", "Token"}.issubset(self.classes))
        self.assertTrue({"files", "locations_default"}.issubset(self.tables))
        self.assertTrue(set(CONTRACT["relations"]).issubset(self.tables))
        self.assertNotIn("nx_bootstrap_targets", self.tables)


if __name__ == "__main__":
    unittest.main()

"""The build must refuse changed or missing GGUF licence declarations."""

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("check_license", Path(__file__).with_name("check-license.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class LicenseTests(unittest.TestCase):
    def test_embedded_license(self):
        for license_id in ("apache-2.0", "mit", None):
            with self.subTest(license_id=license_id), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "model.gguf"
                # Minimal GGUF v3: zero tensors and one string metadata field.
                key = b"general.license" if license_id else b"general.name"
                value = (license_id or "fixture").encode()
                path.write_bytes(struct.pack("<4sIQQ", b"GGUF", 3, 0, 1)
                                 + struct.pack("<Q", len(key)) + key
                                 + struct.pack("<IQ", 8, len(value)) + value)
                if license_id == "apache-2.0":
                    checker.check_license(path)
                else:
                    with self.assertRaisesRegex(ValueError, "Expected general.license"):
                        checker.check_license(path)


if __name__ == "__main__":
    unittest.main()

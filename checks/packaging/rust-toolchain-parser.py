"""Exercise the Rust channel parser on rustup's supported file formats."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PARSER = Path(sys.argv[1]).resolve()


class RustToolchainParser(unittest.TestCase):
    def parse(self, files):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, text in files.items():
                (root / name).write_text(text)
            return subprocess.run(
                [sys.executable, str(PARSER), str(root)],
                capture_output=True,
                text=True,
            )

    def assert_channel(self, files, channel):
        result = self.parse(files)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{channel}\n")
        self.assertEqual(result.stderr, "")

    def assert_rejected(self, files, diagnostic):
        result = self.parse(files)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn(diagnostic, result.stderr)

    def test_host_suffix_preserved_for_drift(self):
        channel = "1.86.0-x86_64-unknown-linux-gnu"
        self.assert_channel(
            {"rust-toolchain.toml": f'[toolchain]\nchannel = "{channel}"\n'}, channel
        )

    def test_legacy_bare_channel(self):
        self.assert_channel({"rust-toolchain": "1.86.0\n"}, "1.86.0")

    def test_legacy_toml_channel(self):
        self.assert_channel(
            {"rust-toolchain": '[toolchain]\nchannel = "1.87.0"\n'}, "1.87.0"
        )

    def test_legacy_toml_without_channel_records_absence(self):
        self.assert_channel(
            {"rust-toolchain": '[toolchain]\nprofile = "minimal"\n'},
            "",
        )

    def test_missing_files_record_absence(self):
        self.assert_channel({}, "")

    def test_rejects_both_files(self):
        self.assert_rejected(
            {
                "rust-toolchain": "1.86.0\n",
                "rust-toolchain.toml": '[toolchain]\nchannel = "1.88.0"\n',
            },
            "both rust-toolchain and rust-toolchain.toml exist",
        )

    def test_rejects_duplicate_channels(self):
        self.assert_rejected(
            {"rust-toolchain.toml": '[toolchain]\nchannel = "1.86.0"\nchannel = "1.88.0"\n'},
            "Cannot overwrite a value",
        )

    def test_rejects_malformed_toml(self):
        self.assert_rejected(
            {"rust-toolchain.toml": "[toolchain\n"},
            "Expected ']'",
        )

    def test_toml_channel(self):
        self.assert_channel(
            {"rust-toolchain.toml": '[toolchain]\nchannel = "1.88.0"\n'}, "1.88.0"
        )

    def test_toml_without_channel_records_absence(self):
        self.assert_channel(
            {"rust-toolchain.toml": '[toolchain]\ncomponents = ["rustfmt"]\nprofile = "minimal"\n'},
            "",
        )


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)

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
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn(diagnostic, result.stderr)

    def test_supported_file_shapes(self):
        hosted = "1.86.0-x86_64-unknown-linux-gnu"
        cases = {
            "legacy bare file is not parsed as TOML": (
                {"rust-toolchain": "1.86.0\n"}, "1.86.0"
            ),
            "legacy file with a table is not read as a bare channel": (
                {"rust-toolchain": '[toolchain]\nchannel = "1.87.0"\n'}, "1.87.0"
            ),
            "legacy table may omit the channel": (
                {"rust-toolchain": '[toolchain]\nprofile = "minimal"\n'}, ""
            ),
            "missing files do not prevent an explicit recipe override": ({}, ""),
            "TOML channel keeps its host suffix for drift comparison": (
                {"rust-toolchain.toml": f'[toolchain]\nchannel = "{hosted}"\n'}, hosted
            ),
            "TOML components do not count as a channel": (
                {"rust-toolchain.toml": '[toolchain]\ncomponents = ["rustfmt"]\nprofile = "minimal"\n'},
                "",
            ),
        }
        for label, (files, expected) in cases.items():
            with self.subTest(label=label):
                self.assert_channel(files, expected)

    def test_invalid_file_shapes(self):
        cases = {
            "a comment-only legacy file is not a bare channel": (
                {"rust-toolchain": "# pinned elsewhere\n"}, "expected a [toolchain] table"
            ),
            "an empty legacy file is not an absent channel": (
                {"rust-toolchain": ""}, "expected a [toolchain] table"
            ),
            "duplicate channels cannot silently select the last": (
                {"rust-toolchain.toml": '[toolchain]\nchannel = "1.86.0"\nchannel = "1.88.0"\n'},
                "Cannot overwrite a value",
            ),
            "malformed TOML is not read as a bare channel": (
                {"rust-toolchain.toml": "[toolchain\n"}, "Expected ']'"
            ),
            "the two filenames may not compete for precedence": (
                {
                    "rust-toolchain": "1.86.0\n",
                    "rust-toolchain.toml": '[toolchain]\nchannel = "1.88.0"\n',
                },
                "both rust-toolchain and rust-toolchain.toml exist",
            ),
        }
        for label, (files, diagnostic) in cases.items():
            with self.subTest(label=label):
                self.assert_rejected(files, diagnostic)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)

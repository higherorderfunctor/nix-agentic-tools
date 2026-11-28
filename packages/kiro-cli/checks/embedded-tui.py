"""Refusal cases for static TUI discovery in a release's native chat binary."""

import hashlib
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

tui_source, kas_source, library, zstd = sys.argv[1:5]
del sys.argv[1:5]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tui, frames = load("embedded_tui", tui_source), load("embedded_kas", kas_source)
BUN_HEADER = b"#!/usr/bin/env bun\n// @bun\n"
SCRIPT = BUN_HEADER + b"var fixture = 1;\n" * 8000


def compressed(data):
    return subprocess.check_output([zstd, "-q", "-c"], input=data)


def resource(data):
    """A frame followed by its payload's checksum, as the vendor embeds one."""
    return compressed(data) + hashlib.sha256(data).hexdigest().encode() + b"asset "


def elf(payload):
    header = bytearray(64)
    header[:4] = b"\x7fELF"
    struct.pack_into("<H", header, 18, 62)
    return header + payload


class ExtractionTests(unittest.TestCase):
    def run_extract(self, payload, architecture="x86_64"):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary, destination = root / "native", root / "tui.js"
            binary.write_bytes(payload)
            tui.extract(frames, binary, destination, architecture, library, zstd)
            return destination.read_bytes()

    def test_unrelated_frames_and_valid_tui(self):
        # Reject a non-script with a valid checksum even when large enough,
        # and keep scanning until the real TUI is found.
        unrelated = b"\x7fELF bun" + b"x" * len(SCRIPT)
        self.assertEqual(self.run_extract(elf(resource(unrelated) + resource(SCRIPT))), SCRIPT)

    def test_refuses_invalid_tui(self):
        digest = hashlib.sha256(SCRIPT).hexdigest().encode()
        cases = (
            ("checksum elsewhere in the binary cannot authenticate this frame",
             compressed(SCRIPT) + b"x" + digest, "expected one checksum-adjacent TUI frame, found 0"),
            ("duplicate scripts cannot be resolved by picking one",
             resource(SCRIPT) + resource(SCRIPT + b"//\n"), "expected one checksum-adjacent TUI frame, found 2"),
            ("truncated script cannot pass just because its checksum matches",
             resource(BUN_HEADER + b"var fixture = 1;\n"), "embedded TUI is unexpectedly small"),
        )
        for regression, payload, diagnostic in cases:
            with self.subTest(regression=regression), self.assertRaisesRegex(ValueError, diagnostic):
                self.run_extract(elf(payload))

    def test_fat_binary_reads_target_architecture(self):
        # Both slices have valid but different scripts; return only ARM bytes.
        x86, arm = resource(SCRIPT + b"// x86\n"), resource(SCRIPT)
        header_size = 48
        header = struct.pack(">II", 0xCAFEBABE, 2)
        header += struct.pack(">IIIII", 0x01000007, 3, header_size, len(x86), 0)
        header += struct.pack(">IIIII", 0x0100000C, 0, header_size + len(x86), len(arm), 0)
        self.assertEqual(self.run_extract(header + x86 + arm, "aarch64"), SCRIPT)


if __name__ == "__main__":
    unittest.main()

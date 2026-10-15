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
SCRIPT = tui.SHEBANG + b"var fixture = 1;\n" * 8000


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
        self.assertEqual(self.run_extract(elf(resource(b"\x7fELF bun") + resource(SCRIPT))), SCRIPT)

    def test_checksum_must_follow_the_frame(self):
        detached = compressed(SCRIPT) + b"x" + hashlib.sha256(SCRIPT).hexdigest().encode()
        with self.assertRaisesRegex(ValueError, "found 0"):
            self.run_extract(elf(detached))

    def test_two_candidates_refuse(self):
        with self.assertRaisesRegex(ValueError, "found 2"):
            self.run_extract(elf(resource(SCRIPT) + resource(SCRIPT + b"//\n")))

    def test_small_tui_refuses(self):
        with self.assertRaisesRegex(ValueError, "small"):
            self.run_extract(elf(resource(tui.SHEBANG + b"var fixture = 1;\n")))

    def test_fat_binary_reads_target_architecture(self):
        x86, arm = resource(SCRIPT + b"// x86\n"), resource(SCRIPT)
        header_size = 48
        header = struct.pack(">II", 0xCAFEBABE, 2)
        header += struct.pack(">IIIII", frames.CPUS["x86_64"], 3, header_size, len(x86), 0)
        header += struct.pack(">IIIII", frames.CPUS["aarch64"], 0, header_size + len(x86), len(arm), 0)
        self.assertEqual(self.run_extract(header + x86 + arm, "aarch64"), SCRIPT)


if __name__ == "__main__":
    unittest.main()

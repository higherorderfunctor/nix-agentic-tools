"""Refusal cases for release KAS discovery and safe archive extraction."""

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest

source, library, zstd = sys.argv[1:4]
del sys.argv[1:4]
spec = importlib.util.spec_from_file_location("extractor", source)
extractor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extractor)


def archive(extra=(), server=extractor.SERVER, script=b"export const stock = true;"):
    output = io.BytesIO()
    files = [(extractor.PACKAGE, json.dumps({"name": "@kiro/agent", "type": "module", "version": "fixture"}).encode()),
             (server, script), ("node_modules/solver.wasm", b"wasm")]
    with tarfile.open(fileobj=output, mode="w") as tar:
        for name, data in files + list(extra):
            member = tarfile.TarInfo(name)
            if isinstance(data, str):
                member.type = tarfile.SYMTYPE
                member.linkname = data
                tar.addfile(member)
            else:
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
    return output.getvalue()


def frame(data):
    compressed = subprocess.check_output([zstd, "-q", "-c", "--check"], input=data)
    return compressed + hashlib.sha256(compressed).hexdigest().encode()


def elf(payload):
    header = bytearray(64)
    header[:4] = b"\x7fELF"
    struct.pack_into("<H", header, 18, 62)
    return header + payload


class ExtractionTests(unittest.TestCase):
    def run_extract(self, payload, architecture="x86_64"):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary, destination = root / "native", root / "out"
            binary.write_bytes(payload)
            extractor.extract(binary, destination, architecture, library, zstd)
            return (destination / extractor.SERVER).read_bytes()

    def test_unrelated_frame_and_valid_archive(self):
        # Scanning only the first frame would miss the actual KAS payload.
        self.assertEqual(self.run_extract(elf(frame(b"other resource") + frame(archive()))), b"export const stock = true;")

    def test_refuses_invalid_archives(self):
        valid = frame(archive())
        # Damage the zstd checksum without changing the frame's structure.
        corrupt = bytearray(valid[:-64])
        corrupt[-1] ^= 1
        cases = (
            ("absolute member is rejected rather than sanitized", frame(archive((("/escape", b"bad"),))),
             ValueError, "unsafe archive path: /escape"),
            ("duplicate archives are not resolved by picking one", valid + valid,
             ValueError, "expected one valid KAS archive, found 2"),
            ("duplicate server member cannot shadow the first", frame(archive(((extractor.SERVER, b"duplicate"),))),
             ValueError, "duplicate archive member:"),
            ("link targets cannot leave the destination", frame(archive((("node_modules/link", "../../escape"),))),
             tarfile.LinkOutsideDestinationError, "which is outside the destination"),
            ("missing checksum cannot authorize an otherwise valid archive", valid[:-64] + b"0" * 64,
             ValueError, "does not match an embedded checksum"),
            ("missing server cannot pass on other agent files alone", frame(archive(server="not-server.js")),
             ValueError, "missing regular KAS runtime file:"),
            ("parent traversal cannot leave the destination", frame(archive((("../escape", b"bad"),))),
             ValueError, r"unsafe archive path: \../escape"),
            ("recognized frame that fails decompression is skipped", bytes(corrupt),
             ValueError, "expected one valid KAS archive, found 0"),
            ("truncated compressed frame is not a candidate", valid[:10],
             ValueError, "expected one valid KAS archive, found 0"),
        )
        for regression, payload, exception, diagnostic in cases:
            with self.subTest(regression=regression), self.assertRaisesRegex(exception, diagnostic):
                self.run_extract(elf(payload))

    def test_fat_binary_selects_target_architecture_before_uniqueness(self):
        # Returning the first slice would produce the Intel marker.
        x86, arm = frame(archive(script=b"// Intel")), frame(archive())
        header_size = 48
        header = struct.pack(">II", 0xCAFEBABE, 2)
        header += struct.pack(">IIIII", 0x01000007, 3, header_size, len(x86), 0)
        header += struct.pack(">IIIII", 0x0100000C, 0, header_size + len(x86), len(arm), 0)
        self.assertEqual(self.run_extract(header + x86 + arm, "aarch64"), b"export const stock = true;")
        # A truncated target slice cannot be read or silently skipped.
        with self.assertRaisesRegex(ValueError, "invalid Mach-O architecture bounds"):
            self.run_extract(header + x86, "aarch64")


if __name__ == "__main__":
    unittest.main()

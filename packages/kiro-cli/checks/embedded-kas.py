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


def archive(extra=()):
    output = io.BytesIO()
    files = [(extractor.PACKAGE, json.dumps({"name": "@kiro/agent", "type": "module", "version": "fixture"}).encode()),
             (extractor.SERVER, b"export const stock = true;"), ("node_modules/solver.wasm", b"wasm")]
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
    compressed = subprocess.check_output([zstd, "-q", "-c"], input=data)
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
        self.assertEqual(self.run_extract(elf(frame(b"other resource") + frame(archive()))), b"export const stock = true;")

    def test_missing_duplicate_and_corrupt_candidates(self):
        valid = frame(archive())
        corrupt = bytearray(valid)
        corrupt[len(corrupt) // 2] ^= 1
        for payload in (frame(b"other resource"), valid + valid, corrupt):
            with self.subTest(size=len(payload)), self.assertRaises(ValueError):
                self.run_extract(elf(payload))

    def test_checksum_is_required(self):
        payload = frame(archive())[:-64] + b"0" * 64
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.run_extract(elf(payload))

    def test_archive_layout_and_path_refusals(self):
        for extra in ((("../escape", b"bad"),), (("/escape", b"bad"),),
                      (("node_modules/link", "../../escape"),), ((extractor.SERVER, b"duplicate"),)):
            with self.subTest(extra=extra), self.assertRaises((ValueError, tarfile.FilterError)):
                self.run_extract(elf(frame(archive(extra))))
        payload = archive().replace(b"dist/server/acp-server.js", b"dist/server/not-server.js")
        # Replacing a tar header also invalidates its checksum; either malformed
        # archive or missing runtime structure must refuse the release.
        with self.assertRaises((ValueError, tarfile.ReadError)):
            self.run_extract(elf(frame(payload)))

    def test_fat_binary_selects_target_architecture_before_uniqueness(self):
        x86, arm = frame(archive()), frame(archive())
        header_size = 48
        header = struct.pack(">II", 0xCAFEBABE, 2)
        header += struct.pack(">IIIII", extractor.CPUS["x86_64"], 3, header_size, len(x86), 0)
        header += struct.pack(">IIIII", extractor.CPUS["aarch64"], 0, header_size + len(x86), len(arm), 0)
        self.assertEqual(self.run_extract(header + x86 + arm, "aarch64"), b"export const stock = true;")
        with self.assertRaisesRegex(ValueError, "bounds"):
            self.run_extract(header + x86, "aarch64")


if __name__ == "__main__":
    unittest.main()

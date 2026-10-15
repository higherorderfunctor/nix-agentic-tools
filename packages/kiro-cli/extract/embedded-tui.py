"""Decode the TUI JavaScript embedded in a release's native chat binary.

The vendor stores it as one zstd frame followed directly by the SHA-256 hex of
the decompressed payload; on first launch the chat binary writes that payload
as tui.js beside the same hex in tui.js.sha256. Reading the frame here executes
nothing, so every platform's release is read on any host.
"""

import argparse
import hashlib
import importlib.util
import mmap
from pathlib import Path
import subprocess

SHEBANG = b"#!/usr/bin/env bun\n// @bun\n"


def extract(frames, binary, destination, architecture, library, zstd):
    found = []
    with binary.open("rb") as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_COPY) as data:
        start, end = frames.architecture_range(data, architecture)
        for offset, frame in frames.frames(data, start, end, library):
            result = subprocess.run([zstd, "-d", "-q", "-c"], input=frame, capture_output=True)
            if result.returncode or not result.stdout.startswith(SHEBANG):
                continue
            digest = hashlib.sha256(result.stdout).hexdigest()
            # The checksum the binary itself accepts, at the frame's end; a
            # bun script without it is some other resource.
            if data[offset + len(frame):offset + len(frame) + len(digest)] == digest.encode():
                found.append((digest, result.stdout))
    if len(found) != 1:
        raise ValueError(f"expected one checksum-adjacent TUI frame, found {len(found)}")
    digest, script = found[0]
    if len(script) < 100_000:
        raise ValueError("embedded TUI is unexpectedly small")
    destination.write_bytes(script)
    print(f"TUI: {len(script)} bytes; SHA-256 {digest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("destination", type=Path)
    # embedded-kas.py: its architecture slice and zstd frame scan.
    parser.add_argument("--frames", required=True)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--zstd-library", required=True)
    parser.add_argument("--zstd", required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("embedded_kas", args.frames)
    frames = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(frames)
    extract(frames, args.binary, args.destination, args.architecture, args.zstd_library, args.zstd)


if __name__ == "__main__":
    main()

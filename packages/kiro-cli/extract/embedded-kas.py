"""Extract the checksum-identified KAS tar from a release's native chat binary.

Discovery scans zstd frames inside the target architecture, never fixed offsets.
The vendor embeds the compressed frame's SHA-256 beside its resources. Other
compressed resources are ignored; ambiguous KAS archives and unsafe layouts fail.
"""

import argparse
import ctypes
import hashlib
import json
import mmap
from pathlib import Path, PurePosixPath
import struct
import subprocess
import tarfile
import tempfile

SERVER = "node_modules/@kiro/agent/dist/server/acp-server.js"
PACKAGE = "node_modules/@kiro/agent/package.json"
MAGIC = b"\x28\xb5\x2f\xfd"
CPUS = {"aarch64": 0x0100000C, "x86_64": 0x01000007}


def architecture_range(data, architecture):
    magic = data[:4]
    if magic == b"\x7fELF":
        if architecture != "x86_64" or struct.unpack_from("<H", data, 18)[0] != 62:
            raise ValueError("unsupported ELF architecture")
        return 0, len(data)
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        wide = magic[-1] == 0xBF
        count = struct.unpack_from(">I", data, 4)[0]
        # cspell:ignore IIQQII
        fmt = ">IIQQII" if wide else ">IIIII"
        stride = struct.calcsize(fmt)
        ranges = []
        for index in range(count):
            cpu, _, offset, size, *_ = struct.unpack_from(fmt, data, 8 + index * stride)
            if offset < 8 + count * stride or offset + size > len(data):
                raise ValueError("invalid Mach-O architecture bounds")
            if cpu == CPUS[architecture]:
                ranges.append((offset, offset + size))
        if len(ranges) != 1:
            raise ValueError(f"expected one {architecture} Mach-O slice, found {len(ranges)}")
        return ranges[0]
    if magic == b"\xcf\xfa\xed\xfe" and struct.unpack_from("<I", data, 4)[0] == CPUS[architecture]:
        return 0, len(data)
    raise ValueError("unsupported native binary format or architecture")


def validate_archive(archive, destination):
    members = archive.getmembers()
    names = set()
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or str(path) != member.name.rstrip("/"):
            raise ValueError(f"unsafe archive path: {member.name}")
        if member.name in names:
            raise ValueError(f"duplicate archive member: {member.name}")
        names.add(member.name)
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ValueError(f"unsupported archive member: {member.name}")
        # Validate EVERY member before writing anything. data_filter checks link
        # targets as well as members, including escape via earlier symlinks.
        tarfile.data_filter(member, destination)
    for name in (PACKAGE, SERVER):
        if name not in names or not archive.getmember(name).isfile():
            raise ValueError(f"missing regular KAS runtime file: {name}")
    metadata = json.load(archive.extractfile(PACKAGE))
    if metadata.get("name") != "@kiro/agent" or metadata.get("type") != "module":
        raise ValueError("unexpected KAS package metadata")
    if not any(name.endswith(".wasm") for name in names):
        raise ValueError("missing KAS WASM resources")
    return metadata, members


def frames(data, start, end, library):
    """Every complete zstd frame in data[start:end], as (offset, frame bytes).

    embedded-tui.py reads the TUI through this scan too.
    """
    decoder = ctypes.CDLL(library)
    decoder.ZSTD_findFrameCompressedSize.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    decoder.ZSTD_findFrameCompressedSize.restype = ctypes.c_size_t
    decoder.ZSTD_isError.argtypes = [ctypes.c_size_t]
    decoder.ZSTD_isError.restype = ctypes.c_uint
    position = start
    while (position := data.find(MAGIC, position, end)) != -1:
        pointer = ctypes.addressof(ctypes.c_char.from_buffer(data, position))
        size = decoder.ZSTD_findFrameCompressedSize(pointer, end - position)
        offset = position
        position += len(MAGIC)
        if not decoder.ZSTD_isError(size):
            yield offset, data[offset:offset + size]


def extract(binary, destination, architecture, library, zstd):
    candidates = []
    with binary.open("rb") as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_COPY) as data, tempfile.TemporaryDirectory() as tmp:
        start, end = architecture_range(data, architecture)
        for offset, frame in frames(data, start, end, library):
            digest = hashlib.sha256(frame).hexdigest()
            archive_path = Path(tmp) / f"{offset}.tar"
            with archive_path.open("wb") as target:
                result = subprocess.run([zstd, "-d", "-q", "-c"], input=frame, stdout=target, stderr=subprocess.PIPE)
            if result.returncode:
                continue
            try:
                archive = tarfile.open(archive_path, "r:")
            except tarfile.ReadError:
                continue
            with archive:
                if not any(m.name.startswith("node_modules/@kiro/agent/") for m in archive):
                    continue
                if data.find(digest.encode(), start, end) == -1:
                    raise ValueError("KAS frame SHA-256 does not match an embedded checksum")
                metadata, members = validate_archive(archive, destination)
                candidates.append((archive_path, digest, metadata, len(members)))
        if len(candidates) != 1:
            raise ValueError(f"expected one valid KAS archive, found {len(candidates)}")
        archive_path, digest, metadata, count = candidates[0]
        with tarfile.open(archive_path, "r:") as archive:
            archive.extractall(destination, filter="data")
        print(f"KAS {metadata['version']}: {count} members; compressed SHA-256 {digest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--architecture", choices=CPUS, required=True)
    parser.add_argument("--zstd-library", required=True)
    parser.add_argument("--zstd", required=True)
    args = parser.parse_args()
    extract(args.binary, args.destination, args.architecture, args.zstd_library, args.zstd)


if __name__ == "__main__":
    main()

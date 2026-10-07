#!/usr/bin/env python3
"""Extracts the two JavaScript bundles embedded in the pinned kiro-cli-chat binary.

usage: python3 bundles.py <out-dir> → kas.js (KAS @kiro/agent 0.66.26), tui.js.
The pinned ELF contains zstd frames at the offsets below. Binary and bundle hashes
bind AST locations and replay functions to this flake's build. Needs zstd on PATH.
"""
import hashlib
import io
import os
import pathlib
import subprocess
import sys
import tarfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "common"))
import pin  # noqa: E402

BINARY_SHA = "94c656bf317607ba1cca17e010e98fc5829d8e7c864f44bdedd8c4f4ad446c4d"
KAS = (6906041, "3bc21b1f684cd3cc4aa0e10f198a5f97ea41398a63ed5db1858d4145fbe42828")
TUI = (95983877, "6733ecdbd8a72ecd1d6c7a2bbfc763b8b81a00e8cd097febcc01dc2152fede4f")
MEMBER = "node_modules/@kiro/agent/dist/server/acp-server.js"


def frame(data, offset):
    # zstd decodes the first frame, then stops with an error at the bytes that follow it.
    r = subprocess.run(["zstd", "-dcq"], input=data[offset:], capture_output=True)
    return r.stdout


if len(sys.argv) != 2:
    sys.exit(__doc__)
out = pathlib.Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
pkg = pathlib.Path(os.environ.get("KIRO_PKG") or pin.package("kiro-cli.unwrapped"))
binary = (pkg / "bin" / ".kiro-cli-chat-wrapped").read_bytes()
if hashlib.sha256(binary).hexdigest() != BINARY_SHA:
    sys.exit("kiro-cli-chat is not the pinned 2.28.0 binary")
with tarfile.open(fileobj=io.BytesIO(frame(binary, KAS[0]))) as tar:
    kas = tar.extractfile(MEMBER).read()
tui = frame(binary, TUI[0])
for name, data, want in (("kas.js", kas, KAS[1]), ("tui.js", tui, TUI[1])):
    got = hashlib.sha256(data).hexdigest()
    if got != want:
        sys.exit(f"{name}: sha256 {got} != {want}")
    (out / name).write_bytes(data)
    print(f"{out / name} {got}")

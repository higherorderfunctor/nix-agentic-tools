#!/usr/bin/env python3
"""Extracts the two JavaScript bundles embedded in the pinned kiro-cli-chat binary.

usage: python3 bundles.py <out-dir>   → <out-dir>/kas.js (KAS @kiro/agent 0.66.22 acp-server.js)
                                        <out-dir>/tui.js
Each bundle is one zstd frame at a fixed offset of the 2.27.1 ELF; the KAS frame is a tar holding
node_modules/@kiro/agent/dist/server/acp-server.js. Both are checked against the hashes the report
used, so a different pin fails loudly instead of yielding other line numbers. Needs `zstd` on PATH.
The same KAS file also appears under a v3 run's home at
.local/share/kiro-cli/kas/2.27.1-*/node_modules/@kiro/agent/dist/server/acp-server.js.
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

BINARY_SHA = "d2ada4bdda2e58bc3375e6822d7dd6ba19a53ff54c6d934d8f2186a0b9ad1372"
KAS = (6893905, "79a1a743ee7236a71bba9c6c68342deccfcffea4d61361eae0254288339b19c8")
TUI = (95928573, "3fe9ded80cc1edc1d2839c18603eb66850644df505f6618b134a7ecad193755e")
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
    sys.exit("kiro-cli-chat is not the 2.27.1 binary the report used")
with tarfile.open(fileobj=io.BytesIO(frame(binary, KAS[0]))) as tar:
    kas = tar.extractfile(MEMBER).read()
tui = frame(binary, TUI[0])
for name, data, want in (("kas.js", kas, KAS[1]), ("tui.js", tui, TUI[1])):
    got = hashlib.sha256(data).hexdigest()
    if got != want:
        sys.exit(f"{name}: sha256 {got} != {want}")
    (out / name).write_bytes(data)
    print(f"{out / name} {got}")

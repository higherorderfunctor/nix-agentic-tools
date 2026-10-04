import hashlib
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from isolated_launch import materialize  # noqa: E402


def verified_tui(root):
    """Every tui.js whose sibling checksum matches, i.e. fully written."""
    verified = []
    for asset in root.rglob("tui.js"):
        checksum = asset.with_name("tui.js.sha256")
        if checksum.is_file():
            expected = checksum.read_text().strip()
            actual = hashlib.sha256(asset.read_bytes()).hexdigest()
            if actual == expected:
                verified.append(asset)
    return verified


binary, destination, fake_kas, cert_file = sys.argv[1:]
with tempfile.TemporaryDirectory(prefix="kiro-tui-") as root:
    # The TUI is unpacked before chat needs an agent, so a fake KAS that only
    # answers `initialize` is enough and the real engine never starts.
    materialize(
        binary,
        ["--v3", "chat"],
        root,
        destination,
        verified_tui,
        "checksum-validated embedded TUI",
        cert_file,
        env={"KIRO_KAS_NODE_PATH": fake_kas, "KIRO_KAS_SERVER_PATH": fake_kas},
    )

if Path(destination).stat().st_size < 100_000:
    raise RuntimeError("embedded TUI is unexpectedly small")

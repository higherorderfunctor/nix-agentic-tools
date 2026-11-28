"""Verify selected substitutions against actual vendor bytes."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile

patcher_path, stock_path, patched_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("patcher", patcher_path)
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
stock = Path(stock_path).read_bytes()
selections = (
    ("relativeFileCheckPaths",),
    ("stripVendorWorktreeSteering",),
    ("relativeFileCheckPaths", "stripVendorWorktreeSteering"),
)
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "server.js"
    for names in selections:
        result, errors = patcher.patch(stock, patcher.replacements(names))
        if len(names) == 2:
            assert Path(patched_path).read_bytes() == result, "packaged selection differs from the two selected patches"
        else:
            # The stock and combined bundles are checked when built. Check
            # each single selection separately so neither needs the other.
            assert not errors, (names, errors)
            path.write_bytes(result)
            syntax = subprocess.run(["node", "--check", str(path)], capture_output=True, text=True)
            assert syntax.returncode == 0, (names, syntax.stderr)
print("PASS: single vendor selections parse and the real package matches both patches")

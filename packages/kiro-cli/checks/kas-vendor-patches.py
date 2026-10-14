"""Verify selected substitutions against actual vendor bytes, including all-off."""

import importlib.util
import itertools
from pathlib import Path
import subprocess
import sys
import tempfile

patcher_path, stock_path, patched_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("patcher", patcher_path)
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
stock = Path(stock_path).read_bytes()
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "server.js"
    for relative, strip in itertools.product((False, True), repeat=2):
        names = [name for name, value in zip(patcher.FIXED, (relative, strip)) if value]
        result, errors = patcher.patch(stock, patcher.replacements(names))
        assert not errors, errors
        expected = stock
        for name in names:
            expected = expected.replace(*patcher.FIXED[name])
        assert result == expected
        path.write_bytes(result)
        subprocess.run(["node", "--check", str(path)], check=True)
    assert Path(patched_path).read_bytes() == result, "packaged selection differs from the two selected patches"
print("PASS: four vendor selections preserve every unselected byte; real patched package matches")

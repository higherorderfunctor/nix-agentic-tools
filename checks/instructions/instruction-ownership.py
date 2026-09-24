"""Replay old delivery ledgers through the repository's actual activation writers."""

import json
import os
from pathlib import Path
import subprocess
import sys

scripts = json.loads(Path(sys.argv[1]).read_text())
materializer, source = sys.argv[2:]
router = ".claude/rules/delegate-sizing-router.md"


def run(script, root):
    return subprocess.run([script], cwd=root, text=True, capture_output=True, check=True)


for kind in ["absent", "regular", "store-symlink", "stale-regular"]:
    root = Path(kind).resolve()
    state = root / "state"
    state.mkdir(parents=True)
    agents = root / "AGENTS.md"
    if kind == "store-symlink":
        agents.symlink_to(source)
    elif kind != "absent":
        agents.write_text(Path(source).read_text() if kind == "regular" else "old generation")
        os.utime(agents, (1, 1))
    router_file = root / router
    router_file.parent.mkdir(parents=True)
    # The generator must also prune a retained regular router; upstream cleanup
    # removes only store symlinks, so test both prior delivery shapes.
    if kind == "store-symlink":
        router_file.symlink_to(source)
    else:
        router_file.write_text("redundant router")
    (root / "conflict").write_text("user conflict")
    (root / "retired").write_text("user retained")
    old = {
        name: {"mode": "symlink", "option": f'ai.codex.files."{name}"', "source": source}
        for name in ["AGENTS.md", router, "retired"]
    }
    (state / "ai-delivery-observed.json").write_text(json.dumps(old))
    (state / "files.json").write_text(json.dumps({"managedFiles": list(old)}))
    for activation in range(2):
        previous_mtime = agents.stat().st_mtime_ns if agents.exists() else None
        run(scripts["snapshot"], root)
        run(scripts["cleanup"], root)
        run(scripts["create"], root)
        if kind == "regular" or activation:
            assert agents.stat().st_mtime_ns == previous_mtime, "seed churned a real file"
        subprocess.run([materializer, "all", str(root)], check=True)
        result = run(scripts["inspect"], root)
        assert not agents.is_symlink()
        assert agents.read_bytes() == Path(source).read_bytes()
        assert not router_file.exists() and not router_file.is_symlink()
        assert "AGENTS.md" not in result.stderr, result.stderr
        assert "delegate-sizing-router" not in result.stderr, result.stderr
        assert 'ai.codex.files."conflict" is set but devenv did not deliver' in result.stderr
        assert 'ai.codex.files."retired" was removed but devenv retained' in result.stderr
        assert (root / "conflict").read_text() == "user conflict"
        assert (root / "retired").read_text() == "user retained"
        ledger = json.loads((state / "ai-delivery-observed.json").read_text())
        assert ledger["AGENTS.md"]["mode"] == "seed"
        assert router not in ledger
        assert "retired" in ledger
        if kind == "regular" or activation:
            assert agents.stat().st_mtime_ns == previous_mtime, "materializer churned unchanged file"

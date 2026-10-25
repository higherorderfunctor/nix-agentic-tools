"""Run Copilot's evaluated skill plans through the shared files engine."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("files_engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
plans = json.loads(Path(sys.argv[2]).read_text())
source = Path(sys.argv[3])
bash = sys.argv[4]

with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    root = base / "repo"
    skills = root / ".github/skills"
    skills.mkdir(parents=True)
    sibling = skills / "unmanaged.txt"
    sibling.write_text("keep\n")
    state = base / "state/ai.json"
    previous = set()
    for step in ("enabled", "enabled", "suppressed", "empty", "enabled", "disabled"):
        plan = plans[step]
        engine.reconcile(plan, root, state, "prune")
        engine.reconcile(plan, root, state, "apply")
        paths = {item["path"] for item in plan}
        records = json.loads(state.read_text())["files"] if state.exists() else {}
        assert set(records) == paths
        assert all(not (root / path).exists() for path in previous - paths)
        for item in plan:
            destination = root / item["path"]
            assert destination.is_file() and not destination.is_symlink()
            assert destination.read_bytes() == Path(item["content"]["source"]).read_bytes()
            assert destination.stat().st_mode & 0o222 == 0
        assert sibling.read_text() == "keep\n"
        if plan:
            skill = skills / "local"
            # Resolve the authored Markdown links from their delivered location.
            links = re.findall(r"\[[^\]]+\]\(([^)]+)\)", (skill / "SKILL.md").read_text())
            assert links and all((skill / link).is_file() for link in links)
            assert (skill / "reference.md").read_bytes() == (skill / "references/deep/guide.md").read_bytes()
            assert (skill / "scripts/check.sh").stat().st_mode & 0o111
            subprocess.run([bash, "scripts/check.sh"], cwd=skill, check=True)
        if step == "enabled" and previous == paths:
            assert not list(state.parent.glob("*.bak"))
            edited = skills / "example/assets/expected.txt"
            edited.chmod(0o644)
            edited.write_text("operator edit\n")
        previous = paths
    backups = list(state.parent.glob("*.bak"))
    assert len(backups) == 1 and backups[0].read_text() == "operator edit\n"
    assert not state.exists()
    assert (source / "reference.md").is_symlink()
    print("PASS: copied skill assets, nested references, executable and file symlink; repeat, suppression, empty and disable retire only owned files")

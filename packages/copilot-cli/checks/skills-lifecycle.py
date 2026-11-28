"""Run Copilot's evaluated skill plans through the shared files engine."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("files_engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
plans = json.loads(Path(sys.argv[2]).read_text())
source = Path(sys.argv[3])

# Use the authored tree as the byte oracle, not the plan's source paths. Pin
# names independently: a plan that silently omits a leaf must fail too.
leaves = (
    "SKILL.md",
    "assets/expected.txt",
    "reference.md",
    "references/deep/guide.md",
    "scripts/check.sh",
)
assert (source / "reference.md").readlink() == Path("references/deep/guide.md"), "fixture must link to the nested guide"

# Empty and disabled both retire all copies, but one removes inputs and the
# other still has populated inputs. Keep both transitions from an owned tree.
steps = (
    ("first apply copies shared and local skills", "enabled", ("example", "local")),
    ("a null override retires only the inherited skill", "suppressed", ("local",)),
    ("removing all inputs retires the last copy", "empty", ()),
    ("repopulating an empty tree reacquires ownership", "enabled", ("example", "local")),
    ("disabling populated Copilot retires every copy", "disabled", ()),
)

with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    root = base / "repo"
    skills = root / ".github/skills"
    skills.mkdir(parents=True)
    sibling = skills / "unmanaged.txt"
    sibling.write_text("keep\n")
    state = base / "state/ai.json"
    for name, step, names in steps:
        plan = plans[step]
        expected = {skills / skill / leaf: source / leaf for skill in names for leaf in leaves}
        engine.reconcile(plan, root, state, "prune")
        engine.reconcile(plan, root, state, "apply")
        actual = {path for path in skills.rglob("*") if path.is_symlink() or not path.is_dir()}
        assert actual == expected.keys() | {sibling}, (name, "delivered tree membership", actual)
        for destination, original in expected.items():
            assert destination.is_file() and not destination.is_symlink(), (name, destination, "regular copy required")
            assert destination.read_bytes() == original.read_bytes(), (name, destination, "wrong authored bytes")
        print(f"PASS: {name}")

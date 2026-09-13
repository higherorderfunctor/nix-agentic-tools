"""Pinned native CLI checks; isolated from Scribe and consumer policy fields."""

import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
STRICTDOC = "/nix/store/qc5w0rnlr2pl8zvaaq5gi6jfhm7h50im-strictdoc/bin/strictdoc"
GRAMMAR = """[DOCUMENT]
TITLE: Native controls

[GRAMMAR]
ELEMENTS:
- TAG: REQUIREMENT
  FIELDS:
  - TITLE: UID
    TYPE: String
    REQUIRED: True
  - TITLE: STATEMENT
    TYPE: String
    REQUIRED: True
  RELATIONS:
  - TYPE: Parent
  - TYPE: Child
  - TYPE: Parent
    ROLE: H
  - TYPE: Parent
    ROLE: R
  - TYPE: Child
    ROLE: Q
"""


def document(edges):
    text = GRAMMAR
    for uid in ["A", "B", "Z", "ISOLATED"]:
        text += f"\n[REQUIREMENT]\nUID: {uid}\nSTATEMENT: {uid}\n"
        owned = [e for e in edges if e[0] == uid]
        if owned:
            text += "RELATIONS:\n"
            for owner, kind, role, target in owned:
                text += f"- TYPE: {kind}\n  VALUE: {target}\n"
                if role is not None:
                    text += f"  ROLE: {role}\n"
    return text


cases = {
    "multiple_roots": ([], True),
    "multiple_native_parents": (
        [("Z", "Parent", "H", "A"), ("Z", "Parent", "R", "B")], True
    ),
    "child_owned_bridge": (
        [("Z", "Parent", "R", "A"), ("Z", "Child", "Q", "B")], True
    ),
    "combined_role_cycle": (
        [("A", "Parent", "H", "B"), ("Z", "Parent", "R", "A"),
         ("Z", "Child", "Q", "B")], False
    ),
    "self_cycle": ([("A", "Parent", "R", "A")], False),
    "missing_endpoint": ([("A", "Parent", "H", "ABSENT")], False),
}
cases["unroled_cycle"] = ([("A", "Parent", None, "B"), ("B", "Parent", None, "A")], False)
cases["unroled_child_cycle"] = ([("A", "Child", None, "B"), ("B", "Child", None, "A")], False)
cases["named_parent_cycle"] = ([("A", "Parent", "H", "B"), ("B", "Parent", "R", "A")], False)
cases["named_child_cycle"] = ([("A", "Child", "Q", "B"), ("B", "Child", "Q", "A")], False)
cases["unroled_mixed_cycle"] = ([("A", "Parent", None, "B"), ("Z", "Parent", None, "A"), ("Z", "Child", None, "B")], False)
results = []
for name, (edges, expected) in cases.items():
    case_dir = ROOT / "native" / name
    case_dir.mkdir(parents=True, exist_ok=True)
    source = case_dir / "input.sdoc"
    source.write_text(document(edges))
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    cmd = [STRICTDOC, "export", str(source), "--formats", "sdoc",
           "--no-parallelization", "--output-dir", str(case_dir / "export")]
    start = time.perf_counter()
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    output = proc.stdout + proc.stderr
    (ROOT / "logs" / f"native-{name}.log").write_text(output)
    actual = proc.returncode == 0
    expected_native = True if name in {"combined_role_cycle", "named_parent_cycle", "named_child_cycle"} else expected
    assert actual == expected_native, (name, proc.returncode, output)
    if "cycle" in name and not actual and name != "self_cycle":
        assert "cycle detected" in output, output
    assert hashlib.sha256(source.read_bytes()).hexdigest() == before
    results.append({"case": name, "accepted": actual, "expected": expected,
                    "satisfies_required_behavior": actual == expected, "input_unchanged": True, "seconds": time.perf_counter()-start,
                    "command": cmd, "exit": proc.returncode})
(ROOT / "results" / "native.json").write_text(json.dumps(results, indent=2)+"\n")
print(json.dumps(results, indent=2))

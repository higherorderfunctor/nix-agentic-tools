"""Check the stock, creator-only and delegate-routing selections on the real release against expectations the patcher does not supply.

The real extractor reads the stock bundle, an in-process creator-only patch and the packaged
delegate-routing selection. This check compares each one against independent expectations.
The selected edits themselves are never the oracle. Failure messages carry no vendor text.
Usage: `kas-vendor-patches.py <patcher> <stock acp-server.js> <stock facts.json> <extractor> <stock kas> <patched kas>`.
"""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

patcher_path, stock_path, facts_path, extractor, stock_kas, patched_kas = sys.argv[1:]
spec = importlib.util.spec_from_file_location("patcher", patcher_path)
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
stock = Path(stock_path).read_bytes()
original = json.loads(Path(facts_path).read_text(encoding="utf-8"))
server = "node_modules/@kiro/agent/dist/server/acp-server.js"
text = {name: fact["text"] for name, fact in original.items()}
planner, creator, orchestration = "agents.workflow.planner", "agents.workflow.creator", "workflow.orchestration"
gate, relative_gate = "/repo/.agents/tasks/fix-throttle/review.json", ".agents/tasks/fix-throttle/review.json"
# Authored replacement instructions, written here so a weaker rewrite of either cannot pass.
GATE_SENTENCE = "names the gate file's workspace-relative path, the one `fileCheck.path` checks, in its prompt"
PATH_RULE = (
    "5. **Every path in a step prompt is absolute, except the stop-condition file.** "
    "Step agents run in the parent session's workspace, not in a worktree, so write every other file a step "
    "reads, writes, or commits as a literal absolute path, and tell worktree steps to use "
    "`git -C <absolute worktree>`. The file a `stopCondition` or `completion` checks is written by the step "
    "and checked by `fileCheck.path` at the same relative path: a plain path relative to the workflow "
    "workspace root (e.g. `.agents/tasks/review.json`), without templates or an absolute worktree prefix. "
    "Step agents' cwd is that root, so the writing step and the check agree. "
    "A `fileCheck.path` that never resolves spins the loop to `maxIterations`."
)
# Measured on the pinned release: gate-file sites and lines the creator tweak may touch.
GATE_SITES, REWRITTEN_LINES = 4, 2
WORKTREE_PROHIBITION = " Do not create the worktree yourself."


def outside_literals(bundle, facts):
    """The bundle with the three prompt literals cut out."""
    pieces, cursor = [], 0
    for fact in sorted(facts.values(), key=lambda fact: fact["start"]):
        pieces.append(bundle[cursor : fact["start"]])
        cursor = fact["end"]
    return b"".join([*pieces, bundle[cursor:]])


assert text[creator].count(gate) == GATE_SITES, "the creator no longer names the gate file at the expected sites"
for kas in (stock_kas, patched_kas):
    for name, body in text.items():
        shipped = Path(kas, "share/kiro/vendorSteering", f"{name}.txt").read_bytes()
        assert shipped == body.encode(), f"{kas} does not ship the original {name}"
assert text[orchestration].count(WORKTREE_PROHIBITION) == 1, "expected exactly one worktree prohibition in the stock prompt"
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "server.js"
    unedited, errors = patcher.patch(stock, original, [])
    assert not errors, errors
    creator_only, errors = patcher.patch(stock, original, patcher.TWEAKS["relativeFileCheckPaths"])
    assert not errors, errors
    for label, result in (
        ("stock", unedited),
        ("creator-only", creator_only),
        ("delegate-routing", Path(patched_kas, server).read_bytes()),
    ):
        path.write_bytes(result)
        subprocess.run(["node", "--check", str(path)], check=True)
        facts = json.loads(subprocess.run([extractor, str(path)], check=True, capture_output=True, text=True).stdout)
        now = {name: fact["text"] for name, fact in facts.items()}
        assert outside_literals(result, facts) == outside_literals(stock, original), f"{label}: bytes outside the prompts changed"
        assert now[planner] == text[planner], f"{label}: the planner changed"
        if label == "creator-only":
            creator_only_text = now[creator]
            changed = [
                (was, line)
                for was, line in zip(text[creator].replace(gate, relative_gate).split("\n"), now[creator].split("\n"))
                if was != line
            ]
            assert len(changed) == REWRITTEN_LINES, f"{label}: {len(changed)} creator lines differ from the expected rewrite"
            for instruction in (GATE_SENTENCE, PATH_RULE):
                assert now[creator].count(instruction) == 1, f"{label}: an authored creator instruction is not present exactly once"
            assert now[creator].count(relative_gate) == GATE_SITES, f"{label}: the relative gate path is not at exactly the example sites"
            assert now[creator].count("\n") == text[creator].count("\n") and gate not in now[creator], label
        else:
            expected_creator = creator_only_text if label == "delegate-routing" else text[creator]
            assert now[creator] == expected_creator, f"{label}: the creator changed"
        expected = text[orchestration]
        if label == "delegate-routing":
            expected = expected.replace(WORKTREE_PROHIBITION, "", 1)
        assert now[orchestration] == expected, f"{label}: orchestration does not match the expected edit"
        assert (result == stock) == (label == "stock"), f"{label}: stock bytes must stay identical only with no edits"
print("PASS: stock, creator-only and delegate-routing selections match independent expectations")

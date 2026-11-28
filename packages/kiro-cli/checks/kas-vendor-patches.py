"""Check the four tweak selections on the real release against expectations the patcher does not supply.

Each selection is patched in process, re-extracted by the real extractor, and compared with the
original prompts under rules written here: which lines may differ, what must disappear, and how
much text is removed. The selected edits themselves are never the oracle. Failure messages carry
no vendor text.
Usage: `kas-vendor-patches.py <patcher> <stock acp-server.js> <stock facts.json> <extractor> <stock kas> <patched kas>`.
"""

import importlib.util
import itertools
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
paragraph_start, paragraph_end = "When a task should run in a worktree", "Do not create the worktree yourself.\n\n"
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
# Measured on the pinned release: gate-file sites, whole removed paragraph length, and lines the creator tweak may touch.
GATE_SITES, PARAGRAPH_LENGTH, REWRITTEN_LINES = 4, 663, 2


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
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "server.js"
    for rewrite, strip in itertools.product((False, True), repeat=2):
        names = [name for name, on in (("relativeFileCheckPaths", rewrite), ("stripVendorWorktreeSteering", strip)) if on]
        label = ",".join(names) or "no tweaks"
        result, errors = patcher.patch(stock, original, [edit for name in names for edit in patcher.TWEAKS[name]])
        assert not errors, errors
        path.write_bytes(result)
        subprocess.run(["node", "--check", str(path)], check=True)
        facts = json.loads(subprocess.run([extractor, str(path)], check=True, capture_output=True, text=True).stdout)
        now = {name: fact["text"] for name, fact in facts.items()}
        assert outside_literals(result, facts) == outside_literals(stock, original), f"{label}: bytes outside the prompts changed"
        assert now[planner] == text[planner], f"{label}: the planner changed"
        if rewrite:
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
            assert now[creator] == text[creator], f"{label}: the creator changed"
        if strip:
            head, _, rest = text[orchestration].partition(paragraph_start)
            removed, _, tail = rest.partition(paragraph_end)
            assert len(paragraph_start) + len(removed) + len(paragraph_end) == PARAGRAPH_LENGTH, f"{label}: removed paragraph has another length"
            assert now[orchestration] == head + tail, f"{label}: the orchestration lost more than the paragraph"
        else:
            assert now[orchestration] == text[orchestration], f"{label}: the orchestration changed"
        assert (result == stock) == (not names), f"{label}: stock bytes must stay identical only with no tweaks"
    assert Path(patched_kas, server).read_bytes() == result, "packaged selection differs from the two selected tweaks"
print("PASS: four vendor selections match independent expectations; real patched package matches")

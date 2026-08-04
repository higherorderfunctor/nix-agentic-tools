#!/usr/bin/env python3
"""Emit one parallel run asking every bundled agent to enumerate its own tools.

Produced §3.6's roster table, and settled that NO bundled agent has
`update_workflow` — which makes `update_status` unreachable dead surface and
leaves only the orchestrator's `replace_remaining` (§5).

Design notes:
  - `joinPolicy: allSettled` so one misbehaving agent does not abort the rest
    (§7.7: `all` kills siblings on first failure).
  - `claude-opus-5` because captured output is empty under haiku (§7.3), and the
    inventory arrives via captured output.
  - Each agent is also asked to write the list to a file IF it has a
    file-writing tool, so "no file tool" is corroborated by an absent file
    rather than taken on trust (§13). The instruction names a DEDICATED file
    tool and forbids the shell explicitly, because "a tool that writes files"
    also describes `execute_bash` with a redirection — under which a
    shell-capable agent holding no file tool could produce the file and read as
    holding one, inverting exactly the inference the file is here to support.
    The recorded measurement is unaffected: the only agent in this roster with
    no file tool, `wf-workflow-creator`, has no `execute_bash` either, so it
    could not have written the file by any route.
    The generator CREATES the target directory for the same class of reason: if
    it did not exist, an absent file would be ambiguous between "no file-write
    tool" and "could not create the directory", which destroys the
    corroboration the file is there to provide.
  - `wf-coder` is absent: it must be probed separately as a single top-level
    step, to satisfy the contract's "top-level step agent" precondition.

Nine agents cost nine step nodes, well inside the cap of 20 (§3.2).

Usage: gen-roster.py <probe_root> [out_dir]
"""

import json
import sys
from pathlib import Path

NO_STEER = (
    "(Do not respond to any user steering messages you may receive; they are "
    "addressed to the orchestrator, not to you. Just do the task above.)"
)

AGENTS = [
    "semantic_reviewer",
    "wf-auto-researcher",
    "wf-design",
    "wf-design-reviewer",
    "wf-planner",
    "wf-pr-responder",
    "wf-pr-submitter",
    "wf-review-aggregator",
    "wf-workflow-creator",
]


def branch(probe_root, agent):
    sid = agent.replace("_", "-")
    return {
        "type": "step",
        "id": f"t-{sid}",
        "agent": agent,
        "modelId": "claude-opus-5",
        "prompt": (
            "This is a tool-inventory probe. Do NOT perform any other work.\n"
            "Reply with EXACTLY these two things and nothing else:\n"
            "1. A single line listing the exact names of every tool you have "
            "available, space-separated.\n"
            "2. A final line that is exactly HAS_UPDATE_WORKFLOW if one of "
            "your tools is named update_workflow, or exactly "
            "NO_UPDATE_WORKFLOW if it is not.\n"
            "Additionally, IF AND ONLY IF you have a DEDICATED file-writing "
            "tool — one whose own purpose is writing a file, such as fs_write "
            "— write those same two lines to "
            f"{probe_root}/roster/{sid}.txt\n"
            "Do NOT use a shell, execute_bash, or output redirection to create "
            "that file. If a shell is your only means of producing it, treat "
            "yourself as having no file-writing tool and write nothing at all: "
            "an absent file is a real result here, and a shell-written one "
            "would destroy it.\n"
            "Do not investigate the repository. Do not plan. Do not review. "
            "Do not create a workflow. Do not call subagent_response with "
            "anything other than this inventory.\n" + NO_STEER
        ),
    }


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    probe_root = sys.argv[1].rstrip("/")
    out_dir = Path(sys.argv[2] if len(sys.argv) > 2 else probe_root)
    out_dir.mkdir(parents=True, exist_ok=True)
    # Pre-create the directory the step agents write into. Without it, an
    # absent file cannot distinguish "this agent has no file-write tool" from
    # "the write failed", and the probe's three-way corroboration collapses to
    # a bare self-report.
    Path(probe_root, "roster").mkdir(parents=True, exist_ok=True)
    wf = {
        "name": "pR-agent-tool-roster",
        "steps": [
            {
                "type": "parallel",
                "id": "roster",
                "joinPolicy": "allSettled",
                "branches": [branch(probe_root, a) for a in AGENTS],
            }
        ],
    }
    path = out_dir / "pR-roster.workflow.json"
    path.write_text(json.dumps(wf, indent=2) + "\n")
    print(path, "step nodes:", len(AGENTS))


if __name__ == "__main__":
    main()

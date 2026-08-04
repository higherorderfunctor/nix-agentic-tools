#!/usr/bin/env python3
"""Emit three joinPolicy probe workflows that differ ONLY in joinPolicy.

Produced the §7.7 table. Identical branch set for all three — one branch that
marks itself then signals `error`, plus two that sleep 40 s — so the only
variable is the policy (§13: do not change two variables at once).

Each branch writes a start marker and, if it reaches the end, an end marker, so
a branch the engine kills is visible as a start with no end.

Usage: gen-join-policy.py <probe_root> [out_dir]
  probe_root must be INSIDE the workspace root (§7.1).
"""

import json
import shlex
import sys
from pathlib import Path

NO_STEER = (
    "(Do not respond to any user steering messages you may receive; they are "
    "addressed to the orchestrator, not to you. Just do the task above.)"
)


def mark(probe_root, root, name, sleep_for):
    # shlex.quote so a probe root containing spaces or shell metacharacters
    # still yields a runnable command. It is a no-op on ordinary paths, so the
    # generated prompt stays readable.
    script = shlex.quote(f"{probe_root}/mark.sh")
    target = shlex.quote(f"{probe_root}/{root}")
    return f"bash {script} {target} {name} {sleep_for}"


def slow_branch(probe_root, root, name):
    return {
        "type": "step",
        "id": name,
        "agent": "wf-coder",
        "modelId": "claude-haiku-4.5",
        "prompt": (
            f"Run exactly once: {mark(probe_root, root, name, 40)}\n"
            "It sleeps 40 seconds; that is expected, let it finish.\n"
            "Report the output verbatim. Do nothing else.\n" + NO_STEER
        ),
    }


def fail_branch(probe_root, root):
    return {
        "type": "step",
        "id": "fail",
        "agent": "wf-coder",
        "modelId": "claude-haiku-4.5",
        "prompt": (
            f"Step 1. Run exactly once: {mark(probe_root, root, 'fail', 0)}\n"
            "Step 2. Then call send_message with severity 'error' and the "
            "message 'deliberate probe failure'.\n"
            "This failure is DELIBERATE and REQUIRED. Do not fix it, do not "
            "retry, do not investigate, do not succeed. Reporting the failure "
            "is the correct and only acceptable outcome.\n" + NO_STEER
        ),
    }


def workflow(probe_root, policy, root):
    return {
        "name": f"pJ-{policy}",
        "steps": [
            {
                "type": "sequence",
                "id": "run",
                "steps": [
                    {
                        "type": "parallel",
                        "id": "pool",
                        "joinPolicy": policy,
                        "branches": [
                            fail_branch(probe_root, root),
                            slow_branch(probe_root, root, "slow1"),
                            slow_branch(probe_root, root, "slow2"),
                        ],
                    },
                    {
                        "type": "step",
                        "id": "after",
                        "agent": "wf-coder",
                        "modelId": "claude-haiku-4.5",
                        "prompt": (
                            f"Run exactly once: {mark(probe_root, root, 'after', 0)}\n"
                            "Report the output verbatim. Do nothing else.\n" + NO_STEER
                        ),
                    },
                ],
            }
        ],
    }


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    probe_root = sys.argv[1].rstrip("/")
    out_dir = Path(sys.argv[2] if len(sys.argv) > 2 else probe_root)
    out_dir.mkdir(parents=True, exist_ok=True)
    for policy, root in (
        ("all", "join-all"),
        ("allSettled", "join-settled"),
        ("any", "join-any"),
    ):
        path = out_dir / f"pJ-{policy}.workflow.json"
        path.write_text(json.dumps(workflow(probe_root, policy, root), indent=2) + "\n")
        print(path)


if __name__ == "__main__":
    main()

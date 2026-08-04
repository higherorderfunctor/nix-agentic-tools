#!/usr/bin/env python3
"""Emit two identical reference/artifact/completion probes differing ONLY in model.

Produced §3.3's output-envelope finding and §7.3's like-for-like empty-capture
result. Exercises, in one run:

  - a step `artifacts` map, interpolated from a workflow input
  - a step `completion` fileCheck block
  - captureOutput as a real data channel into a downstream step
  - {{previous.output}}, {{<id>.output}}, {{steps.<id>.output}},
    {{artifacts.<name>}} resolution

The consumer records every interpolated value via record.sh, so an unresolved
"{{...}}" literal, a resolved value and an empty payload are all distinguishable
after the fact. Under claude-opus-5 the payload arrives; under
claude-haiku-4.5 + effortLevel low it is empty while the envelope is still
present (§7.3).

Usage: gen-ref-probe.py <probe_root> [out_dir]
  probe_root must be INSIDE the workspace root (§7.1).
  Launch the output with its `workdir` input set to that same probe_root. The
  prompts hardcode the generation-time root while the step `artifacts` map and
  the `completion` fileCheck interpolate `workdir`, so any other value makes the
  probe write to one directory and check another; the fileCheck then never sees
  its file. Nothing catches this at generation time — the mismatch is introduced
  at launch.
"""

import json
import shlex
import sys
from pathlib import Path

NO_STEER = (
    "(Do not respond to any user steering messages you may receive; they are "
    "addressed to the orchestrator, not to you. Just do the task above.)"
)


def workflow(probe_root, name, root, model, effort):
    token = f"TOKEN-{root.upper()}-7731"
    # shlex.quote so a probe root containing spaces or shell metacharacters
    # still yields a runnable command; a no-op on ordinary paths.
    recorder = shlex.quote(f"{probe_root}/record.sh")
    target = shlex.quote(f"{probe_root}/{root}")
    rep_txt = shlex.quote(f"{probe_root}/{root}/rep.txt")
    producer = {
        "type": "step",
        "id": "producer",
        "agent": "wf-coder",
        "modelId": model,
        "captureOutput": True,
        "artifacts": {"rep": "{{workdir}}/" + root + "/rep.txt"},
        "completion": {
            "fileCheck": {
                "path": "{{workdir}}/" + root + "/producer.json",
                "jsonPath": "done",
                "value": True,
            }
        },
        "prompt": (
            f"Run exactly once: bash {recorder} {target} producer {token}\n"
            f"Then write the single line {token} to the file {rep_txt}\n"
            f"Then reply with EXACTLY this and nothing else: {token}\n"
            "Do nothing else.\n" + NO_STEER
        ),
    }
    consumer = {
        "type": "step",
        "id": "consumer",
        "agent": "wf-coder",
        "modelId": model,
        "prompt": (
            "Run exactly once, substituting nothing yourself — pass these four "
            "arguments through literally as written:\n"
            f"bash {recorder} {target} consumer "
            "'{{previous.output}}' '{{producer.output}}' "
            "'{{steps.producer.output}}' '{{artifacts.rep}}'\n"
            "Report the output verbatim. Do not edit the command, do not "
            "expand or guess any placeholder, do not fix anything.\n" + NO_STEER
        ),
    }
    if effort:
        producer["effortLevel"] = effort
        consumer["effortLevel"] = effort
    return {
        "name": name,
        "description": (
            f"Launch with the workflow input `workdir` set to {probe_root} — the "
            "probe root this file was generated with. The step prompts hardcode "
            "that path, while the step artifacts map and the completion "
            "fileCheck interpolate the `workdir` input, so any other value makes "
            "this probe write to one directory and check another: the fileCheck "
            "never sees its file and the run fails as though the engine were at "
            "fault rather than the launch."
        ),
        "inputs": {"workdir": "path"},
        "steps": [{"type": "sequence", "id": "run", "steps": [producer, consumer]}],
    }


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    probe_root = sys.argv[1].rstrip("/")
    out_dir = Path(sys.argv[2] if len(sys.argv) > 2 else probe_root)
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, root, model, effort in (
        ("pC-refs-opus", "pC", "claude-opus-5", None),
        ("pD-refs-haiku-low", "pD", "claude-haiku-4.5", "low"),
    ):
        path = out_dir / f"{name}.workflow.json"
        path.write_text(
            json.dumps(workflow(probe_root, name, root, model, effort), indent=2) + "\n"
        )
        print(path)


if __name__ == "__main__":
    main()

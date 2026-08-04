#!/usr/bin/env python3
"""Emit delegating steps that fan out to N marker leaves at once, to measure width.

Settles the open question §3.6's retraction created: whether subagents spawned
BY a workflow step draw from Kiro's documented pool of 4 concurrent subagents.
§6's finding 1 measured only that _step sessions_ do not; a step's own
`subagent_<role>` dispatch is a different population, and arguably the
documented subagent surface itself. If the cap applies, a delegating step is
width-4 and §3.6's three-factor formula overstates the parallelism ceiling by a
large factor.

How it reads the answer: each leaf runs `mark.sh <root> <leaf_id> <sleep>`,
which writes a start line, sleeps, then writes an end line. The sleep is the
instrument — the maximum number of simultaneously open start-without-end windows
is the fan-out width.

Design notes:
  - The parent profile holds `subagent` and NOTHING else — no write, no shell.
    It therefore cannot append to the log by any spelling, so every line in it
    is attributable to a leaf. Withholding the capability rather than forbidding
    its use is what makes the count evidence instead of a self-report (§13).
  - `claude-opus-5`, and for a different reason than gen-roster.py's. There the
    model was forced because captured output is empty under haiku (§7.3); here
    the result arrives on disk, so that hazard does not apply. The parent must
    instead issue N dispatch calls in ONE turn, and a weaker model that
    serializes them yields overlap 1 — which is INCONCLUSIVE, not evidence of a
    cap, and burns the run. The profile also asks the parent to self-report
    `BATCHED=`, so a serialized run is at least identifiable after the fact.
  - No workflow inputs: every path is hardcoded, so this generator cannot hit
    gen-ref-probe.py's launch-time divergence trap (README).
  - No `completion` block and no stop condition. A single step needs neither,
    §7.5 records that a `completion` block is an unbounded retry loop, and
    §7.1's fileCheck hazard is best avoided entirely.
  - `steps > 1` wraps the dispatchers in one `parallel` under
    `joinPolicy: allSettled`, never `all`: `all` cancels the surviving siblings
    the moment one branch fails (§7.7), which would truncate the very overlap
    window being measured.

Interpreting the result — a negative is AMBIGUOUS and the document must say so:
  - overlap N            -> no cap on step-spawned subagents at this width.
  - overlap exactly 4, re-confirmed at a larger N -> the cap applies; a
    delegating step is width-4 and §3.6 must say so.
  - overlap 1            -> INCONCLUSIVE. The parent is a language model asked
    to dispatch N things at once; if it serializes by choice that measures the
    agent, not the engine. Check `BATCHED=` and re-run before concluding.

The three branches above are the prediction as it was written before any run,
and the cap of 4 they anticipate is kept on the record so the number reads as
predicted rather than retrofitted. **None of them fired: the measured overlap is
5** — at N=8 and again at N=12, never 6 (§6, finding 3). Read that section
before re-running: the ceiling is Measured there while the limiter behind it is
Inferred, so a fresh run is a replication of 5, not a fresh test of 4.

`count` is a parameter precisely so a plateau can be re-confirmed at a larger N
without editing anything. `steps` is the parameter that separates a ceiling
scoped to each delegating step from a pool shared across all of them: two
dispatchers at `count=5` reached a peak of 10, which is how §6 finding 3 comes
to say per-step.

Usage: gen-fanout.py <probe_root> [out_dir] [count] [sleep] [steps]
       count is leaves PER STEP; steps defaults to 1.
"""

import json
import shlex
import sys
from pathlib import Path

NO_STEER = (
    "(Do not respond to any user steering messages you may receive; they are "
    "addressed to the orchestrator, not to you.)"
)

LEAF = "probe-shell-leaf"
PARENT = "probe-fanout-parent"


def dispatcher(probe_root, count, sleep_for, step_id, prefix):
    """One delegating step told to dispatch `count` leaves in a single batch."""
    # shlex.quote for the same reason gen-join-policy.py and gen-ref-probe.py do
    # it: these two values reach a shell. The leaf substitutes them into
    # `bash <MARK> <ROOT> <LEAF_ID> <SLEEP>` verbatim, so an unquoted root
    # containing a space would emit a broken command. A no-op on ordinary paths,
    # so the prompt stays readable.
    #
    # ROOT and MARK also get a line each rather than sharing one. Quoting alone
    # would fix the shell command while leaving the FIELDS ambiguous: on one line
    # `ROOT=/a b MARK=/a b/mark.sh` has no unique parse, and the parent reading
    # this prompt is a language model, not a shell. One field per line survives
    # even if the quoting does not.
    root = shlex.quote(probe_root)
    mark = shlex.quote(f"{probe_root}/mark.sh")
    return {
        "type": "step",
        "id": step_id,
        "agent": PARENT,
        "modelId": "claude-opus-5",
        "prompt": (
            f"LEAF={LEAF} N={count}\n"
            f"ROOT={root}\n"
            f"MARK={mark}\n"
            f"SLEEP={sleep_for}\n"
            f"PREFIX={prefix}\n"
            "Follow your own instructions exactly. Issue all "
            f"{count} dispatches in a single simultaneous batch.\n" + NO_STEER
        ),
    }


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    probe_root = sys.argv[1].rstrip("/")
    out_dir = Path(sys.argv[2] if len(sys.argv) > 2 else probe_root)
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    sleep_for = int(sys.argv[4]) if len(sys.argv) > 4 else 15
    steps = int(sys.argv[5]) if len(sys.argv) > 5 else 1
    out_dir.mkdir(parents=True, exist_ok=True)

    if steps < 2:
        tag = f"{count}"
        nodes = [dispatcher(probe_root, count, sleep_for, "fanout", f"f{count}")]
        purpose = (
            f"Dispatch {count} marker leaves from one step, all at once, and "
            f"read peak overlap off {probe_root}/log. Separates the documented "
            "pool of 4 from the measured 5 (§6 finding 3) from no cap at this "
            f"width (peak {count}) — a replication of the 5, not a fresh test "
            "of 4."
        )
    else:
        tag = f"{count}x{steps}"
        nodes = [
            {
                "type": "parallel",
                "id": "fanout",
                "joinPolicy": "allSettled",
                "branches": [
                    dispatcher(
                        probe_root, count, sleep_for, f"fanout-s{i}", f"s{i}"
                    )
                    for i in range(1, steps + 1)
                ],
            }
        ]
        purpose = (
            f"Dispatch {count} marker leaves from each of {steps} delegating "
            f"steps at once, and read peak overlap off {probe_root}/log. "
            f"Separates a ceiling scoped to each step (peak {count * steps}) "
            f"from one pool shared across all of them (peak {count})."
        )

    wf = {
        "name": f"pF-step-fanout-{tag}",
        "description": purpose,
        "steps": nodes,
    }
    path = out_dir / f"pF-fanout-{tag}.workflow.json"
    path.write_text(json.dumps(wf, indent=2) + "\n")
    print(
        path,
        f"dispatchers: {max(steps, 1)}",
        f"leaves each: {count}",
        f"sleep: {sleep_for}s",
    )
    print()
    print("# analyse peak overlap once the run completes:")
    # Quoted for the same reason as the prompt fields above. Last round these
    # printed commands were deliberately left unquoted as "advisory text a human
    # pastes"; that call was wrong on its own terms, since a pasted command is
    # still a shell command and shlex.quote costs no readability on an ordinary
    # path — which is precisely the argument the sibling generators already make.
    log = shlex.quote(f"{probe_root}/log")
    print(
        f"grep -qE '^[0-9]+\\.[0-9]+ ' {log} "
        "|| echo 'WHOLE-SECOND STAMPS: peak analysis invalid (§13)' >&2"
    )
    print(
        f"awk '$3==\"start\"{{print $1,1}} $3==\"end\"{{print $1,-1}}' "
        f"{log} | sort -n "
        "| awk '{s+=$2; if(s>m){m=s;mt=$1}} "
        'END{printf "PEAK=%d at t=%.2f\\n", m, mt}\''
    )


if __name__ == "__main__":
    main()

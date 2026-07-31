#!/usr/bin/env python3
"""Fold a finished queue run and the engine's own node tree into one RUN.json.

This is the bridge that was missing. The harness had two halves that never met:
a synthetic queue that records what the SCHEDULER believes happened, and a
workflow engine that records what the RUNTIME believes happened. `verify.py`
evaluates EXPECT.md's predicates against a single `kiro-mode-f/run/1` document,
and nothing produced one, so P1-P4 had never been evaluated against a live run.

THE JOIN, which is the whole design:

  The queue attributes every claim to an OWNER -- a branch label like
  `branch-03` -- because that is all a worker knows about itself. A branch is
  not an execution, though: one branch runs a fresh step session per `repeat`
  iteration, so `branch-03` is a dozen different sessions over a run.

  `workflow-state.json` supplies the missing half. The engine persists the FULL
  per-iteration node tree with an absolute `startedAt`/`endedAt` and a
  `sessionId` on every step node. So a claim by `branch-03` at time T belongs to
  exactly the one `branch-03` step session whose window contains T.

  That join is not bookkeeping, it is the cross-check. The two sides are written
  by different processes with different notions of identity, and a claim that
  falls in NO window is a worker that acted outside any execution the engine
  recorded -- which is precisely the "work happened untracked" fault X1 exists to
  catch, in the only form it can take on this arm.

WHY `sessionDir` IS DELIBERATELY OMITTED FROM THE OUTPUT: `verify.py`'s X1
rebuilds its disk-side view from `sub_agent_start` rows, and a workflow run
emits none -- its steps are top-level sessions, not sub-executions (see
EXPECT.md). Declaring executions AND a sessionDir would make X1 diff a populated
edge set against an empty one and report every worker as dropped: a FAIL for a
correct run. Omitting `sessionDir` makes X1 report INCONCLUSIVE with the honest
reason, and the attribution check above is reported here instead.

Reads only. Writes only the file named by --out.
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path

# Queue outcomes that end a claim without ending the ITEM. Anything else is
# read from the item's own final state, because only the item knows whether the
# last attempt was the one that finished it.
NON_TERMINAL_OUTCOMES = frozenset({"abandoned", "failed", "violation"})


def iso_to_epoch(text):
    if not text:
        return None
    value = text.replace("Z", "+00:00")
    return datetime.fromisoformat(value).replace(tzinfo=timezone.utc).timestamp() \
        if datetime.fromisoformat(value).tzinfo is None \
        else datetime.fromisoformat(value).timestamp()


def read_json(path):
    with open(path) as fh:
        return json.load(fh)


def load_dir(root: Path, name):
    out = {}
    directory = root / name
    if not directory.is_dir():
        return out
    for path in sorted(directory.glob("*.json")):
        out[path.stem] = read_json(path)
    return out


def load_claims(root: Path):
    """{item_id: [claim record, ...]} ordered by generation."""
    claims = {}
    directory = root / "claims"
    if not directory.is_dir():
        return claims
    for item_dir in sorted(directory.iterdir()):
        if not item_dir.is_dir():
            continue
        records = [read_json(p) for p in sorted(item_dir.glob("*.json"))]
        claims[item_dir.name] = sorted(records, key=lambda r: r.get("gen", 0))
    return claims


def collect_executions(node, branch=None, out=None):
    """Flatten the engine's node tree to the step sessions it actually ran.

    The branch is the enclosing `repeat` node's id. It is carried down rather
    than read off the step, because the step node's own id is the same string
    on every branch -- the branch identity lives in the tree, not in a field.
    """
    if out is None:
        out = []
    node_type = node.get("type")
    node_id = node.get("nodeId")
    if node_type == "repeat":
        branch = node_id
    if node_type == "step" and node.get("sessionId"):
        out.append({
            "branch": branch,
            "endedAt": node.get("endedAt"),
            "ended_epoch": iso_to_epoch(node.get("endedAt")),
            "iteration": node.get("iteration"),
            "sessionId": node["sessionId"],
            "startedAt": node.get("startedAt"),
            "started_epoch": iso_to_epoch(node.get("startedAt")),
            "status": node.get("status"),
        })
    for child in node.get("children") or []:
        collect_executions(child, branch, out)
    return out


class Attributor:
    """Owner + timestamp -> the step session that was running then."""

    def __init__(self, executions):
        self.by_branch = {}
        for execution in executions:
            self.by_branch.setdefault(execution["branch"], []).append(execution)
        for rows in self.by_branch.values():
            rows.sort(key=lambda r: r["started_epoch"] or 0.0)
        self.unattributed = []

    def find(self, owner, when, what):
        for execution in self.by_branch.get(owner, []):
            start = execution["started_epoch"]
            end = execution["ended_epoch"]
            if start is None:
                continue
            # The end is inclusive and slightly generous: a worker's final write
            # can land microseconds after the engine stamps the node's end.
            if start <= when <= (end + 1.0 if end is not None else when):
                return execution["sessionId"]
        self.unattributed.append({"owner": owner, "at_epoch": when, "what": what})
        return f"unattributed:{owner}"


def build(queue_root: Path, workflow_dir: Path, runs_observed, notified):
    config = read_json(queue_root / "config.json")
    status = read_json(queue_root / "status.json")
    items = load_dir(queue_root, "items")
    results = load_dir(queue_root, "results")
    claims = load_claims(queue_root)
    events = [read_json(p) for p in sorted((queue_root / "events").glob("*.json"))]

    state = read_json(workflow_dir / "workflow-state.json")
    executions = collect_executions(state["root"])
    attribute = Attributor(executions)

    # An item dead-lettered at the admission gate was refused BEFORE it was ever
    # claimable, so it is not work the drain failed to do -- it is the depth cap
    # doing its job. Including it would hand verify.py a terminal state with no
    # claim behind it and manufacture an atomicity violation out of correct
    # behavior. It is counted and reported instead of being silently dropped.
    refused = sorted(
        i for i, item in items.items()
        if item.get("state") == "dead" and not claims.get(i)
    )
    tracked = {i: item for i, item in items.items() if i not in refused}

    proposed_by = {}
    for event in events:
        if event.get("kind") == "push.accepted":
            proposed_by[event["item"]] = event

    raw = []
    for item_id, item in sorted(tracked.items()):
        push = proposed_by.get(item_id)
        if push:
            session = attribute.find(push["owner"], push["at_epoch"], f"propose {item_id}")
            raw.append((push["at_epoch"], {
                "execution": session, "item": item_id, "kind": "propose", "session": session,
            }))

        generations = claims.get(item_id, [])
        final_state = item.get("state")
        for index, claim in enumerate(generations):
            owner = claim["owner"]
            acquired = claim["acquired_at_epoch"]
            session = attribute.find(owner, acquired, f"claim {item_id} gen{claim.get('gen')}")
            raw.append((acquired, {
                "execution": session, "item": item_id, "kind": "claim", "session": session,
            }))

            result = results.get(item_id)
            if result and result.get("gen") == claim.get("gen"):
                at = result["at_epoch"]
                worker = attribute.find(result["owner"], at, f"implement {item_id}")
                raw.append((at, {
                    "execution": worker, "item": item_id, "kind": "implement", "session": worker,
                }))

            released = claim.get("released_at_epoch")
            if released is None:
                # No release record: the claim was stolen or the holder died.
                # Emitting nothing is correct -- verify.py's dangling check is
                # exactly the right thing to trip.
                continue
            is_last = index == len(generations) - 1
            outcome = claim.get("outcome")
            if is_last and final_state == "done":
                kind = "done"
            elif is_last and final_state == "dead":
                kind = "failed"
            elif outcome in NON_TERMINAL_OUTCOMES or not is_last:
                kind = "release"
            else:
                kind = "release"
            raw.append((released, {
                "execution": session, "item": item_id, "kind": kind, "session": session,
            }))

    raw.sort(key=lambda pair: pair[0])
    ordered = []
    for seq, (_, event) in enumerate(raw, start=1):
        event["seq"] = seq
        ordered.append(event)

    terminal_states = {"dead", "done"}
    carried = sorted(i for i, item in tracked.items() if item.get("state") not in terminal_states)
    drained = bool(status.get("drained"))
    reason = "queue-drained" if drained and not carried else "budget-exhausted"

    run = {
        "carriedForward": carried,
        "events": ordered,
        "executions": [
            {"dispatchedBy": None, "id": e["sessionId"], "role": "implementer"}
            for e in executions
        ],
        "items": [
            {
                "id": item_id,
                "origin": "seed" if item.get("kind") == "seed" else "late",
                "parent": item.get("derived_from"),
            }
            for item_id, item in sorted(tracked.items())
        ],
        "notifications": {
            "runsObserved": runs_observed,
            "runsWithNotification": notified,
            "thisRun": 0,
        },
        "runId": state["workflowId"],
        "schema": "kiro-mode-f/run/1",
        "stampedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "termination": {"operatorIntervened": False, "reason": reason},
        # Not part of the schema verify.py reads; carried so the run file is
        # self-describing and the omissions above stay visible rather than
        # becoming a silent narrowing of the denominator.
        "_harness": {
            "attributionMisses": attribute.unattributed,
            "profile": config.get("profile"),
            "queueCounts": status.get("counts"),
            "refusedAtGate": refused,
            "sessionDirOmitted":
                "workflow steps are top-level sessions, not sub-executions, so "
                "verify.py's transcript-based X1 has no dispatch rows to diff "
                "against; see EXPECT.md",
            "stepExecutions": len(executions),
            "unitMs": config.get("unit_ms"),
            "leaseTtlSec": config.get("lease_ttl_sec"),
        },
    }
    return run, executions


def timing_report(executions, wall_sec):
    """The drain-versus-wave comparison, from the engine's own step windows."""
    per_iteration = {}
    total = 0.0
    for execution in executions:
        start, end = execution["started_epoch"], execution["ended_epoch"]
        if start is None or end is None:
            continue
        seconds = end - start
        total += seconds
        per_iteration.setdefault(execution["iteration"], []).append(seconds)
    wave = sum(max(v) for v in per_iteration.values()) if per_iteration else 0.0
    return {
        "serialSec": round(total, 1),
        "waveCounterfactualSec": round(wave, 1),
        "observedSec": round(wall_sec, 1) if wall_sec else None,
        "speedupVsSerial": round(total / wall_sec, 2) if wall_sec else None,
        "savedVsWavesPct": round(100 * (wave - wall_sec) / wave, 1) if wave and wall_sec else None,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--queue-root", required=True)
    ap.add_argument("--workflow-dir", required=True,
                    help="the run's directory under <home>/.kiro/sessions/<bucket>/workflows/")
    ap.add_argument("--drain-record", help="acp-drain.py --out JSON, for wall-clock")
    ap.add_argument("--runs-observed", type=int, default=1,
                    help="how many runs this history contains; F4 needs >= 2 to be measurable")
    ap.add_argument("--runs-notified", type=int, default=0)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    run, executions = build(Path(args.queue_root), Path(args.workflow_dir),
                            args.runs_observed, args.runs_notified)

    wall = None
    if args.drain_record and os.path.exists(args.drain_record):
        wall = read_json(args.drain_record).get("elapsed_sec")
    run["_harness"]["timing"] = timing_report(executions, wall)

    with open(args.out, "w") as fh:
        json.dump(run, fh, indent=2, sort_keys=True)

    misses = run["_harness"]["attributionMisses"]
    print(json.dumps({
        "attributionMisses": len(misses),
        "carriedForward": len(run["carriedForward"]),
        "events": len(run["events"]),
        "items": len(run["items"]),
        "refusedAtGate": run["_harness"]["refusedAtGate"],
        "stepExecutions": run["_harness"]["stepExecutions"],
        "termination": run["termination"]["reason"],
        "timing": run["_harness"]["timing"],
        "wrote": args.out,
    }, indent=2))
    if misses:
        print(f"\nWARNING: {len(misses)} queue action(s) fell outside every step-session "
              "window the engine recorded -- work happened untracked:")
        for miss in misses[:5]:
            print(f"  {miss}")


if __name__ == "__main__":
    main()

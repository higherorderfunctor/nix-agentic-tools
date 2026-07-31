#!/usr/bin/env python3
"""Run a workflow definition to completion over ACP, and record what happened.

This is the DRIVER the whole mode-F harness was built for. `acp-probe.py` proved
the workflow extension methods are reachable without a model; `acp-host.py`
proved the engine runs headless once the auth callback is answered. This one
composes the two and actually executes a run:

    _kiro/workflow/new  ->  _kiro/workflow/invoke  ->  poll _kiro/workflow/inspect

WHY IT IMPORTS `acp-host.py` RATHER THAN RESTATING THE AUTH DANCE: the token
contract has four ways to get it silently wrong (a falsy token, an unparseable
expiry, an expiry inside the engine's 3-minute buffer, and a missing profileArn
that fails at the SERVICE while presenting as an auth failure). One copy of that
reasoning is the only supportable number. The filename has a hyphen so it is not
importable by name — hence the explicit loader below rather than `import`.

THREE THINGS THAT ARE NOT OBVIOUS FROM THE METHOD NAMES:

1. `invoke` RETURNS IMMEDIATELY. The handler kicks the runner off with
   `void deps.runner.invoke(id).catch(...)` and answers with the status as it was
   *before* the run started -- which is `running` at best and `pending` at worst.
   Reading that response as the outcome is the obvious mistake; the run's result
   only ever arrives through `inspect` or through the lifecycle notifications.

2. `paused` IS NOT TERMINAL AND IS NOT RECOVERABLE HERE. The engine's terminal
   set is completed/failed/aborted. A run that pauses has not finished, and
   resuming it grants no further iterations, so this driver treats `paused` as a
   loud stall rather than an end state -- see PAUSED_IS_A_STALL below.

3. THE NOTIFICATIONS ARE THE MEASUREMENT, not the final state. `inspect` at the
   end tells you a drain finished; only the `loop_iteration` / `node_start`
   stream tells you whether branch 1 was on its 7th item while branch 2 was on
   its 2nd, which is the entire difference between a drain and a wave.

WRITES: only under the scratch HOME and the workspace it is given. It never
writes to the real ~/.kiro. It reads the operator's credential store through
acp-host.py's read-only handle and never prints a token.
"""

import argparse
import importlib.util
import json
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load_host_module():
    """Load `acp-host.py` as a module. Its name is not a valid identifier."""
    path = os.path.join(_HERE, "acp-host.py")
    spec = importlib.util.spec_from_file_location("acp_host", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


acp_host = _load_host_module()

# The engine's own terminal set (`isTerminalWorkflowStatus`). `paused` is
# deliberately absent: it is a state a run cannot be driven out of, because
# resuming grants no additional iterations and `retry` rejects anything that is
# not completed/failed/aborted.
TERMINAL_STATUSES = {"aborted", "completed", "failed"}
PAUSED_IS_A_STALL = "paused"


class DrainHost(acp_host.AcpHost):
    """An ACP host that also answers the requests a RUNNING agent makes.

    `acp-host.py` answers exactly one request (the token) because a single
    scripted turn needs nothing else. A workflow step is a full agent turn with
    tools, so it asks for permission before acting -- and an unanswered request
    does not fail, it BLOCKS, which presents as a workflow that hangs with no
    error anywhere. Every permission asked is recorded rather than merely
    granted: what a workflow step actually needs approved is a finding in its own
    right, and it is only observable from this side.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.permissions = []
        self.unanswered = []

    def _handle_request(self, msg):
        method = msg["method"]
        if method == "session/request_permission":
            params = msg.get("params") or {}
            options = params.get("options") or []
            tool = (params.get("toolCall") or {}).get("title") or \
                   (params.get("toolCall") or {}).get("kind")
            # Prefer a persistent allow so a K-branch drain does not re-ask once
            # per branch per iteration; fall back to a one-shot allow. Selecting
            # by `kind` rather than by position: the option order is the agent's,
            # and "the first option" has been a reject before.
            by_kind = {o.get("kind"): o for o in options if isinstance(o, dict)}
            chosen = by_kind.get("allow_always") or by_kind.get("allow_once")
            self.permissions.append({
                "t": time.monotonic() - self._t0,
                "tool": tool,
                "options": [o.get("kind") for o in options if isinstance(o, dict)],
                "chosen": (chosen or {}).get("kind"),
            })
            if chosen is None:
                # No allow option offered at all. Cancelling is the honest
                # answer; granting something arbitrary would corrupt the run.
                self._send({"jsonrpc": "2.0", "id": msg["id"],
                            "result": {"outcome": {"outcome": "cancelled"}}})
                return
            self._send({"jsonrpc": "2.0", "id": msg["id"], "result": {
                "outcome": {"outcome": "selected", "optionId": chosen.get("optionId")},
            }})
            return
        if method != "_kiro/auth/getAccessToken":
            # Record what we refused. A run that stalls after an unimplemented
            # request is diagnosable only if the request was written down.
            self.unanswered.append({"t": time.monotonic() - self._t0, "method": method})
        super()._handle_request(msg)

    def pump(self, seconds):
        """Drain the inbox for `seconds`, recording notifications.

        The base class only processes messages while awaiting a response id, so
        between two `inspect` polls the notification stream would sit unread and
        every event would take the receipt timestamp of the next poll. That would
        not change WHICH events arrived, but it would flatten their ORDER into
        poll-sized buckets -- destroying exactly the interleaving this run exists
        to measure.
        """
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                line = self.inbox.get(timeout=max(0.05, deadline - time.time()))
            except Exception:
                return
            if line is None:
                self.inbox.put(None)  # keep EOF visible to the next `_await`
                return
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "method" in msg and "id" in msg:
                self._handle_request(msg)
            elif "method" in msg:
                self.log.append({
                    "t": time.monotonic() - self._t0,
                    "method": msg["method"],
                    "params": msg.get("params"),
                })
            # A response to a call nobody is awaiting: the only calls this driver
            # makes are synchronous, so this is a late answer to a timed-out one.
            # Dropping it is correct; it is already reported as a timeout.


def summarize_nodes(node_plan):
    """Flatten the engine's node plan to (id, type, status, iterations)."""
    rows = []

    def walk(nodes, depth=0):
        for node in nodes or []:
            if not isinstance(node, dict):
                continue
            rows.append({
                "depth": depth,
                "id": node.get("id"),
                "type": node.get("type"),
                "status": node.get("status"),
                "iterations": node.get("iterations") or node.get("iteration"),
            })
            for key in ("branches", "steps", "children"):
                walk(node.get(key), depth + 1)

    walk(node_plan)
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--home", required=True, help="scratch HOME (the isolation lever)")
    ap.add_argument("--workspace", required=True, help="workspace root, absolute")
    ap.add_argument("--definition", required=True, help="path to a *.workflow.json")
    ap.add_argument("--input", action="append", default=[], metavar="K=V",
                    help="workflow input; repeatable. Values are strings by schema.")
    ap.add_argument("--parent-session", action="store_true",
                    help="create a chat session first and pass it as parentSessionId. "
                         "Without this a step's `send_message` has no parent to deliver "
                         "to, the step's captured output stays empty, and the run PAUSES "
                         "'awaiting next user message' with the work already done.")
    ap.add_argument("--poll-sec", type=float, default=5.0)
    ap.add_argument("--timeout-sec", type=float, default=1800.0)
    ap.add_argument("--out", help="write the full run record here as JSON")
    ap.add_argument("--keep", action="store_true",
                    help="do not delete the run afterwards (leaves state on disk)")
    args = ap.parse_args()

    workspace = os.path.abspath(args.workspace)
    if not os.path.isdir(workspace):
        raise SystemExit(f"workspace is not a directory: {workspace}")

    inputs = {}
    for pair in args.input:
        if "=" not in pair:
            raise SystemExit(f"--input must be K=V (got '{pair}')")
        key, value = pair.split("=", 1)
        inputs[key] = value

    with open(args.definition) as fh:
        definition = json.load(fh)

    token, expires_at, remaining = acp_host.read_token()
    floor = acp_host.REFRESH_BUFFER_SEC + acp_host.MIN_HEADROOM_SEC
    print(f"token: {len(token)} chars, expires {expires_at}, {remaining}s remaining")
    if remaining <= floor:
        raise SystemExit(
            f"REFUSING: {remaining}s of token left, under the {floor}s floor. This host does "
            "not refresh by design. Renew by using Kiro normally, then re-run."
        )
    # A run cannot outlive the token, and finding that out at minute 40 costs the
    # whole run. Say it up front instead.
    if remaining < args.timeout_sec:
        print(f"NOTE: token has {remaining}s but --timeout-sec is {int(args.timeout_sec)}s. "
              "A run that outlives the token fails at the auth callback, not here.")

    profile_arn = acp_host.read_profile_arn()
    if not profile_arn:
        print("WARNING: no profile ARN; the service rejects prompts without one")

    host = DrainHost(args.home, workspace, token, expires_at, profile_arn)
    record = {
        "definition": os.path.basename(args.definition),
        "inputs": inputs,
        "workspace": workspace,
        "home": args.home,
    }
    workflow_id = None
    started = time.monotonic()
    try:
        init = host.call("initialize", {
            "protocolVersion": 1,
            # Both false on purpose: with fs capabilities declared the agent asks
            # the CLIENT to read and write files, which would make this driver a
            # participant in the very file I/O the drain's stop condition reads.
            # Declining them keeps every write the engine's own, so the workspace
            # on disk is the engine's account of the run and not ours.
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}},
        })
        record["initialize_ok"] = "result" in init

        parent_session_id = None
        if args.parent_session:
            made = host.call("session/new", {"cwd": workspace, "mcpServers": []}, timeout=120)
            parent_session_id = (made.get("result") or {}).get("sessionId")
            record["parent_session"] = {"ok": "result" in made, "sessionId": parent_session_id}
            if parent_session_id is None:
                raise SystemExit(f"session/new failed: {json.dumps(made)[:800]}")
            print(f"parentSessionId: {parent_session_id}")

        new = host.call("_kiro/workflow/new", {
            "workspacePaths": [workspace],
            "workflow": definition,
            "inputs": inputs,
            **({"parentSessionId": parent_session_id} if parent_session_id else {}),
        }, timeout=120)
        record["new"] = new
        if "result" not in new:
            raise SystemExit(f"_kiro/workflow/new failed: {json.dumps(new)[:800]}")
        workflow_id = new["result"]["workflowId"]
        record["workflowId"] = workflow_id
        print(f"workflowId: {workflow_id}")

        invoked = host.call("_kiro/workflow/invoke", {"workflowId": workflow_id}, timeout=120)
        record["invoke"] = invoked
        # NOT the outcome -- see the module docstring. Recorded because a
        # non-`running` status here is a real signal that the run never started.
        print(f"invoke returned status: {(invoked.get('result') or {}).get('status')}")

        deadline = time.monotonic() + args.timeout_sec
        status = None
        last = None
        while time.monotonic() < deadline:
            host.pump(args.poll_sec)
            got = host.call("_kiro/workflow/inspect", {"workflowId": workflow_id}, timeout=60)
            if "result" not in got:
                record["inspect_error"] = got
                break
            last = got["result"]
            status = (last.get("state") or {}).get("status")
            elapsed = int(time.monotonic() - started)
            print(f"[{elapsed:5d}s] status={status} notifications={len(host.log)}")
            if status in TERMINAL_STATUSES:
                break
            if status == PAUSED_IS_A_STALL:
                print("PAUSED — not terminal and not recoverable: resuming grants no further "
                      "iterations and retry rejects a paused run. Stopping.")
                break
        else:
            print(f"TIMEOUT after {int(args.timeout_sec)}s with status={status}")
            record["timed_out"] = True

        record["final_status"] = status
        record["state"] = (last or {}).get("state")
        record["nodes"] = summarize_nodes((last or {}).get("nodePlan"))
        record["elapsed_sec"] = round(time.monotonic() - started, 2)
    finally:
        record["notifications"] = host.log
        record["permissions"] = host.permissions
        record["unanswered_requests"] = host.unanswered
        record["auth_callbacks_answered"] = host.auth_calls
        if workflow_id and not args.keep:
            if record.get("final_status") not in TERMINAL_STATUSES:
                # Leave nothing running against the scratch home after we detach.
                host.call("_kiro/workflow/cancel", {"workflowId": workflow_id}, timeout=30)
        record["stderr_tail"] = host.errors[-12:]
        host.close()

    if args.out:
        with open(args.out, "w") as fh:
            json.dump(record, fh, indent=2, sort_keys=True, default=str)
        print(f"wrote {args.out}")

    print(json.dumps({
        "final_status": record.get("final_status"),
        "elapsed_sec": record.get("elapsed_sec"),
        "notifications": len(record.get("notifications") or []),
        "permissions_asked": len(record.get("permissions") or []),
        "unanswered_requests": record.get("unanswered_requests"),
        "auth_callbacks_answered": record.get("auth_callbacks_answered"),
    }, indent=2))

    sys.exit(0 if record.get("final_status") == "completed" else 1)


if __name__ == "__main__":
    main()

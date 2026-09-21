#!/usr/bin/env python3
"""Run the same update targets in isolated CI jobs and collect sweep receipts."""

import argparse
import json
import os
import re
import subprocess
from pathlib import Path


def discover(lock, targets, requested=""):
    inputs = lock["nodes"][lock["root"]]["inputs"]
    if set(inputs) & set(targets):
        raise ValueError("input and package update branch names collide")
    rows = [{"kind": "input", "name": name} for name in sorted(inputs)]
    rows += [{"kind": "package", "name": name, **config} for name, config in sorted(targets.items())]
    if any(not re.fullmatch(r"[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*", row["name"]) for row in rows):
        raise ValueError("unexpected update target name")
    if requested:
        names = requested.split(",")
        if len(set(names)) != len(names) or set(names) - {row["name"] for row in rows}:
            raise ValueError("unknown or duplicate requested update targets")
        rows = [row for row in rows if row["name"] in names]
    if not rows or len(rows) > 256:
        raise ValueError("update matrix must contain between 1 and 256 targets")
    return {"include": rows}


def report_status(report, name):
    lines = report.splitlines()
    matches = [re.fullmatch(r"(UPDATED|NO UPDATES|HELD BACK): " + re.escape(name) + r"(?: \|.*| \(.*\))?", line) for line in lines]
    if len(lines) != 1 or not matches[0]:
        raise ValueError(f"missing or ambiguous completion report for {name}")
    return matches[0][1]


# A HELD BACK target preserves its branch and leaves the sweep GREEN on
# purpose: no new PR or branch update could be WRITTEN for the attempt, so
# branch CI has nothing to judge for it, and preserving whatever PR already
# exists is correct. What is not correct is that the condition then repeats
# every six hours with nobody told.
#
# `docs/update-ci-operations.md` has instructed a human to go read receipt
# statuses since 2026-09-14 (commit b8653e57). Two days later oxlint was held
# back on three consecutive sweeps -- 06:32Z, 12:28Z and 18:21Z on 2026-09-16,
# every one of those runs green -- and nobody read them. Documentation lost, so
# this is a gate.
#
# TWO sweeps, not one: a single hold-back is routinely transient (an upstream
# fetch blip, a substituter timeout) and re-running it six hours later is
# cheaper than interrupting someone. Two in a row means the condition is
# structural and only a person can clear it.
HOLD_BACK_SWEEPS_BEFORE_ESCALATION = 2

# Cap on the preparation-log excerpt carried into an annotation. The excerpt is
# a convenience, never the gate: escalation fires on receipt status alone, so a
# missed or malformed excerpt degrades to the artifact pointer instead of
# turning the gate off. Keeping it bounded stops an annotation becoming a log
# dump.
REASON_MAX_LINES = 12

# nix renders a failed builder's output as `> `-prefixed lines under a
# "Last N log lines:" banner, and that block is where a package's own guard
# says what a human must do -- e.g. oxlint's "catalog no longer pins
# @napi-rs/cli at 3.9.1 - bump napi.version and regenerate the patch". The
# plain tail of the log is useless here: it ends on the generic
# "HELD BACK: <name> (nix-update, formatter or commit failed)" line, ~20 lines
# after the sentence that actually names the blocker.
BUILDER_OUTPUT = re.compile(r"^\s*> ?(.*)$")


def held_back_reason(log):
    """Best-effort excerpt naming why a target was held back.

    Returns the last block of builder output in `log`, newest block only,
    trimmed to REASON_MAX_LINES. Returns None when the log carries no builder
    output, which is a normal outcome -- the caller still reports the hold-back
    and points at the full artifact.
    """
    blocks, current = [], []
    for line in log.splitlines():
        match = BUILDER_OUTPUT.match(line)
        if match:
            current.append(match[1].rstrip())
        elif current:
            blocks.append(current)
            current = []
    if current:
        blocks.append(current)
    lines = [line for line in (blocks[-1] if blocks else []) if line.strip()]
    return "\n".join(lines[-REASON_MAX_LINES:]) or None


def escalation(held_back, previous):
    """Split this sweep's held-back targets into repeats and first offenses.

    `held_back` maps target name -> its one-line completion report. `previous`
    maps those names -> the same target's status in the most recent earlier
    sweep that has a receipt for it, or None when none could be read.

    An unreadable predecessor never escalates. A first-ever hold-back, and one
    whose predecessor's artifact has aged out, must not be indistinguishable
    from a repeat -- erring toward silence there leaves today's behavior,
    while erring the other way pages someone for a transient blip.
    """
    repeated = sorted(n for n in held_back if previous.get(n) == "HELD BACK")
    fresh = sorted(n for n in held_back if n not in set(repeated))
    return repeated, fresh


def gh(*args, required=True):
    """Run `gh` and return stdout; None when it fails and the caller tolerates it.

    Artifact downloads are expected to fail routinely -- a sweep older than the
    90-day retention, a target that did not exist yet -- so those callers pass
    required=False. The run listing is not optional: silently treating an API
    outage as "no previous sweep" would turn the gate off exactly when it is
    hardest to notice.
    """
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        if required:
            raise RuntimeError(f"gh {' '.join(args)} failed: {result.stderr.strip()}")
        return None
    return result.stdout


def previous_sweep(repo, current_run_id):
    """The scheduled Update run immediately before this one, or None.

    Only SCHEDULED runs count. A workflow_dispatch sweep may carry an explicit
    target subset, so its receipts cover only those targets; treating one as the
    predecessor would read "this target was not in that sweep" as "not held
    back" and silently reset the count.

    Conclusion is deliberately NOT filtered. Once this gate fires the failing
    sweep is the predecessor the next one must compare against, and skipping it
    would reset the count every other sweep and never escalate twice running.
    """
    listing = gh("api", f"repos/{repo}/actions/workflows/update.yml/runs?status=completed&event=schedule&per_page=5")
    earlier = [run for run in json.loads(listing)["workflow_runs"] if str(run["id"]) != str(current_run_id)]
    return earlier[0] if earlier else None


def previous_status(repo, run, name, workspace):
    """`name`'s status in that one sweep: (status, run_url), status None if unreadable.

    ONLY the immediate predecessor is consulted. An earlier version walked back
    to the newest sweep that happened to carry a receipt, which would let a gap
    turn two NON-consecutive hold-backs into an escalation -- precisely what the
    two-sweep threshold exists to prevent.
    """
    if run is None:
        return None, None
    destination = workspace / f"previous-{run['id']}-{name}"
    if gh("run", "download", str(run["id"]), "--repo", repo, "--name", f"update-receipt-{name}", "--dir", str(destination), required=False) is None:
        return None, run["html_url"]
    try:
        receipt = json.loads((destination / "update-receipt.json").read_text())
    except (OSError, ValueError):
        return None, run["html_url"]
    # Well-formed JSON of the wrong SHAPE is unreadable, not authoritative: a
    # bare `[]` would raise AttributeError on .get and abort the cleanup job
    # rather than decline to escalate. The name must match too, so a
    # mis-attached artifact cannot answer for a different target.
    if not isinstance(receipt, dict) or receipt.get("name") != name:
        return None, run["html_url"]
    return receipt.get("status"), run["html_url"]


def preparation_reason(repo, run_id, name, workspace):
    """Excerpt from this sweep's own preparation log, or None."""
    destination = workspace / f"report-{name}"
    if gh("run", "download", str(run_id), "--repo", repo, "--name", f"update-report-{name}", "--dir", str(destination), required=False) is None:
        return None
    logs = sorted(destination.rglob("prepare.log"))
    if not logs:
        return None
    try:
        return held_back_reason(logs[0].read_text(errors="replace"))
    except OSError:
        return None


def collect(matrix, receipts, base):
    expected = sorted(row["name"] for row in matrix["include"])
    if sorted(r["name"] for r in receipts) != expected:
        raise ValueError("missing, duplicate, or unexpected update receipts")
    touched = []
    for receipt in receipts:
        if receipt["base"] != base or receipt["status"] not in {"UPDATED", "NO UPDATES", "HELD BACK"}:
            raise ValueError("receipt from another base or incomplete preparation")
        branch = "update/" + receipt["name"]
        if receipt["touched"] not in ([], [branch]):
            raise ValueError("receipt contains another target's branch")
        if receipt["status"] in {"UPDATED", "HELD BACK"} and receipt["touched"] != [branch]:
            raise ValueError("changed or held-back target must preserve its PR")
        touched.extend(receipt["touched"])
    return sorted(touched)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["discover", "prepare", "receipt", "collect", "escalate"])
    args = parser.parse_args()
    temp = Path(os.environ["RUNNER_TEMP"])
    if args.command == "discover":
        matrix = discover(json.loads(Path("flake.lock").read_text()), json.loads((temp / "targets.json").read_text()), os.environ.get("REQUESTED_TARGETS", ""))
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("matrix=" + json.dumps(matrix, separators=(",", ":")) + "\n")
        print(json.dumps(matrix, indent=2))
    elif args.command == "prepare":
        target = json.loads(os.environ["UPDATE_TARGET_JSON"])
        scripts = Path(__file__).resolve().parent
        subprocess.run(["bash", str(scripts / "update-init.sh")], check=True)
        command = ["bash", str(scripts / f"update-{'pkg' if target['kind'] == 'package' else 'input'}.sh"), target["name"]]
        if target["kind"] == "package":
            command.extend(target["flags"])
            if target["git"]:
                command.append(target["git"])
        subprocess.run(command, check=True)
        # An early phase-0 commit is not proof that hashes/extraction completed.
        # Only a normal target return with its final report permits publication.
        report = Path(".update-report.txt").read_text()
        status = report_status(report, target["name"])
        # `detail` is the whole completion line, including the parenthetical
        # reason category. The escalation gate quotes it so an annotation says
        # what happened without downloading anything.
        (temp / "prepared.json").write_text(json.dumps({"base": os.environ["UPDATE_BASE_SHA"], "detail": report.strip(), "name": target["name"], "status": status}))
    elif args.command == "receipt":
        receipt = json.loads((temp / "prepared.json").read_text())
        receipt["touched"] = (temp / "touched-branches").read_text().splitlines()
        (temp / "update-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    elif args.command == "escalate":
        repo, run_id = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_RUN_ID"]
        receipts = [json.loads(p.read_text()) for p in Path("receipts").glob("*/update-receipt.json")]
        held = {r["name"]: r.get("detail") or f"HELD BACK: {r['name']}" for r in receipts if r["status"] == "HELD BACK"}
        if not held:
            print("No target was held back this sweep.")
            return
        # Only pay for the API when something is actually held back.
        previous = previous_sweep(repo, run_id)
        seen = {name: previous_status(repo, previous, name, temp) for name in held}
        repeated, fresh = escalation(held, {name: status for name, (status, _) in seen.items()})
        for name in fresh:
            print(f"::warning title=Update target held back::{held[name]} | first sweep in a row; a repeat next sweep fails this job.")
        for name in repeated:
            lines = [
                held[name],
                f"Held back on {HOLD_BACK_SWEEPS_BEFORE_ESCALATION} consecutive sweeps. Preparation failed, so no",
                "new PR or branch update was written for this attempt and branch CI has nothing to",
                "judge for it -- any update PR still open is an EARLIER proposal, not this one.",
                "It cannot clear itself; a person has to unblock preparation.",
                f"Previous sweep: {seen[name][1]}",
            ]
            reason = preparation_reason(repo, run_id, name, temp)
            if reason:
                lines.append("Preparation failed with:")
                lines.extend("  " + line for line in reason.splitlines())
            else:
                lines.append(f"Full log: gh run download {run_id} --repo {repo} --name update-report-{name}")
            print("::error title=Update target held back twice::" + "%0A".join(lines))
        if repeated:
            raise SystemExit(f"Held back on consecutive sweeps: {', '.join(repeated)}")
    else:
        matrix = json.loads(os.environ["UPDATE_MATRIX"])
        receipts = [json.loads(p.read_text()) for p in Path("receipts").glob("*/update-receipt.json")]
        touched = collect(matrix, receipts, os.environ["UPDATE_BASE_SHA"])
        (temp / "touched-branches").write_text("".join(branch + "\n" for branch in touched))
        # Cleanup refuses to act without proof of a complete, published sweep.
        (temp / "update-completed.flag").touch()


if __name__ == "__main__":
    main()

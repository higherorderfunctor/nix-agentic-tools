#!/usr/bin/env python3
"""Run the same update targets in isolated CI jobs and collect sweep receipts."""

import argparse
import json
import os
import re
import subprocess
import time
from pathlib import Path


def discover(lock, targets, requested=""):
    inputs = lock["nodes"][lock["root"]]["inputs"]
    if set(inputs) & set(targets):
        raise ValueError("input and package update branch names collide")
    rows = [{"kind": "input", "name": name} for name in sorted(inputs)]
    rows += [{"kind": "package", "name": name, **config} for name, config in sorted(targets.items())]
    if any(not re.fullmatch(r"[a-zA-Z0-9_-]+", row["name"]) for row in rows):
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

# A failure OUTSIDE any nix build has no builder block -- kimchi-docs' updateScript
# failing with "Permission denied" before nix-update's traceback is one. The
# fallback is the tail of the log with the lines that never name a cause removed:
# colour codes, the pipeline's own report line (the annotation already quotes it),
# git's worktree reset, and Python traceback frames, of which only the exception
# line itself is kept.
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
PIPELINE_BOOKKEEPING = re.compile(r"^\W*(?:(?:UPDATED|NO UPDATES|HELD BACK): |HEAD is now at )")
TRACEBACK_START = "Traceback (most recent call last):"

# A nix-update command line can run to kilobytes. Keep both ends: the start
# names the command, the end carries e.g. "returned non-zero exit status 126".
REASON_MAX_LINE_CHARS = 240


def shorten(line):
    if len(line) <= REASON_MAX_LINE_CHARS:
        return line
    half = (REASON_MAX_LINE_CHARS - 5) // 2
    return f"{line[:half]} ... {line[-half:]}"


def builder_block(lines):
    """The newest contiguous block of builder output, prefix stripped."""
    blocks, current = [], []
    for line in lines:
        match = BUILDER_OUTPUT.match(line)
        if match:
            current.append(match[1])
        elif current:
            blocks.append(current)
            current = []
    if current:
        blocks.append(current)
    return blocks[-1] if blocks else []


def failure_tail(lines):
    """The log's lines minus the ones that never name a cause, oldest first."""
    kept, in_traceback = [], False
    for line in lines:
        if line.startswith(TRACEBACK_START):
            in_traceback = True
            continue
        # Frames are indented; the first unindented line is the exception.
        if in_traceback and (not line or line[0].isspace()):
            continue
        in_traceback = False
        if not PIPELINE_BOOKKEEPING.match(line):
            kept.append(line)
    return kept


def held_back_reason(log):
    """Excerpt naming why a target was held back, or None for an empty log.

    Prefers the newest block of builder output. A log with no builder output
    falls back to failure_tail(), so a failure outside any nix build still
    names its cause. Either way the excerpt is trimmed to REASON_MAX_LINES
    non-blank lines of at most REASON_MAX_LINE_CHARS each.
    """
    lines = [ANSI_ESCAPE.sub("", line).rstrip() for line in log.splitlines()]
    chosen = [line for line in (builder_block(lines) or failure_tail(lines)) if line.strip()]
    return "\n".join(shorten(line) for line in chosen[-REASON_MAX_LINES:]) or None


# previous_status() result for a receipt that EXISTS but could not be read.
UNREADABLE = "UNREADABLE"


def escalation(held_back, previous):
    """Split this sweep's held-back targets: (repeated, unreadable, fresh).

    `held_back` maps target name -> its one-line completion report. `previous`
    maps those names -> the same target's status in the immediately preceding
    scheduled sweep: that receipt's status, None when that sweep has no receipt
    for the target, or UNREADABLE when it has one that could not be read.

    Only an ABSENT receipt makes a first offense -- a first-ever hold-back, a
    target new to the registry. An unreadable one is not evidence of a clean
    predecessor. Counting it as one resets the consecutive-hold counter, and a
    transient artifact failure then turns a repeat into a green sweep. Unreadable
    targets therefore fail the job under their own name: the operator is told
    the count is unknown, never that it is one.
    """
    repeated = sorted(n for n in held_back if previous.get(n) == "HELD BACK")
    unreadable = sorted(n for n in held_back if previous.get(n) == UNREADABLE)
    fresh = sorted(n for n in held_back if n not in set(repeated) | set(unreadable))
    return repeated, unreadable, fresh


# Reads of the previous sweep are the hold-back counter's only memory, so one
# transient API failure must not decide the outcome. Every call retries with a
# linear backoff before it is allowed to fail.
GH_ATTEMPTS = 3
GH_RETRY_DELAY_SECONDS = 5


class GhError(RuntimeError):
    """`gh` still failed after GH_ATTEMPTS tries; the message carries its stderr."""


def gh(*args):
    """Run `gh` and return stdout, retrying; raise GhError if every attempt fails.

    There is no tolerated-failure mode. A caller that can proceed without the
    answer catches GhError and must say what it lost: silently reading an API
    outage as "no previous sweep" or "not held back" turns the gate off exactly
    when it is hardest to notice.
    """
    for attempt in range(1, GH_ATTEMPTS + 1):
        result = subprocess.run(["gh", *args], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout
        if attempt < GH_ATTEMPTS:
            time.sleep(GH_RETRY_DELAY_SECONDS * attempt)
    raise GhError(f"gh {' '.join(args)} failed after {GH_ATTEMPTS} attempts: {result.stderr.strip()}")


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
    """`name`'s status in that one sweep: (status, run_url, note).

    status is the receipt's own status, None when that sweep has no unexpired
    receipt artifact for `name`, or UNREADABLE when it has one that could not be
    listed, downloaded or parsed. note says why whenever status is not a
    receipt's own, so neither outcome passes silently.

    Existence is asked separately from the download on purpose: a failed
    download alone cannot tell "no receipt" from "receipt we failed to read",
    and only the first may count as a first offense.

    ONLY the immediate predecessor is consulted. An earlier version walked back
    to the newest sweep that happened to carry a receipt, which would let a gap
    turn two NON-consecutive hold-backs into an escalation -- precisely what the
    two-sweep threshold exists to prevent.
    """
    if run is None:
        return None, None, "there is no earlier scheduled sweep"
    url, artifact = run["html_url"], f"update-receipt-{name}"
    try:
        listing = json.loads(gh("api", f"repos/{repo}/actions/runs/{run['id']}/artifacts?name={artifact}"))
        live = [a for a in listing["artifacts"] if a["name"] == artifact and not a["expired"]]
    except (GhError, KeyError, TypeError, ValueError) as error:
        return UNREADABLE, url, f"could not list its {artifact} artifact: {error}"
    if not live:
        return None, url, f"that sweep has no unexpired {artifact} artifact"
    destination = workspace / f"previous-{run['id']}-{name}"
    try:
        gh("run", "download", str(run["id"]), "--repo", repo, "--name", artifact, "--dir", str(destination))
        receipt = json.loads((destination / "update-receipt.json").read_text())
    except (GhError, OSError, ValueError) as error:
        return UNREADABLE, url, f"its {artifact} artifact exists but could not be read: {error}"
    # Well-formed JSON of the wrong SHAPE is unreadable too: a bare `[]` would
    # raise AttributeError on .get and abort the cleanup job. The name must
    # match, so a mis-attached artifact cannot answer for a different target.
    if not isinstance(receipt, dict) or receipt.get("name") != name or not isinstance(receipt.get("status"), str):
        return UNREADABLE, url, f"its {artifact} artifact is not a receipt for {name}"
    return receipt["status"], url, None


def preparation_reason(repo, run_id, name, workspace):
    """(excerpt, None) from this sweep's own preparation log, or (None, why not)."""
    destination = workspace / f"report-{name}"
    try:
        gh("run", "download", str(run_id), "--repo", repo, "--name", f"update-report-{name}", "--dir", str(destination))
        logs = sorted(destination.rglob("prepare.log"))
        excerpt = held_back_reason(logs[0].read_text(errors="replace")) if logs else None
    except (GhError, OSError) as error:
        return None, f"could not read update-report-{name}: {error}"
    if not logs:
        return None, f"update-report-{name} carries no prepare.log"
    return (excerpt, None) if excerpt else (None, "prepare.log is empty")


def annotate(level, title, lines):
    """Print one workflow-command annotation, escaping per GitHub's rules.

    A note can carry gh's multi-line stderr; an unescaped newline would end the
    annotation there and print the rest as plain log text.
    """
    message = "\n".join(lines).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::{level} title={title}::{message}")


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
        repeated, unreadable, fresh = escalation(held, {name: status for name, (status, _, _) in seen.items()})

        def predecessor(name):
            status, url, note = seen[name]
            return f"Previous sweep: {url or 'none'} ({note or status})"

        def reason(name):
            excerpt, missing = preparation_reason(repo, run_id, name, temp)
            lines = ["Preparation failed with:", *("  " + line for line in excerpt.splitlines())] if excerpt else [f"Preparation log excerpt unavailable: {missing}."]
            return [*lines, f"Full log: gh run download {run_id} --repo {repo} --name update-report-{name}"]

        for name in fresh:
            annotate("warning", "Update target held back", [f"{held[name]} | first sweep in a row; a repeat next sweep fails this job.", predecessor(name)])
        failing = (
            ("Update target held back twice", "Held back on consecutive sweeps", repeated, [
                f"Held back on {HOLD_BACK_SWEEPS_BEFORE_ESCALATION} consecutive sweeps. Preparation failed, so no",
                "new PR or branch update was written for this attempt and branch CI has nothing to",
                "judge for it -- any update PR still open is an EARLIER proposal, not this one.",
                "It cannot clear itself; a person has to unblock preparation.",
            ]),
            ("Update hold-back count unknown", "Held back with an unreadable predecessor receipt", unreadable, [
                "Held back, and the previous sweep's receipt for this target could not be read, so",
                "whether this is a first or a repeated hold-back is unknown. Counting it as a first",
                "would silently reset the consecutive-hold counter, so this job fails instead.",
            ]),
        )
        for title, _, names, explanation in failing:
            for name in names:
                annotate("error", title, [held[name], *explanation, predecessor(name), *reason(name)])
        failures = [f"{summary}: {', '.join(names)}" for _, summary, names, _ in failing if names]
        if failures:
            raise SystemExit("; ".join(failures))
    else:
        matrix = json.loads(os.environ["UPDATE_MATRIX"])
        receipts = [json.loads(p.read_text()) for p in Path("receipts").glob("*/update-receipt.json")]
        touched = collect(matrix, receipts, os.environ["UPDATE_BASE_SHA"])
        (temp / "touched-branches").write_text("".join(branch + "\n" for branch in touched))
        # Cleanup refuses to act without proof of a complete, published sweep.
        (temp / "update-completed.flag").touch()


if __name__ == "__main__":
    main()

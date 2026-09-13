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
    parser.add_argument("command", choices=["discover", "prepare", "receipt", "collect"])
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
        status = report_status(Path(".update-report.txt").read_text(), target["name"])
        (temp / "prepared.json").write_text(json.dumps({"base": os.environ["UPDATE_BASE_SHA"], "name": target["name"], "status": status}))
    elif args.command == "receipt":
        receipt = json.loads((temp / "prepared.json").read_text())
        receipt["touched"] = (temp / "touched-branches").read_text().splitlines()
        (temp / "update-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    else:
        matrix = json.loads(os.environ["UPDATE_MATRIX"])
        receipts = [json.loads(p.read_text()) for p in Path("receipts").glob("*/update-receipt.json")]
        touched = collect(matrix, receipts, os.environ["UPDATE_BASE_SHA"])
        (temp / "touched-branches").write_text("".join(branch + "\n" for branch in touched))
        # Cleanup refuses to act without proof of a complete, published sweep.
        (temp / "update-completed.flag").touch()


if __name__ == "__main__":
    main()

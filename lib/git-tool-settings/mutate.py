#!/usr/bin/env python3
"""Prove an extractor fails closed: run it over mutated copies of the source.

Shared by every git-tool census (packages/git-*/extract/extract.py). Each
mutant makes one upstream-shaped change to a copy of the source tree and
states what the extractor must do with it:

  fails    guard codes that must all appear, with a non-zero exit
  adds     settings keys that must appear, with exit 0 and nothing lost
  changes  {key: {field: value}} a setting or foreign key must carry, exit 0
  deadKeysAdd, revsetFunctionsAdd
           dead keys or builtin revset names that must appear, with exit 0
  (none)   exit 0 and an output identical to the baseline

What a person must then write about a new name (a type, a description, a
dead key's reason) is lib/git-tool-settings/rules.nix's to demand, not the
extractor's; checks/git-tool-settings/rules.nix holds those cases.

A mutant whose edit does not apply is itself a failure, so a source change
that retires a mutant's anchor surfaces here instead of passing vacuously.
The extractor is run as `python3 <extractor> --src --out`, with this
process's environment (PYTHONPATH included).
"""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
for flag in ("baseline", "extractor", "mutants", "src"):
    parser.add_argument(f"--{flag}", type=Path, required=True)
args = parser.parse_args()

baseline = json.loads(args.baseline.read_text())
problems = []


def run(mutant, work):
    src = work / "src"
    shutil.copytree(args.src, src)
    for path in [src, *src.rglob("*")]:
        path.chmod(0o755 if path.is_dir() else 0o644)
    for edit in mutant.get("edits", []):
        target = src / edit["file"]
        text = target.read_text()
        if "append" in edit:
            new = text + edit["append"]
        else:
            if text.count(edit["from"]) != 1:
                return None, f"edit anchor matches {text.count(edit['from'])} times in {edit['file']}: {edit['from']!r}"
            new = text.replace(edit["from"], edit["to"])
        target.write_text(new)
    out = work / "out.json"
    result = subprocess.run([sys.executable, str(args.extractor), "--src", str(src), "--out", str(out)],
                            capture_output=True, text=True)
    return (result.returncode, result.stderr, json.loads(out.read_text()) if out.exists() else None), None


def field(out, key, name):
    return {**out["foreign"], **out["settings"]}.get(key, {}).get(name)


for mutant in json.loads(args.mutants.read_text()):
    name = mutant["name"]
    with tempfile.TemporaryDirectory() as tmp:
        outcome, error = run(mutant, Path(tmp))
    if error:
        problems.append(f"{name}: {error}")
        continue
    rc, stderr, out = outcome
    guards = sorted({line.split(":")[0].removeprefix("FAIL ") for line in stderr.splitlines() if line.startswith("FAIL ")})
    summary = f"{name}: exit={rc} guards={','.join(guards) or '-'}"
    if "fails" in mutant:
        missing = sorted(set(mutant["fails"]) - set(guards))
        if rc == 0 or missing:
            problems.append(f"{summary}; expected failure with {mutant['fails']}, missing {missing}\n{stderr}")
            continue
    else:
        if rc != 0 or out is None:
            problems.append(f"{summary}; expected exit 0\n{stderr}")
            continue
        added = sorted(set(out["settings"]) - set(baseline["settings"]))
        lost = sorted(set(baseline["settings"]) - set(out["settings"]))
        if added != sorted(mutant.get("adds", [])) or lost:
            problems.append(f"{summary}; added {added} (expected {mutant.get('adds', [])}), lost {lost}")
            continue
        moved = {section: sorted(set(out.get(section, [])) ^ set(baseline.get(section, [])))
                 for section in ("deadKeys", "revsetFunctions")}
        unexpected = {section: names for section, names in moved.items()
                      if names != sorted(mutant.get(f"{section}Add", []))}
        if unexpected:
            problems.append(f"{summary}; {unexpected} moved, not as its <section>Add lists")
            continue
        wrong = {f"{k}.{f}": field(out, k, f) for k, fields in mutant.get("changes", {}).items()
                 for f, v in fields.items() if field(out, k, f) != v}
        if wrong:
            problems.append(f"{summary}; expected changes {mutant['changes']}, got {wrong}")
            continue
        if not any(mutant.get(k) for k in ("adds", "changes", "deadKeysAdd", "revsetFunctionsAdd")) and out != baseline:
            problems.append(f"{summary}; expected the baseline output unchanged")
            continue
        summary += f" added={','.join(added) or '-'}"
    print("ok", summary)

for p in problems:
    print("FAIL", p, file=sys.stderr)
sys.exit(1 if problems else 0)

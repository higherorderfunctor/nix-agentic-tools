#!/usr/bin/env python3
"""Prove the extractor fails closed: run it over mutated copies of the source.

Each mutant makes one upstream-shaped change to a copy of the patched source
(or to the annotations) and states what the extractor must do with it:

  fails    guard codes that must all appear, with a non-zero exit
  adds     settings keys that must appear, with exit 0 and nothing lost
  changes  {key: {field: value}} the output must carry, with exit 0
  revsetFunctionsAdd  builtin revset names that must appear, with exit 0
  (none)   exit 0 and an output identical to the baseline

A mutant whose edit does not apply is itself a failure, so a source change
that retires a mutant's anchor surfaces here instead of passing vacuously.
"""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
for flag in ("annotations", "ast-grep", "baseline", "extractor", "mutants", "rules", "src"):
    parser.add_argument(f"--{flag}", type=Path, required=True)
args = parser.parse_args()

baseline = json.loads(args.baseline.read_text())
annotations = json.loads(args.annotations.read_text())
problems = []


def deep_merge(base, patch):
    out = dict(base)
    for k, v in patch.items():
        out[k] = deep_merge(out.get(k, {}), v) if isinstance(v, dict) else v
    return out


def run(mutant, work):
    src = work / "src"
    shutil.copytree(args.src, src)
    src.chmod(0o755)
    for path in src.rglob("*"):
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
    ann = work / "annotations.json"
    ann.write_text(json.dumps(deep_merge(annotations, mutant.get("annotations", {}))))
    matches = work / "matches.jsonl"
    with matches.open("w") as out:
        subprocess.run([str(args.ast_grep), "scan", "--rule", str(args.rules), "--json=stream", "."],
                       cwd=src, stdout=out, check=True)
    result = subprocess.run([sys.executable, str(args.extractor), "--src", str(src), "--matches", str(matches),
                             "--annotations", str(ann), "--out", str(work / "out.json")],
                            capture_output=True, text=True)
    out_json = json.loads((work / "out.json").read_text()) if (work / "out.json").exists() else None
    return (result.returncode, result.stderr, out_json), None


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
            problems.append(f"{summary}; expected failure with {mutant['fails']}, missing {missing}")
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
        functions = sorted(set(out["revsetFunctions"]) ^ set(baseline["revsetFunctions"]))
        if functions != sorted(mutant.get("revsetFunctionsAdd", [])):
            problems.append(f"{summary}; revset functions moved by {functions} (expected {mutant.get('revsetFunctionsAdd', [])})")
            continue
        wrong = {f"{k}.{f}": out["settings"].get(k, {}).get(f) for k, fields in mutant.get("changes", {}).items()
                 for f, v in fields.items() if out["settings"].get(k, {}).get(f) != v}
        if wrong:
            problems.append(f"{summary}; expected changes {mutant['changes']}, got {wrong}")
            continue
        if not any(mutant.get(k) for k in ("adds", "changes", "revsetFunctionsAdd")) and out != baseline:
            problems.append(f"{summary}; expected the baseline output unchanged")
            continue
        summary += f" added={','.join(added) or '-'}"
    print("ok", summary)

for p in problems:
    print("FAIL", p, file=sys.stderr)
sys.exit(1 if problems else 0)

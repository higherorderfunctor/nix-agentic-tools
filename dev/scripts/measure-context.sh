#!/usr/bin/env bash
# Rough steering measurements; optional arguments are repository-relative paths.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

cd "$(git rev-parse --show-toplevel)"

python3 - "$@" <<'PY'
import fnmatch
import json
from pathlib import Path
import sys


def report(label, paths):
    print(f"=== {label} ===")
    total = 0
    for path in sorted(set(paths)):
        if not path.is_file():
            print(f"  {path}: MISSING")
            continue
        data = path.read_bytes()
        size = len(data)
        total += size
        print(f"  {path}: {size:,} bytes; ~{size / 4:,.0f} tokens "
              f"({data.count(bytes([10])):,} lines, {len(data.split()):,} words)")
    print(f"  Total: {total:,} bytes; ~{total / 4:,.0f} tokens "
          f"(sensitivity {total / 5:,.0f}..{total / 3:,.0f})\n")


def patterns(path):
    # Only the generated single-line applyTo scalar; this is not a YAML parser.
    lines = path.read_text().splitlines()
    if not lines or lines[0] != "---":
        return []
    for line in lines[1:]:
        if line == "---":
            break
        if line.startswith("applyTo:"):
            value = line.partition(":")[2].strip()
            if value.startswith('"'):
                value = json.loads(value)
            elif value.startswith("'") and value.endswith("'"):
                value = value[1:-1].replace("''", "'")
            return [item.strip() for item in value.split(",") if item.strip()]
    return []


print("Token estimates assume bytes/4; sensitivity assumes bytes/5..bytes/3.")
print("These are rough tuning estimates, not a GitHub limit or a pass/fail gate.")
print("Copilot known-file estimates exclude diff, system, and organization context.")
print("Fallback child indexes are excluded from Copilot native instruction totals.\n")
root = [Path("AGENTS.md")]
claude_always = [path for path in Path(".claude/rules").glob("*.md")
                 if not any(line.startswith("paths:")
                            for line in path.read_text().splitlines())]
native = sorted(Path(".github/instructions").glob("*.instructions.md"))
scopes = {path: patterns(path) for path in native}
always = [path for path in native if "**" in scopes[path]]
report("Claude always-on steering", [Path(".claude/CLAUDE.md"), *claude_always])
report("AGENTS.md (Codex, Copilot, Kiro, Kimchi)", root)
report("Copilot root + always-on native instructions", [*root, *always])
report("Copilot root + entire emitted native instruction corpus", [*root, *native])

if sys.argv[1:]:
    candidates = []
    for raw in sys.argv[1:]:
        path = Path(raw)
        if path.is_absolute() or ".." in path.parts:
            sys.exit(f"Expected a repository-relative path without '..': {raw}")
        candidates.append(path.as_posix())
    print("Candidate paths (need not exist): " + ", ".join(candidates))
    print("Approximate applyTo matching uses Python fnmatch; native glob semantics may differ.")
    matched = [path for path in native
               if any(fnmatch.fnmatchcase(candidate, pattern)
                      for candidate in candidates for pattern in scopes[path])]
    report("Copilot root + matched native instructions (each file counted once)",
           [*root, *matched])

report("Source monorepo fragments (composed into the orientation)",
       Path("dev/fragments/monorepo").glob("*.md"))
PY

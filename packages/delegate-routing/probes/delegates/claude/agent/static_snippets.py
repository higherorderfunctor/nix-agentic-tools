#!/usr/bin/env python3
"""codex:A (G evidence) — print small, bounded excerpts from selected pinned Claude bundle chunks.

usage: python3 static_snippets.py <unpacked-dir>   (<unpacked-dir> from ../unpack.sh)
"""
import sys
from pathlib import Path

if len(sys.argv) != 2:
    sys.exit(__doc__)
root = Path(sys.argv[1])
queries = {
    "chunk-z27fd322.js": ["ONLY call this tool when the user has explicitly opted", "opts.model overrides the model for this agent call", "Workflow({scriptPath, resumeFromRunId}"],
    "chunk-2dk1sr5c.js": ["spawn_depth_cap", "SubagentStart hooks cancelled", "Task tool", "agentType"],
    "chunk-5g752enf.js": ["Every monitor expires", "persistent: true", "Use TaskStop to cancel"],
    "chunk-6dcv9czk.js": ["No completion record was found"],
    "chunk-5zevbw45.js": ["SubagentStart", "SubagentStop"],
}
for name, terms in queries.items():
    text = (root / name).read_text(errors="replace")
    print(f"## {name}")
    for term in terms:
        at = text.find(term)
        if at >= 0:
            print(f"[{term}] {text[max(0, at-220):at+680].replace(chr(10), ' ')}")

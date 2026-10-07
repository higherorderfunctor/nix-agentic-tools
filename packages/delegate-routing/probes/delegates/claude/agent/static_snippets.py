#!/usr/bin/env python3
"""codex:A (G evidence) — print small, bounded excerpts from selected pinned Claude bundle chunks.

usage: python3 static_snippets.py <unpacked-dir>   (<unpacked-dir> from ../unpack.sh)
"""
import sys
from pathlib import Path

if len(sys.argv) != 2:
    sys.exit(__doc__)
root = Path(sys.argv[1])
# Select by behavior; chunk names change on each release. Missing facts are errors.
queries = [
    ["ONLY call this tool when the user has explicitly opted", "opts.model overrides the model for this agent call", "Workflow({scriptPath, resumeFromRunId}"],
    ["spawn_depth_cap", "SubagentStart hooks cancelled", "agentType"],
    ["Every monitor expires", "persistent: true", "Use TaskStop to cancel"],
    ["No completion record was found"],
    ["Math.min(16,Math.max(2", "z?.stallMs", "nesting is limited to one level", "Bo=5"],
    ["Vat=600000"],
    ["Exit code 0 - JSON additionalContext shown to subagent", "SubagentStop"],
]
chunks = [(path, path.read_text(errors="replace")) for path in sorted(root.glob("chunk-*.js"))]
for terms in queries:
    matches = [(path, text) for path, text in chunks if all(term in text for term in terms)]
    if len(matches) != 1:
        sys.exit(f"expected one chunk containing {terms}, found {len(matches)}")
    path, text = matches[0]
    print(f"## {path.name}")
    for term in terms:
        at = text.index(term)
        print(f"[{term}] {text[max(0, at-220):at+680].replace(chr(10), ' ')}")

# G rows: inventory the pinned strings, retaining source locations and excerpts.
for term in [
    "API_TIMEOUT_MS", "CLAUDE_CODE_DISABLE_WORKFLOWS", "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS",
    "CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS", "WorktreeCreate", "WorktreeRemove",
    "allow_workflows", "appendSystemPrompt", "bashCommandClamp", "bgIsolation", "can_use_tool",
    "context", "disallowedTools", "heron_brook", "maxEffortLevel", "memory", "mcpServers",
    "model.complete", "model.fork", "policyHelper", "skills", "teammateMode", "workflowSizeGuideline",
]:
    matches = [(path, text) for path, text in chunks if term in text]
    if not matches:
        sys.exit(f"missing pinned string: {term}")
    print(f"## grep {term}: {len(matches)} chunks")
    for path, text in matches:
        at = text.index(term)
        print(f"{path.name}:{text[:at].count(chr(10))+1}: {text[max(0, at-160):at+400].replace(chr(10), ' ')}")

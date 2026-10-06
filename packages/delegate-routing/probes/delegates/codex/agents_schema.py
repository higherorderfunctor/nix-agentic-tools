#!/usr/bin/env python3
"""judge:J2 — keys of `AgentsToml` in the pinned source's core/config.schema.json.

usage: python3 agents_schema.py [<codex-src>]   (default: the pinned chatgpt-codex src)
Expect: default_subagent_model, default_subagent_reasoning_effort, enabled, interrupt_message,
max_concurrent_threads_per_session, max_depth; `max_threads` and `job_max_runtime_seconds` absent.
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import codexpin  # noqa: E402

src = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else codexpin.source()
schema = json.loads((src / "codex-rs" / "core" / "config.schema.json").read_text())
agents = schema.get("definitions", schema.get("$defs", {}))["AgentsToml"]
print(json.dumps(sorted(agents.get("properties", {})), indent=2))

# Workflow reader evidence

Copied verbatim workflow event lines from a 2026-10-04 probe using Kimchi 1.5.1,
model `kimchi-dev/glm-5.3-flash`, the real home and a `kimchi -p` parent session
launching through bash. `run-completed` was observed. Preparation, provenance
and usage events were omitted; JSONL was not rewritten.

- `blocked.jsonl`: `workflow-blocked-f05b613a.events.jsonl:3-5`.
- `completed.jsonl`: `workflow-success-da9f64f0.events.jsonl:3-4,6-7`.
- `crashed.jsonl`: `workflow-one-step-d0f7b35b.events.jsonl:3-4,6`.

Classification follows the published `@kimchi-dev/kimchi-workflows@0.0.9`
source:

- `src/engine/node-path.ts:120-132`: `staticPathOf`/`staticKeyOf` collapse loop
  indices; foreach indices remain distinct.
- `src/engine/run-status.ts:32-49`: started prerequisite, active/blocked
  precedence, latest terminal, crash fallback.
- `src/engine/step-state.ts:63-109`: step lifecycle, human input, branch arms
  and forced crash/cancel closure.

The check adds synthetic active-plus-blocked, cancelled, unfinished and
malformed records and enriches a blocked request with opaque conversation
history to verify redaction. These are reader coverage, not live measurements.
`kimchi-workflow-version` rejects a changed bundled lockfile version until the
reader is verified against the new published source.

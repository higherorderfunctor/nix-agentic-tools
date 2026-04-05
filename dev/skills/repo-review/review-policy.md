# Review Policy

This policy is loaded by all reviewer subagents and the orchestrator. It
defines severity levels, output format, change thresholds, and the decision
confidence model.

## Severity Levels

<!-- dprint-ignore -->
| Severity | Meaning | Action required |
|----------|---------|-----------------|
| `high` | Incorrect command, broken install path, security issue, contradiction that would cause user failure | Must fix |
| `medium` | Non-idiomatic pattern, unclear docs, missing edge case, stale reference | Should fix |
| `low` | Style preference, minor clarity improvement, nice-to-have | Observation only |

## Change Threshold

A finding becomes a **recommended change** when:

- Severity is `high`, OR
- 3+ reviewers independently flag the same issue (any severity), OR
- A finding contradicts an accepted decision with confidence < 0.5

Everything else appears as an **observation** — informational, no action
expected. This prevents churn.

## Decision Confidence Model

Decisions in `docs/decisions/` carry a confidence score (0.0–1.0) that
reflects how well-supported they are by current evidence.

### Initial Confidence

Set by reviewer consensus at the time of the decision:

- 0.9–0.95: Strong evidence, multiple sources, no viable alternatives
- 0.7–0.85: Good evidence, clear reasoning, but alternatives exist
- 0.5–0.65: Reasonable choice, limited evidence, could go either way
- Below 0.5: Provisional — needs validation

Maximum initial confidence is 0.95. Nothing is certain.

### Reinforcement

Each review run, reviewers search for new evidence supporting existing
decisions. When found:

- Increment `reinforcement-count`
- Update `last-reinforced` date
- Adjust confidence: `min(0.95, confidence + 0.03 * (1 - confidence))`
  (diminishing returns — approaching but never reaching 1.0)
- Add an entry to the decision's Evidence Log with the new source

### Decay

Confidence decays when a review run finds NO new reinforcement AND discovers
competing approaches gaining traction. Decay is attention-based, not
time-based:

- **No reinforcement + competing approaches found**: confidence decreases by
  0.05 per run
- **No reinforcement + no competing approaches**: confidence decreases by
  0.01 per run (slow drift — the ecosystem is stable)
- **Reinforcement found**: no decay (reinforcement and decay don't happen in
  the same run)

### Challenge Threshold

When confidence drops below 0.5:

- The decision is flagged as **weakening** in the review report
- All reviewers are asked to re-evaluate with fresh research
- Consensus must be reached to either:
  - **Reinforce**: Update reasoning and bump confidence back up
  - **Supersede**: Create a new decision referencing the old one

### Superseding a Decision

To supersede an accepted decision:

- All 6 reviewers must be consulted (even if not all have an opinion)
- At least 4 must agree on the replacement
- The old decision's status changes to `superseded-by: NNNN`
- A new decision is created with fresh evidence

### Creating New Decisions

To create a new decision:

- All 6 reviewers must be consulted (even if not all have an opinion)
- At least 4 must agree the topic warrants a decision record
- Initial confidence is set by reviewer consensus (see § Initial Confidence)
- The decision is written to `docs/decisions/` with the next available ID

### What Is NOT a Decision

Decisions record **architectural choices that could be re-litigated** — not
bug fixes, typos, or one-off corrections. The test: would a reasonable person
argue for the opposite approach? If yes, record a decision. If no, just fix
the bug.

Examples of decisions: "keep disable-model-invocation true", "install is nix
or manual only", "use MADR with confidence scoring".

NOT decisions: "fix extraConfig → settings", "remove pull.ff", "add missing
symlink", "fix invalid flag".

## Output Schema

Each reviewer must return findings as a JSON array. The orchestrator parses
and aggregates these.

```json
[
  {
    "file": "path/to/file",
    "line_start": 42,
    "line_end": 45,
    "category": "string (personality-specific categories)",
    "severity": "high | medium | low",
    "description": "What's wrong or could be better",
    "suggestion": "What to do about it",
    "evidence": "URL, quote, or comparison supporting the finding",
    "decision_refs": ["0001", "0003"]
  }
]
```

The `decision_refs` field lists any existing decisions this finding relates
to (reinforcing or contradicting).

## Reviewer Conduct

- **Research before opining.** Do web searches for current best practices.
  Don't rely on training data alone.
- **Cite sources.** Every `high` or `medium` finding must include evidence.
- **Respect accepted decisions.** If a finding contradicts an accepted
  decision with confidence >= 0.5, note the contradiction but do not
  recommend changes — flag it for the debate round instead.
- **Don't change for change's sake.** A working pattern that isn't "optimal"
  is not a finding unless it causes concrete problems.
- **Be specific.** "This could be better" is not a finding. "Line 42 says
  `--flag` but upstream removed it in v0.11" is.

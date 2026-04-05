---
name: repo-review
description: >-
  Use when you need a multi-perspective review of this repo. Spawns 6
  specialized reviewers (git expert, agentic UX, human UX, nix expert,
  FP/DRY expert, consistency auditor). Aggregates findings, deduplicates,
  respects recorded decisions, and proposes changes with human approval.
argument-hint: "[full | scope:<path> | decisions-only]"
---

Multi-perspective repo review with parallel specialized reviewers. Human
approves all changes. Implementation uses this repo's own skills.

## Model Tiers

This skill uses three model tiers. Express these as intent — the tool
runtime maps them to available models.

| Tier | Intent | Examples |
|------|--------|----------|
| **TRIAGE** | Fast, cheap. Filtering, classification, scoring. | Pre-flight checks, confidence scoring, eligibility |
| **REVIEW** | Standard depth. Read code, find issues, research. | The 6 reviewer personalities |
| **CRITICAL** | Deepest analysis. Synthesis, debate, judgment. | Aggregation, debate resolution, finding validation |

When spawning agents, include the tier in the description:
- `[TRIAGE]` agents: use `model: "haiku"` if available
- `[REVIEW]` agents: use default model (sonnet-class)
- `[CRITICAL]` agents: use `model: "opus"` if available

Tools that don't support model selection use their default for all tiers.

## Pre-flight [TRIAGE]

Spawn a **[TRIAGE] pre-flight agent** that:

1. **Loads review policy** — reads `review-policy.md` from this skill's
   directory.

2. **Loads existing decisions** — reads all files in `docs/decisions/` at
   the repo root.

3. **Determines scope** from `$ARGUMENTS`:
   - `full` or empty — review entire repo
   - `scope:<path>` — review only files under the given path
   - `decisions-only` — skip review, only run decision reinforcement/decay

4. **Gathers context**:
   - List of files in scope (with line counts)
   - Recent git log (last 20 commits) for historical context
   - Any TODO.md or known issues

5. Returns: scope, decision log, file list, context summary.

## Phase 1: Fan-Out (Parallel Review) [REVIEW]

Spawn **6 [REVIEW] reviewer subagents in parallel** using the Agent tool.
Each gets:

- Their personality prompt (from `personalities/` in this skill's directory)
- The review policy
- The full decision log
- The scope (which files to focus on)
- The reference docs from `references/` in this skill's directory — these
  are distilled, indexed upstream docs (produced by `/index-repo-docs`) and
  should be treated as authoritative baseline knowledge. Reviewers should
  read them BEFORE doing external research to avoid re-discovering what's
  already documented.
- Read-only access to the repo
- **Git blame/history context**: tell each reviewer to run `git log` and
  `git blame` on files they're reviewing to understand change context.
  Flag issues that were introduced recently vs pre-existing.

Each reviewer:

1. Reads the files in scope
2. Runs `git blame` on files with findings to confirm whether issues are
   new (introduced in recent commits) or pre-existing
3. Does web research for current best practices in their domain
4. Checks findings against the decision log (skip accepted decisions with
   confidence >= 0.5 unless new contradicting evidence is found)
5. Searches for new evidence that reinforces or weakens existing decisions
6. Returns structured JSON findings per the output schema in review-policy.md

**IMPORTANT:** Tell each subagent to return findings as a JSON array in a
fenced code block tagged `json`. Findings that match an accepted decision
(confidence >= 0.5) should be SKIPPED — do not include them.

Only return a `decision_updates` array if there are CHALLENGES (findings
that contradict accepted decisions with new evidence). Do NOT report
reinforcements or slow-decay — the orchestrator handles confidence
maintenance silently.

## Phase 2: Confidence Scoring [TRIAGE]

For each finding from Phase 1, spawn a **[TRIAGE] scoring agent** that
receives:

- The finding (description, file, evidence)
- The decision log
- The review policy's false positive rubric (below)

The scoring agent returns a confidence score 0–100:

- **0**: Not confident. False positive, doesn't survive scrutiny, or is
  pre-existing (introduced before recent work).
- **25**: Somewhat confident. Might be real, might be false positive.
  Stylistic issue not explicitly called out in CLAUDE.md or coding
  standards.
- **50**: Moderately confident. Real issue but minor or infrequent.
  Not important relative to the rest of the repo.
- **75**: Highly confident. Verified real issue, will impact functionality,
  or directly mentioned in coding standards. Existing approach is
  insufficient.
- **100**: Absolutely certain. Confirmed, will happen frequently, evidence
  directly proves it.

**False positive rubric** (give to scoring agents verbatim):

These are NOT real findings:
- Pre-existing issues not introduced in recent work
- Something that looks wrong but is intentional (check git blame)
- Pedantic nitpicks a senior engineer wouldn't flag
- Issues a linter, typechecker, or formatter would catch (treefmt,
  deadnix, statix, cspell handle these)
- General quality concerns not in CLAUDE.md or coding standards
- Issues with explicit suppression comments (lint ignore, etc.)
- Functionality changes that are clearly intentional
- Issues on lines not modified in recent work

Score each finding independently. Run scoring agents in parallel.

**Filter**: Drop findings with confidence < 80.

## Phase 3: Aggregate [CRITICAL]

Spawn a **[CRITICAL] aggregation agent** that receives all findings
that survived the confidence filter. This agent:

1. **Deduplicates** by `(file, line_range)`:
   - If 2+ reviewers flag the same area, merge into one finding
   - Keep the best description (most specific, best evidence)
   - Note agreement count and which reviewers agreed

2. **Applies change threshold** (from review-policy.md):
   - `high` severity → recommended change
   - 3+ reviewer agreement → recommended change
   - Contradicts decision with confidence < 0.5 → recommended change
   - Everything else → observation

3. **Checks decision contradictions**:
   - If a finding contradicts an accepted decision with confidence >= 0.5,
     DO NOT mark it as a recommended change. Flag for Phase 4.

4. **Processes decision updates**:
   - Merge reinforcement/decay observations across reviewers
   - Apply confidence adjustments per the formulas in review-policy.md

5. **Validates findings**: For each recommended change, verify the evidence
   is concrete and actionable. Demote to observation if evidence is vague.

## Phase 4: Debate (Only If Needed) [CRITICAL]

If any findings contradict accepted decisions (confidence >= 0.5):

Spawn a **[CRITICAL] debate agent** that receives:

- The contradicting finding(s) with evidence
- The original decision with its evidence log
- Arguments from the reviewer(s) who flagged it

The debate agent evaluates both sides and returns a recommendation:

- **Uphold**: The decision stands. Add the new evidence as a consideration
  but don't change the decision.
- **Challenge**: The decision should be re-evaluated. Lower confidence and
  flag for human review.
- **Supersede**: Strong evidence warrants a new decision. Draft the
  replacement for human approval.

## Phase 5: Report

Present the aggregated report to the user. Format:

```
## Review Report

### Recommended Changes (N findings)

1. **[HIGH]** file.md:42 — description (confidence: 92)
   Evidence: ...
   Suggestion: ...
   Reviewers: git-expert, consistency-auditor (2/6 agree)

2. ...

### Observations (N findings)

1. **[LOW]** file.md:10 — description (confidence: 85)
   ...

### Decision Challenges (requires consensus)

(Only shown if a finding contradicts an accepted decision)

### Proposed New Decisions

(Only shown if reviewers identify an architectural choice worth recording)

Decisions are for **design choices that could be re-litigated** — not bug
fixes. "Use programs.git.settings not extraConfig" is a bug fix. "Keep
disable-model-invocation true" is a decision. The test: would a reasonable
person argue for the opposite approach? If yes, record it. If no, just fix it.

### Status: CLEAN | N findings

One-line summary: "Clean — no recommended changes" or "N recommended
changes, M observations".
```

**Omit from the report:**

- Decision reinforcements (confidence bumps with no action needed)
- Decision slow-decay (no action until challenge threshold)
- Findings that match accepted decisions (already decided, skip silently)
- Findings filtered by confidence scoring (< 80)

The goal is convergence: each run should produce fewer findings. If findings
persist across runs, either the fix wasn't applied or the decision log is
missing an entry. A clean report means the review system is working.

## Phase 6: Human Approval and Implementation

**ALL changes require human approval.** Do not modify any files without
explicit confirmation.

After presenting the report, ask the user:

> Which recommended changes would you like to implement? You can:
>
> - Accept all recommended changes
> - Cherry-pick specific findings by number
> - Dismiss findings with reasoning (adds to decision log)
> - Accept decision updates
> - Approve/reject proposed new decisions

**Wait for the user's response.** Do not proceed without approval.

### Implementation — USE THIS REPO'S SKILLS

Once the user approves changes, implement them using the stacked workflow
skills. **Do NOT make changes via raw git commands.** The implementation
flow is:

1. **Run `/stack-summary`** on the current stack to understand what exists
   and where approved changes should land.

2. **Determine distribution**: Can approved changes be absorbed into
   existing unmerged commits (via `/stack-fix`), or do they need new
   commits?
   - Consistency fixes (stale references, naming) → absorb into the commit
     that introduced the inconsistency using `/stack-fix`
   - New content (new decision records, new reference content) → new commits
   - Structural changes (reorganization) → `/stack-plan` to plan the commits

3. **Plan the implementation** using `/stack-plan` if new commits are needed.
   Present the plan to the user for approval before executing.

4. **Execute changes**:
   - Use `/stack-fix` for absorbing fixes into existing commits
   - Use `/stack-plan` for building new commits
   - Use `/stack-split` if an existing commit needs splitting

5. **Update decision records**: Write new decisions to `docs/decisions/`,
   update confidence scores and evidence logs on existing decisions.

6. **Verify** with `/stack-test` if a test command is available.

## Tips

- First run on a repo will produce more findings. Subsequent runs should be
  shorter as decisions accumulate and findings get fixed.
- The `decisions-only` argument is useful for periodic confidence maintenance
  without a full review.
- Reviewers that find no issues should still report decision reinforcements.
- If the report is overwhelming, focus on `high` severity first. `low`
  severity observations are informational only.
- Decision files in `docs/decisions/` are part of the repo and go through
  normal PR review. They are not auto-committed.
- The confidence scoring pass dramatically reduces false positives. If too
  many findings are filtered, lower the threshold from 80 to 60.
- [CRITICAL] tier agents cost more but catch synthesis errors that cheaper
  models miss. Don't skip the aggregation/debate phases.

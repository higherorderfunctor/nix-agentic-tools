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

## Pre-flight

1. **Load review policy** — read `review-policy.md` from this skill's
   directory.

2. **Load existing decisions** — read all files in `docs/decisions/` at the
   repo root. These are accepted decisions that reviewers must respect. Pass
   the full decision content to each reviewer subagent.

3. **Determine scope** from `$ARGUMENTS`:
   - `full` or empty — review entire repo
   - `scope:<path>` — review only files under the given path
   - `decisions-only` — skip review, only run decision reinforcement/decay

## Phase 1: Fan-Out (Parallel Review)

Spawn **6 reviewer subagents in parallel** using the Agent tool. Each gets:

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

Each reviewer:

1. Reads the files in scope
2. Does web research for current best practices in their domain
3. Checks findings against the decision log (skip accepted decisions with
   confidence >= 0.5 unless new contradicting evidence is found)
4. Searches for new evidence that reinforces or weakens existing decisions
5. Returns structured JSON findings per the output schema in review-policy.md

**IMPORTANT:** Tell each subagent to return findings as a JSON array in a
fenced code block tagged `json`. Findings that match an accepted decision
(confidence >= 0.5) should be SKIPPED — do not include them.

Only return a `decision_updates` array if there are CHALLENGES (findings
that contradict accepted decisions with new evidence). Do NOT report
reinforcements or slow-decay — the orchestrator handles confidence
maintenance silently.

## Phase 2: Aggregate

After all 6 reviewers complete:

1. **Parse findings** from each reviewer's output.

2. **Deduplicate** by `(file, line_range)`:
   - If 2+ reviewers flag the same area, merge into one finding
   - Keep the best description (most specific, best evidence)
   - Note agreement count

3. **Apply change threshold** (from review-policy.md):
   - `high` severity → recommended change
   - 3+ reviewer agreement → recommended change
   - Contradicts decision with confidence < 0.5 → recommended change
   - Everything else → observation

4. **Check decision contradictions**:
   - If a finding contradicts an accepted decision with confidence >= 0.5,
     DO NOT mark it as a recommended change. Instead flag it for Phase 3.

5. **Process decision updates**:
   - Merge reinforcement/decay observations across reviewers
   - Apply confidence adjustments per the formulas in review-policy.md

## Phase 3: Debate (Only If Needed)

If any findings contradict accepted decisions (confidence >= 0.5):

Spawn a **debate subagent** that receives:

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

## Phase 4: Report

Present the aggregated report to the user. Format:

```
## Review Report

### Recommended Changes (N findings)

1. **[HIGH]** file.md:42 — description
   Evidence: ...
   Suggestion: ...
   Reviewers: git-expert, consistency-auditor (2/6 agree)

2. ...

### Observations (N findings)

1. **[LOW]** file.md:10 — description
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

The goal is convergence: each run should produce fewer findings. If findings
persist across runs, either the fix wasn't applied or the decision log is
missing an entry. A clean report means the review system is working.

## Phase 5: Human Approval and Implementation

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

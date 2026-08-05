# Kiro Workflow Engine — Working Reference

> ## BOOTSTRAP — instructions for the session receiving this file
>
> You are turning this stub into the finished reference. Replace this entire
> blockquote with real content as you go; it must not survive into the
> ready-for-review PR.
>
> **Workspace.** Work in the `docs/workflow-refs` worktree at
> `~/Documents/projects/nix-agentic-tools-worktrees/workflow-refs` (draft PR
> #782, branch `docs/workflow-refs`). Pre-flight before your first file write:
> `git rev-parse --git-dir` must end in `.git/worktrees/workflow-refs` — never
> author files in the primary checkout, not even untracked drafts. The worktree
> is already bootstrapped (direnv covers it; `cd` is enough). Read the
> `project_kiro_harness_matrix_northstar` memory before any Kiro work.
>
> **Mission.** Write THIS doc: a human-readable reference on the Kiro workflow
> engine — the mechanics, plus small worked examples of wiring them into
> patterns. Synthesize ONLY from research already in this repo:
> `dev/references/kiro-workflows.md` (the measured-mechanics evidence ledger —
> cite it by section, do not duplicate or re-derive it),
> `fixtures/kiro-primitives/`, `packages/kiro-cli/docs/`, and the kiro memories.
> The reader is the operator, a human — prefer plain answers with a short
> provenance note over the ledger's full epistemic scaffolding.
>
> **Questions this doc must answer** (they are the section skeleton below):
>
> 1. Steering individual agents from the workflow TUI — and what other
>    run-control mechanics exist.
> 2. Message passing between agents — is there any, and what is the actual
>    channel that moves data.
> 3. Workflows are written as JSON — are they composable? Ref pointers from one
>    workflow into another? Can an LLM synthesize a workflow from saved ones
>    used as templates?
> 4. The built-in coder workflow (planner → looper(writer → reviewer)): the
>    exact mechanic that carries writer output to the reviewer, and reviewer
>    feedback into the next iteration's writer.
> 5. Node-count limits (operator's guess: 18 max; coder uses 3) — verify from
>    the research. Is there an easy fan-out to 6 parallel × 3-agent chains? Ref
>    stitching, synthetic plans, or dynamic node editing (incremental synthesis
>    rather than all-upfront)?
> 6. Can agents inside a workflow spawn ad-hoc agents outside the graph —
>    blocking, async/background, or both?
> 7. Can an agent inside a workflow create a second workflow, or is that
>    reserved for the root agent? (Parallel workflows are known to run.)
>
> **Open-item register.** Every question the existing repo data cannot answer
> goes in the register section at the bottom — stated crisply, with what single
> targeted measurement WOULD answer it. Do not chase them; the operator decides
> what gets researched after reviewing this doc.
>
> **Method.** Ultracode is approved for this: parallel readers over the source
> documents and fixtures, then synthesis. Cap concurrency at ~6 agents. All
> sources are text files — there is NO reason to touch a binary.
>
> **Hard constraints, non-negotiable.**
>
> - Never grep, read, slice, or otherwise process binary blobs (the kas bundle,
>   the kiro binary, any executable). A previous session OOM'd the machine doing
>   exactly this.
> - No open-ended research loops; answer from existing data, register the gaps,
>   stop. Converge.
> - No mock engines, replica harnesses, or transactional test apparatus of any
>   kind — a previous session built a mock Kiro workflow engine and it is
>   explicitly banned.
> - No live Kiro probing in this pass; that is exactly what the register defers
>   to the operator.
> - Commit to this branch as sections complete; PR #782 stays draft. The
>   claude-workflows.md sibling on this branch is preserved as-is.

## 1. Execution model

<!-- how a workflow run works end to end: definition, validation, run, TUI -->

## 2. Steering and run control

<!-- question 1: per-agent steering + every other control mechanic -->

## 3. How data moves between agents

<!-- questions 2 and 4: the channel; coder loop writer/reviewer threading -->

## 4. Composition and reuse

<!-- question 3: JSON composability, refs, template-driven synthesis -->

## 5. Limits and fan-out

<!-- question 5: node caps, 6x3 shape, dynamic node editing -->

## 6. Ad-hoc agents and nested workflows

<!-- questions 6 and 7 -->

## 7. Wiring patterns

<!-- small worked examples composing the mechanics above -->

## 8. Open-item register

<!-- gaps the repo data cannot answer + the one measurement each needs -->

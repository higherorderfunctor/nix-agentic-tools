# Backlog Grooming Ledger

> **Transient work-doc.** Created 2026-06-18 to groom `docs/`. Delete this
> file once grooming is FULLY executed (after the restructure-synthesis pass).
> This is the resume point — re-read this file to continue.

**Status:** AUDIT COMPLETE. Decisions captured. **Execution deferred to a
later session (user chose "resume later").** Nothing has been moved or
deleted. Two initiatives queued: (1) the archive sweep, (2) a
restructure-doc synthesis pass.
**Method:** 4 parallel read-only audit agents + a direct mtime/git-date
re-check of the restructure cluster.

---

## ▶ START HERE — resume menu

> **AGENT:** if the user said "look at the backlog ledger" (or similar) with no
> specific instruction, do NOT start work. Read this file, then present the
> three paths below and ask the user to pick ONE. Confirm the choice, then
> execute only that initiative. Recommend Path A first.
>
> **USER:** pick a path (or just tell me the letter).

| Path  | What it does                                         | Engagement                        |
| ----- | ---------------------------------------------------- | --------------------------------- |
| **A** | Archive sweep — declutter only (Initiative 1)        | Low focus, ~few min               |
| **B** | Restructure synthesis — the real work (Initiative 2) | High focus, needs your decisions  |
| **C** | Both, A then B                                       | Do A, then B in a focused stretch |

- **Path A (recommended first):** move the 10 done/superseded docs to
  `docs/archive/` + hard-delete `spiral-context.md`. Gets `docs/` from 25 → ~14
  files so the restructure cluster stops being buried. Safe anytime, even
  half-distracted. Agent: show the `git mv` plan before running it.
- **Path B (the thing that was bugging you):** read all 8 restructure docs →
  draft a combined `docs/package-restructure.md`. Needs you engaged — two
  decisions only you can make: (1) fixture-first (Lineage B) vs the merge-up
  namespace (Lineage A), and (2) a `fixture/` subdir vs a separate scratch repo
  for the no-domain-specifics test. Do NOT archive the 8 sources until the
  combined doc is reviewed.
- **Path C:** A as a warm-up, then B.

During whichever path: also flag the `grill-me` skill itself (separate from its
docs) as a removal candidate and confirm with the user before touching it.

---

## Final decisions (user, 2026-06-18)

- **Removal style = ARCHIVE** to `docs/archive/` (NOT hard delete), EXCEPT
  `spiral-context.md` = **HARD-DELETE** (verbatim personal quotes; don't leave
  in-tree).
- **grill-me = RETIRE.** `concepts.md` → archive; `spiral-context.md` →
  hard-delete. Flag the `grill-me` skill itself as a removal candidate.
- **harness = KEEP** (`agentic-harness-handoff.md` — still a planned build).
- **Restructure cluster = KEEP ALL, DO NOT archive piecemeal.** User: "been
  months since I read these… may need to group and later use an LLM to comb
  through them all and synthesize a combined version. Not sure if we drop any
  details just axing older ones to the archive." → Plan a **synthesis pass**
  (below). Archive the sources only AFTER details are captured in the combined
  doc.

---

## Initiative 1 — Archive sweep (mechanical, ready to execute)

On resume: `mkdir -p docs/archive/`, then for each file below grep the repo
for references first (AGENTS.md change-propagation), `git mv` into
`docs/archive/`, fix any cross-refs, `treefmt`.

**ARCHIVE (10 done/superseded, all verified landed/superseded via git):**

| File                                                          | Why                                                                                           |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `plans/per-cli-model-and-thinking-config.md`                  | SUPERSEDED by convergence; shipped.                                                           |
| `plans/claude-effort-pin-and-mutable-state-reconciliation.md` | SUPERSEDED by convergence; forensics safe in memory `project_claude_effort_pin_state`.        |
| `plans/typed-model-and-thinking-config-convergence.md`        | COMPLETE (`94d2262`). ⚠ memory cites it as canonical handoff — update memory if path changes. |
| `plans/typed-model-and-thinking-config-implementation.md`     | COMPLETE — 7+1 commits landed.                                                                |
| `plans/kiro-agent-engine-and-mode.md`                         | COMPLETE — `v3` bool shipped (`19a87a9`).                                                     |
| `plans/ci-darwin-nuscht-and-update-timeout.md`                | COMPLETE — 3 CI fixes landed.                                                                 |
| `plans/gitlab-mcp-packaging.md`                               | SUPERSEDED by `-slim` (wrong tool count).                                                     |
| `plans/gitlab-mcp-packaging-slim.md`                          | COMPLETE — executed; pkg live.                                                                |
| `ai-rules-livelink-plan.md`                                   | Feature shipped then REVERTED (`056c7ad`).                                                    |
| `concepts.md`                                                 | grill-me glossary stub (Q-GRILL retire).                                                      |

**HARD-DELETE (1):** `spiral-context.md` (personal quotes).

**FLAG (not a doc):** `grill-me` skill — candidate for removal; handle separately.

---

## Initiative 2 — Restructure-doc synthesis pass (the focus)

**Do NOT archive any of these until synthesized.** Group = 8 docs spanning the
package/monorepo restructure + package-eval problem:

| File                                    | Date             | Role                                                          |
| --------------------------------------- | ---------------- | ------------------------------------------------------------- |
| `slice-architecture-assessment.md`      | 2026-05-08       | **CANONICAL / newest** — fixture-first; supersedes greenfield |
| `greenfield-package-shape.md`           | 2026-05-04       | package-shape input (mixed-eval-barrel → all-paths)           |
| `slice-nav-design.md`                   | 2026-04-28       | older Lineage A — merge-up namespace, effect-mcp pre-pilot    |
| `name-resolution-gap-analysis.md`       | 2026-04-28       | 14-site name→file migration checklist                         |
| `monorepo-restructure-assessment.md`    | 2026-04-21/06-01 | §11 slice table + flake-parts post-mortem                     |
| `ai-factory-collision-refactor-plan.md` | 2026-04-27       | COMPLETE foundation (`lib/ai/`); design context               |
| `mcp-servers-migration-plan.md`         | 2026-05-04       | `overlays/`→`packages/mcp-servers/` slice migration           |
| `mcp-servers-pilot-plan.md`             | 2026-05-04       | superseded parallel-sandbox precursor to migration            |

**Corrected canonical determination (supersedes the first audit agent AND the
stale `project_slice_nav_design` memory):** by mtime + git author date + the
explicit supersession header, the newest live thinking is
**`slice-architecture-assessment.md` (fixture-first)** — NOT `slice-nav-design.md`
(older Lineage A) and NOT `greenfield-package-shape.md` (superseded by it 4
days later). User's "greenfield was latest, test in a new repo without domain
specifics" maps to slice-architecture's headline: build a `fixture/` of mock
slices exercising only the architecture (no domain content), lock as reference,
then refactor the real repo. The "package eval was bugging me" = greenfield's
mixed-eval-barrel premise. **~0% implemented** for all restructure lineages;
only the factory foundation is landed.

**Synthesis-pass plan (next session):**

1. Have an LLM (sub-agent) read all 8 docs in full.
2. Produce ONE combined canonical doc — e.g. `docs/package-restructure.md` —
   reconciling the two lineages: fixture-first validation (B) + the merge-up
   namespace idea (A, if it survives the "mixed combinators" decision) +
   greenfield's all-paths package shape + the name-resolution checklist + the
   mcp-servers migration as a concrete pilot target. Preserve every
   load-bearing detail (decisions, dropped options + rationale, open Qs).
3. ONLY after the combined doc is reviewed: `git mv` the 8 sources into
   `docs/archive/`.
4. Open question for that pass: fixture as a `fixture/` subdir (per the doc)
   vs an actual separate greenfield repo (user's phrasing) — execution choice.

---

## KEEP — untouched (6)

| File                                     | Why                                                               |
| ---------------------------------------- | ----------------------------------------------------------------- |
| `plan.md`                                | SENTINEL-ONLY living backlog. Never merges to main. DO NOT TOUCH. |
| `update-pipeline-transitive-hash-gap.md` | LIVE-OPEN (Gap 1 + #144 canary).                                  |
| `unified-instructions-design.md`         | Live spec; tracks deferred work accurately.                       |
| `agentic-harness-handoff.md`             | KEEP per user (still a planned build).                            |
| `book.toml`, `.gitignore`                | mdbook / docs infra.                                              |

---

## Resume checklist

1. Re-read this ledger.
2. **Initiative 1 (archive sweep):** grep refs → `git mv` the 10 ARCHIVE
   files into `docs/archive/`; hard-delete `spiral-context.md`; fix cross-refs;
   `treefmt`; update memory `project_claude_effort_pin_state` if the
   convergence-doc path changes. Flag `grill-me` skill separately.
3. **Initiative 2 (synthesis):** run the 8-doc synthesis sub-agent → combined
   `docs/package-restructure.md` → review → archive the 8 sources.
4. Delete this ledger once both initiatives land.
5. Then: focused work on the synthesized restructure plan (fixture-first).

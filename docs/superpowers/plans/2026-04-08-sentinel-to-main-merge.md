# Sentinel → Main Merge Plan (2026-04-08)

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan
> task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Catch `main` up to the content of
`sentinel/monorepo-plan` (252 commits ahead, strict additive)
by landing a series of squash-merged PRs grouped by natural
file-scope chunks, one PR at a time, gated on Copilot review

- CI green + user GitHub review. Main becomes functionally
  equivalent to the sentinel tip while retaining a clean,
  atomic, reviewable history.

**Architecture:** File-based lazy extraction. Instead of
rewriting 252 commits into a stack, start from the sentinel
tip's on-disk file tree and chunk by logical dependency
group. A new `sentinel/main-catchup-2026-04-08` branch holds
the full squash as a reference tip. For each chunk, create a
short-lived `pr/<chunk>` branch from `origin/main`, stage
only that chunk's files, commit, open PR, iterate to merge.
After each merge, rebase the catchup branch onto the advanced
main to shrink the remaining delta. Keep chunks small enough
that Copilot/user feedback on one chunk doesn't force rework
on the rest.

**Tech Stack:** git, `gh` CLI, GitHub PR workflow, Copilot
auto-review, branch protection (PR required, squash merge
default), CI via `.github/workflows/{ci,docs,update}.yml`,
branchless for local stack hygiene.

---

## Required reading

Before starting:

1. **`memory/project_merge_to_main_strategy.md`** — the
   condensed strategy. Key points: lazy extraction, group like
   changes, no forward references, no docs-only catchup
   commits.
2. **`docs/plan.md`** "Next action" section — confirms this is
   the current TOP priority and captures the outcome expected
   after this plan completes.
3. **`memory/feedback_sentinel_plan.md`** — sentinel workflow
   conventions, why plan.md stays sentinel-tip-only.
4. **`memory/feedback_working_style.md`** — user's
   checkpoint-driven delivery preference. Applies at every
   PR boundary: pause, report, wait for approval.

---

## Current state (verified 2026-04-08)

- `origin/main` at `688b56a` — 2 commits, minimal scaffolding
  (PR #1 closed, PR #2 merged).
- `sentinel/monorepo-plan` at `19df998` — 252 commits ahead.
  Strict additive: `git merge-base --is-ancestor origin/main
HEAD` returns true.
- Diff size: 206 files changed, ~36k insertions, ~86 deletions.
- Branch protection on `main`: PR required (0 approving
  reviews), no force-push, no deletion. Merge methods allowed:
  merge, squash, rebase. **We always squash merge.**
- Copilot auto-review enabled via ruleset "Copilot review for
  default branch".
- CI runs `ci.yml` on PR (flake check + devenv test + cachix
  push). `docs.yml` runs on any branch for preview deploy.
- `nix flake check` green on sentinel tip.
- `devenv test` green on sentinel tip.
- `checks.cache-hit-parity` GREEN.

## User decisions (confirmed before drafting)

1. **Chunking order**: bottom-up (lib → packages → modules →
   content → checks → docs → CI). Controller's call; user
   deferred.
2. **Merge method**: squash merge, 1 PR = 1 commit on main.
3. **Sentinel handling**: create a NEW `sentinel/main-catchup-
2026-04-08` branch. Leave `sentinel/monorepo-plan` alone
   so original commits are preserved (GC-safe). Assume NO
   concurrent sentinel work during this plan's execution.
4. **CI gating**: wait for all CI checks green before merging
   any PR.
5. **Feedback threshold**: fix minor issues inline per Copilot
   review; file major issues as plan.md backlog items and
   resolve the thread with a comment linking the backlog item.
   Human-in-the-loop when unclear.
6. **Squash content**: include everything at sentinel tip
   including `docs/plan.md` and `docs/superpowers/`. These
   may become the "new" sentinel source after merge completes
   (deferred decision).
7. **New branch name**: `sentinel/main-catchup-2026-04-08`.

## Working conventions

- **Tool preferences**: `gh` CLI for all GitHub ops. `git` for
  local ops. Bash for scripting. Read/Edit/Write for files.
  Never use `curl` for GitHub — always `gh api` or `gh pr`.
- **Commit convention**: Conventional Commits. Subject
  lowercase imperative, no trailing period. Co-Authored-By
  footer on every commit. PR title matches the primary
  commit subject.
- **PR body template**: use the template in
  `dev/notes/pr-template.md` (created in Phase 1 as part of
  setup). Structure:
  - Summary (1-2 sentences)
  - Scope (files + dependency notes)
  - Verification (`nix flake check` + `devenv test` + any
    manual tests)
  - Backlog links (if any feedback was deferred)
- **Formatting**: `treefmt <file>` after every edit. `nix
flake check` + `devenv test` before every commit.
- **No force-push to main-catchup branch**. Rebase as
  additive-rewrite at the tip is fine (local only, not
  pushed until each chunk is extracted).
- **Never amend a pushed chunk PR**. Fix via additional
  commits; the PR squash-merges regardless.

---

## Phase 1: Create the merge sentinel

**Scope:** Produce a clean `sentinel/main-catchup-2026-04-08`
branch starting from `origin/main` with one squash commit
whose tree matches `sentinel/monorepo-plan` (currently at
`19df998`). Verify the tree builds cleanly.

### Task 1.1: Create the branch and squash

**Files:** None yet (branch creation + one squash commit).

**Steps:**

- [ ] **Step 1: Fetch latest refs.**

```bash
cd /home/caubut/Documents/projects/nix-agentic-tools
git fetch origin main sentinel/monorepo-plan
```

- [ ] **Step 2: Capture the sentinel tip and main base
      SHAs.**

```bash
SENTINEL_TIP=$(git rev-parse sentinel/monorepo-plan)
MAIN_BASE=$(git rev-parse origin/main)
echo "sentinel tip: $SENTINEL_TIP"
echo "main base:    $MAIN_BASE"
```

      Store these in variables for the rest of the phase.
      Expected: sentinel tip = `19df998...`, main base = `688b56a...`.

- [ ] **Step 3: Create the new branch from main.**

```bash
git checkout -b sentinel/main-catchup-2026-04-08 "$MAIN_BASE"
```

      Verify:

```bash
git log --oneline -3
```

      Expected: exactly 2 commits (`688b56a` and `1b25cd4`).

- [ ] **Step 4: Apply sentinel tip's tree as a single commit.**
      Use `git read-tree` to set the index to the sentinel
      tip's tree, then commit the working tree state.

```bash
git read-tree "$SENTINEL_TIP"
git checkout -- .
git add -A
git status
```

      Expected: all 206 files staged as a large addition on
      top of main.

- [ ] **Step 5: Create the squash commit.**

```bash
git commit -m "$(cat <<'EOF'
chore(merge): squash sentinel/monorepo-plan tip onto main

This is the starting point for the sentinel-to-main merge
plan at docs/superpowers/plans/2026-04-08-sentinel-to-main-
merge.md. The tree matches `sentinel/monorepo-plan` tip
(commit 19df998) exactly.

This commit is NOT intended to land on main. It exists as a
working tip from which individual chunks are extracted into
short-lived `pr/<chunk>` branches, PR'd, and squash-merged
into main one at a time. After each PR merges, this branch
rebases onto the advanced main and the remaining delta
shrinks.

252 commits of sentinel history are retained on the
`sentinel/monorepo-plan` branch so nothing is garbage-
collected. That branch is frozen (no new work) for the
duration of this plan.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: Verify the tree matches sentinel tip
      byte-for-byte.**

```bash
git diff --stat "$SENTINEL_TIP" HEAD
```

      Expected: empty output (trees are identical).

- [ ] **Step 7: Verify the build.**

```bash
nix flake check 2>&1 | tail -5
```

      Expected: `all checks passed!`. If not, STOP and
      report `BLOCKED` — the squash broke something.

```bash
devenv test 2>&1 | tail -10
```

      Expected: green. Same stop condition.

- [ ] **Step 8: Push the new branch.**

```bash
git push origin sentinel/main-catchup-2026-04-08
```

      Expected: pushes cleanly. Ruleset doesn't block this
      branch (only `main` is protected).

### Task 1.2: Create a PR body template

**Files:**

- Create: `dev/notes/pr-template.md`

**Steps:**

- [ ] **Step 1: Write the template.** This is local dev
      documentation, not a GitHub PR template (the repo
      doesn't have one yet — deferred). It's a reference
      for agentic workers creating PRs in the loop.

      Content:

```markdown
# PR body template (sentinel-to-main merge)

Use this structure when running `gh pr create` from a
`pr/<chunk>` branch during the sentinel-to-main merge.

    ## Summary

    <1-2 sentences describing what this chunk introduces to main.>

    ## Scope

    **Files added:**
    - `path/to/file.nix`
    - ...

    **Files modified:**
    - `path/to/other.nix` — what changed and why
    - ...

    **Dependencies:**
    - Depends on previously-merged chunks: <list or "none (first chunk)">
    - Blocks subsequent chunks: <list>

    ## Verification

    - `nix flake check` — green
    - `devenv test` — green
    - Any chunk-specific manual tests (e.g., built a package,
      ran a module-eval check, etc.)

    ## Backlog items (if any)

    - Any Copilot or review feedback deferred to a backlog
      entry in `docs/plan.md`. Link to the item.

    ---

    Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

      The leading 4-space indent is so the entire template is
      a single fenced code block in the .md file — the
      worker copy-pastes from the fenced block into the
      `gh pr create --body "..."` argument verbatim, preserving
      the markdown structure inside the PR body.

- [ ] **Step 2: Commit the template.**

```bash
treefmt dev/notes/pr-template.md
git add dev/notes/pr-template.md
git commit -m "$(cat <<'EOF'
docs(dev): add PR body template for sentinel-to-main merge

Reference template for agentic workers creating PRs during
the sentinel-to-main merge plan. Not a GitHub PR template
(the repo doesn't have one yet — deferred) — just a local
convention for consistency across the ~15-25 PRs the merge
loop will produce.

Structure: Summary, Scope, Dependencies, Verification,
Backlog. All PRs follow this shape so reviewers (Copilot
and human) know where to look.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Push.**

```bash
git push origin sentinel/main-catchup-2026-04-08
```

---

## Phase 2: Audit and chunk proposal

**Scope:** Produce a static file-tree audit of the sentinel
tip and group every tracked file into a bottom-up chunk
proposal. Write the proposal to a dev note. **Pause for user
approval before any PRs open.**

### Task 2.1: Static file-tree audit

**Files:**

- Create: `dev/notes/merge-chunks-2026-04-08.md`

**Steps:**

- [ ] **Step 1: Inventory the sentinel tree.**

```bash
git ls-tree -r --name-only HEAD > /tmp/sentinel-files.txt
wc -l /tmp/sentinel-files.txt
```

      Expected: ~200+ tracked files.

- [ ] **Step 2: Group files by directory and purpose.** Walk
      through the file list and assign each file to a chunk.
      Use the bottom-up order below. Don't invent chunks —
      stick to this list unless a file genuinely doesn't
      fit. When in doubt, bias toward FEWER chunks (each
      chunk should be a meaningful PR-sized delta).

      **Chunk 1: Flake scaffold + pre-commit hooks**
      - `flake.nix` (but just the skeleton — `outputs`,
        `inputs`, maybe the `checks` wiring — NOT the full
        `packages` attrset)
      - `flake.lock` (in final form — needed for the other
        chunks to evaluate)
      - `.gitignore`
      - `.cspell/project-terms.txt`
      - `cspell.json`
      - `.pre-commit-config.yaml` (if present — or devenv
        `git-hooks.hooks` via devenv.nix)
      - `treefmt.nix`
      - `devenv.nix` (base only — no ai config yet, no
        claude.code config)
      - `devenv.yaml`
      - Lock files if any

      **Important:** Chunk 1 should produce a `flake.nix`
      that evaluates cleanly but has EMPTY package outputs.
      Subsequent chunks add to it. This is the "forward
      reference" risk — if Chunk 1's flake.nix references
      `./packages/git-tools` that doesn't exist yet, it'll
      fail. Solution: Chunk 1's flake.nix is a minimal
      scaffold; later chunks EXTEND it via additional
      entries.

      **Risk note:** `flake.nix` is a single file that can
      only be modified, not split. Options:
      - (a) Chunk 1 lands a minimal flake.nix. Subsequent
        chunks `Edit` it to add entries.
      - (b) Chunk 1 lands the FULL flake.nix. Subsequent
        chunks add only the `packages/`/`modules/` files.
        flake.nix references them via `./packages/...` but
        nix doesn't error on a missing referenced file
        until it's ACTUALLY evaluated. So if Chunk 1's
        flake.nix references `./packages/git-tools` that
        doesn't exist on disk yet, `nix flake show` will
        fail on it but `nix flake check` may or may not
        depending on which outputs get evaluated.
      - (c) Each chunk has its own `flake.nix` edit as part
        of the chunk's file set. So Chunk 3 includes
        `packages/git-tools/*.nix` AND the flake.nix entry
        that registers them.

      **Recommendation: option (c)**. Each chunk brings the
      files it needs AND the flake.nix edit to wire them in.
      This means `flake.nix` gets modified in every chunk,
      but the modifications are additive (never removing
      anything a prior chunk added). Conventional
      commit-wise, every chunk touches `flake.nix` with
      its own scope (e.g. `build(flake): register
      git-tools overlay`) as part of the chunk's commit.

      **Chunk 2: Shared lib primitives**
      - `lib/fragments.nix`
      - `lib/ai-common.nix`
      - `lib/buddy-types.nix`
      - `lib/hm-helpers.nix`
      - `lib/mcp.nix`
      - `lib/options-doc.nix`
      - `lib/devshell.nix` (if present)
      - `flake.nix` edit to expose `lib` outputs
      - No tests yet — the test infrastructure comes with
        Chunk 9.

      **Chunk 3: Fragment pipeline + fragments-ai transforms**
      - `packages/fragments-ai/` (full tree)
      - `dev/fragments/monorepo/` (all 5 remaining
        always-loaded fragments)
      - `dev/fragments/flake/` + `dev/fragments/packaging/`
        + `dev/fragments/nix-standards/` (new scoped
        categories from Phase 2.5 of architecture-foundation)
      - `dev/fragments/pipeline/` (including the merged
        `generation-architecture.md`)
      - `dev/generate.nix`
      - `dev/tasks/generate.nix`
      - `flake.nix` edit to expose `fragments-ai` overlay
        and `packages.instructions-*` derivations

      **Chunk 4: Content packages**
      - `packages/coding-standards/` (full tree)
      - `packages/stacked-workflows/` (skills, references,
        fragments — full tree including the SKILL.md files
        and the hardened `builtins.path` filter)
      - `packages/fragments-docs/` (page generators +
        snippets)
      - `flake.nix` edit to expose content-package overlays

      **Chunk 5: Overlay — git-tools**
      - `packages/git-tools/` (full tree: agnix, git-absorb,
        git-branchless, git-revise, default.nix, sources.nix,
        hashes.json)
      - `nvfetcher.toml` entries for the 4 Rust packages
      - `flake.nix` edit to expose `packages.{agnix,git-*}`
      - **Includes the `ourPkgs` pattern fix from Phase 3.3
        of architecture-foundation (this is the state at
        sentinel tip).**

      **Chunk 6: Overlay — mcp-servers (single PR, 14
      servers)**
      - `packages/mcp-servers/` (full tree: 14 server .nix
        files, default.nix, sources.nix, hashes.json, locks/)
      - `nvfetcher.toml` entries for all 14 servers
      - `flake.nix` edit to expose
        `packages.{context7,effect,...}-mcp`
      - **Includes the `ourPkgs` pattern fix from Phase
        3.4/3.5/3.6 of architecture-foundation.**

      **Chunk 7: Overlay — ai-clis**
      - `packages/ai-clis/` (full tree: claude-code,
        copilot-cli, kiro-cli, kiro-gateway, any-buddy,
        default.nix, sources.nix, hashes.json, locks/,
        fragments/dev/)
      - `nvfetcher.toml` entries for the AI CLI packages
      - `flake.nix` edit to expose `packages.claude-code`
        etc.
      - **Includes the `ourPkgs` pattern fix from Phase 3.7
        of architecture-foundation.**

      **Chunk 8: HM modules — ecosystem CLIs**
      - `modules/copilot-cli/`
      - `modules/kiro-cli/`
      - `modules/mcp-servers/` (HM side, not the overlay)
      - `modules/claude-code-buddy/`
      - `modules/stacked-workflows/`
      - `flake.nix` edit to expose
        `homeManagerModules.{copilot-cli,kiro-cli,mcp-servers,
        claude-code-buddy,stacked-workflows}`

      **Chunk 9: HM module — unified ai + fragments/dev**
      - `modules/ai/` (full tree including
        `fragments/dev/ai-module-fanout.md`)
      - `modules/default.nix`
      - `flake.nix` edit to expose
        `homeManagerModules.{ai,default}`
      - Depends on Chunks 3, 5, 6, 7, 8 (fragments, packages,
        other modules).

      **Chunk 10: DevEnv modules**
      - `modules/devenv/` (full tree: ai.nix, copilot.nix,
        kiro.nix, claude-code-skills/, mcp-common.nix,
        default.nix)
      - `dev/fragments/devenv/` (files-internals.md,
        file-internals scoped rule)
      - `flake.nix` edit to expose `devenvModules.*`

      **Chunk 11: Checks**
      - `checks/module-eval.nix`
      - `checks/devshell-eval.nix`
      - `checks/cache-hit-parity.nix`
      - `inputs.nixpkgs-test` addition in `flake.nix`
        (this is the one place flake.nix gets an input
        added)
      - `flake.nix` edit to wire checks into
        `checks = forAllSystems ...`

      **Chunk 12: Doc site — prose + structure**
      - `docs/book.toml`
      - `docs/.gitignore`
      - `dev/docs/` (full tree: index, getting-started,
        concepts, guides, troubleshooting, SUMMARY)
      - `flake.nix` edit to expose
        `packages.{docs-site-prose,docs-site}`

      **Chunk 13: Doc site — generators (fragments-docs
      pages + options search)**
      - `packages/fragments-docs/pages/` (if not already in
        Chunk 4)
      - Options-search wiring in `flake.nix`
      - `packages.docs` assembly
      - `dev/docs/contributing/` architecture pages

      **Chunk 14: Dev helpers and scripts**
      - `dev/scripts/measure-context.sh`
      - `dev/update.nix`
      - `dev/data.nix`
      - `dev/references/`
      - `dev/notes/` (except the merge-specific ones created
        by this plan)
      - `dev/skills/` (if present)

      **Chunk 15: Architecture fragments (scoped, per-file)**
      - `packages/ai-clis/fragments/dev/` (buddy-activation,
        claude-code-wrapper)
      - `modules/ai/fragments/dev/` (if not in Chunk 9)
      - `dev/fragments/ai-skills/`
      - `dev/fragments/hm-modules/`
      - `dev/fragments/mcp-servers/`
      - `dev/fragments/overlays/`
      - `dev/fragments/stacked-workflows/`

      **Chunk 16: CI workflows**
      - `.github/workflows/ci.yml`
      - `.github/workflows/docs.yml`
      - `.github/workflows/update.yml`

      **Chunk 17: Top-of-tree meta**
      - `CLAUDE.md`
      - `AGENTS.md`
      - `README.md` (if tracked — check gitignore)
      - `CONTRIBUTING.md` (if tracked)
      - `LICENSE`
      - `docs/plan.md` (the sentinel backlog — leave this
        OUT if you want main to stay clean of sentinel-only
        tracking; include if you want main to become the
        new sentinel source)
      - `docs/superpowers/` (optional — same decision as
        plan.md)

      **Note:** Chunks may need re-ordering if dependencies
      turn out to be wrong. The audit is the first draft —
      user approval in Task 2.2 locks it in.

- [ ] **Step 3: Write the chunk proposal to
      `dev/notes/merge-chunks-2026-04-08.md`.** Structure:

```markdown
# Sentinel → Main Merge: Chunk Proposal (2026-04-08)

Produced by the static file-tree audit in Phase 2 Task 2.1 of
`docs/superpowers/plans/2026-04-08-sentinel-to-main-merge.md`.

## Chunking strategy

Bottom-up by dependency order. Each chunk bundles its files
plus the `flake.nix` edit that registers them with the flake
outputs. No forward references between chunks. No docs-only
catchup commits — docs travel with their feature chunk.

## Chunk list

### Chunk 1: <name>

- **Files:** <list>
- **Lines:** ~N added
- **Depends on:** none
- **PR title:** `<type>(<scope>): <subject>`
- **Rationale:** <why this is a chunk, what it unblocks>

### Chunk 2: <name>

...

## Notes

- Chunks with [SPLIT?] tags may need splitting if the diff is
  too large for a single reviewable PR (>1000 lines of net
  add).
- Chunks with [MERGE?] tags may be consolidated if adjacent
  chunks share the same reviewer concerns.
- Order may shift based on user approval in Task 2.2.

## Out of scope for the merge

- `sentinel/monorepo-plan` branch itself (frozen, not
  touched)
- Open PRs or discussions on main
- Any future sentinel work (assumed no concurrent edits)
```

      Fill in the details for each of the 17 chunks above,
      with actual file lists and rough diff sizes from
      `git diff --stat` against main.

- [ ] **Step 4: Commit the proposal.**

```bash
treefmt dev/notes/merge-chunks-2026-04-08.md
git add dev/notes/merge-chunks-2026-04-08.md
git commit -m "$(cat <<'EOF'
docs(dev): sentinel-to-main merge chunk proposal

Static file-tree audit output from Phase 2 Task 2.1 of the
sentinel-to-main merge plan. Groups all 206 tracked files in
the sentinel tip into 17 bottom-up chunks by dependency
order. Each chunk bundles its files plus the flake.nix edit
that registers them — no docs-only catchup commits, no
forward references.

Locked in by user approval in Task 2.2 before the PR loop
starts. May be updated in-place if execution reveals
dependency issues.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin sentinel/main-catchup-2026-04-08
```

### Task 2.2: User approval checkpoint

**Files:** None modified.

- [ ] **Step 1: Present the chunk list to the user.**
      Summarize each chunk in ~1 sentence with its rough
      diff size. Flag any chunks that feel too large
      (>1000 lines) or too small (<50 lines).

- [ ] **Step 2: Wait for approval.** User says "proceed" or
      "reorder these" or "split X". Update the proposal doc
      in place if changes are requested. Commit the updated
      doc as a separate commit on the catchup branch.

- [ ] **Step 3: Only after explicit approval, move to
      Phase 3.**

---

## Phase 3: PR loop

**Scope:** For each approved chunk in order, create a
short-lived `pr/<chunk>` branch from the latest `origin/main`,
stage only that chunk's files from the catchup branch, commit,
open a PR, run through review/fix/merge, then rebase the
catchup branch onto the advanced main.

**Key constraints:**

- **One PR at a time.** Never open multiple PRs concurrently.
  They stack awkwardly and Copilot review quality degrades.
- **Wait for CI green before merging.** The `ci.yml` workflow
  runs `nix flake check` + `devenv test`.
- **Wait for Copilot review to complete.** Copilot auto-
  reviews on PR open; poll every 60s via `gh pr view
<number> --json reviews`.
- **User review gate.** User reviews on GitHub after Copilot.
  Don't merge until user approves or explicitly says
  "merge".

### Task 3.1: Per-chunk loop template

This template applies to every chunk. The task list below
iterates this template N times (once per chunk).

**Per-chunk steps:**

- [ ] **Step 1: Update main locally.**

```bash
git fetch origin main
```

- [ ] **Step 2: Create the PR branch from the LATEST
      `origin/main`.**

      For the first chunk, `origin/main` is at `688b56a`.
      For subsequent chunks, it's wherever the prior PR
      merged to.

```bash
CHUNK_NAME="<chunk-slug>"  # e.g. "flake-scaffold"
git checkout -b pr/${CHUNK_NAME} origin/main
```

- [ ] **Step 3: Stage only the chunk's files.** Use
      `git checkout <catchup-branch> -- <paths>` to copy the
      chunk's files from the catchup branch into the working
      tree of the pr/ branch.

```bash
CATCHUP=sentinel/main-catchup-2026-04-08

# For each file or directory in the chunk:
git checkout "$CATCHUP" -- path/to/file.nix
git checkout "$CATCHUP" -- path/to/directory/

# For the flake.nix edit specific to this chunk:
# Manually `git checkout $CATCHUP -- flake.nix` and then
# `git restore --staged flake.nix` + manual edit to include
# ONLY this chunk's additions. OR apply a pre-prepared patch.
```

      **Important:** flake.nix is the tricky file — it's
      modified by nearly every chunk. Options:
      - (a) Checkout the catchup's flake.nix and manually
        remove the entries that belong to LATER chunks.
      - (b) Maintain an incremental flake.nix that starts
        minimal in Chunk 1 and grows per chunk. This
        requires careful tracking of what each chunk adds.

      Recommendation: (a). It's easier to subtract than to
      maintain parallel flake.nix versions.

- [ ] **Step 4: Verify the chunk builds.** After staging,
      run the flake check to make sure the chunk's own
      outputs evaluate.

```bash
nix flake check 2>&1 | tail -10
```

      Expected: green. If eval errors mention files from a
      LATER chunk, the flake.nix edit isn't scoped narrowly
      enough. Fix by reverting the LATER chunk's entries.

      If the check needs something from a LATER chunk to
      pass (e.g., a test references a module that doesn't
      exist yet), the chunking is wrong. STOP and update
      `dev/notes/merge-chunks-2026-04-08.md` accordingly,
      then re-discuss with the user.

- [ ] **Step 5: Run devenv test** (where applicable).

```bash
devenv test 2>&1 | tail -10
```

      Expected: green. Same stop conditions.

- [ ] **Step 6: Commit.** One commit per PR (1 PR = 1 commit
      after squash). The commit message subject becomes the
      PR title.

```bash
treefmt .
git add .
git commit -m "$(cat <<'EOF'
<type>(<scope>): <subject for chunk N>

<body explaining what this chunk adds and why. Include a
short dependency summary: "depends on chunks 1, 2, 3" or
"first chunk, no dependencies".>

<any notes relevant to reviewers — architectural decisions,
open questions, known limitations.>

Part of the sentinel-to-main merge (Chunk N of M). See
docs/superpowers/plans/2026-04-08-sentinel-to-main-merge.md
for the full plan.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 7: Push the branch.**

```bash
git push origin pr/${CHUNK_NAME}
```

- [ ] **Step 8: Open the PR.**

```bash
gh pr create \
  --base main \
  --head pr/${CHUNK_NAME} \
  --title "<commit subject>" \
  --body "$(cat <<'EOF'
## Summary

<1-2 sentences>

## Scope

**Files added:**
- ...

**Files modified:**
- ...

**Dependencies:**
- First chunk (or: depends on chunks 1, 2)

## Verification

- `nix flake check` — green
- `devenv test` — green

Part of the sentinel-to-main merge. Chunk N of M.
EOF
)"
```

      Capture the PR number in a variable for the rest of
      the task:

```bash
PR_NUM=$(gh pr view --json number -q .number)
echo "PR #$PR_NUM opened"
```

- [ ] **Step 9: Wait for Copilot review.** Poll every 60s:

```bash
while true; do
  STATE=$(gh pr view $PR_NUM --json reviews -q '.reviews[] | select(.author.login == "copilot-pull-request-reviewer[bot]") | .state' 2>/dev/null || echo "")
  if [ -n "$STATE" ]; then
    echo "Copilot review state: $STATE"
    break
  fi
  echo "Waiting for Copilot review..."
  sleep 60
done
```

      (Adjust the bot login name if it differs in practice —
      check the first PR manually to confirm the login.)

- [ ] **Step 10: Wait for CI to complete.**

```bash
gh pr checks $PR_NUM --watch
```

      Expected: all checks green. If any fail, investigate
      and fix.

      For flake check failures: rebuild locally, debug, push
      a fix commit to the same `pr/<chunk>` branch.

      For docs.yml failures (preview deploy): usually
      unrelated to the chunk content — check the workflow
      log, may be a transient issue.

- [ ] **Step 11: Process Copilot's review comments.** Use
      `gh pr view $PR_NUM --json reviews,comments` to get
      the feedback. For each comment:

      - **Minor issues**: fix inline. Commit and push to the
        same branch. Add a reply resolving the comment via
        `gh api --method POST
        /repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies
        -f body='Fixed in commit abcd1234'`.
      - **Major issues**: file as a backlog entry in
        `docs/plan.md` (via a SEPARATE commit on the catchup
        branch, NOT this PR — plan.md stays sentinel-tip
        only per feedback memory). Reply to the comment:
        "Filed as backlog item: <link to commit>. Fixing
        in a follow-up PR." Resolve the thread.
      - **Unclear**: escalate to the user. Pause the loop.

- [ ] **Step 12: Wait for user review.** User reviews on
      GitHub. User says "merge" or "address X first".

      - Fix any additional feedback from the user.
      - Once both Copilot's thread and user's thread are
        approved/resolved, proceed to merge.

- [ ] **Step 13: Merge the PR (squash).**

```bash
gh pr merge $PR_NUM --squash --delete-branch
```

      This deletes the `pr/<chunk>` branch on both local
      and origin after successful merge.

- [ ] **Step 14: Update main locally and rebase the catchup
      branch.**

```bash
git fetch origin main
git checkout sentinel/main-catchup-2026-04-08
git rebase origin/main
```

      Expected: rebase succeeds cleanly. The squash commit
      on the catchup branch gets reapplied on top of the
      new main; since the new main now contains the chunk's
      content, the rebase should result in an EMPTY
      incremental diff for the chunk's files (they're
      already in main).

      Force-push the catchup branch:

```bash
git push origin sentinel/main-catchup-2026-04-08 --force-with-lease
```

      (Force-push is safe here because the catchup branch is
      a working reference, not published content. The
      force-with-lease flag guards against concurrent writes
      we didn't see.)

- [ ] **Step 15: Report to user.** One-line update:
      "Chunk N of M merged (PR #<num>). Main caught up on
      <files>. Moving to next chunk."

- [ ] **Step 16: Repeat Steps 1-15 for the next chunk.**

### Task 3.2: Execute the loop

- [ ] For each approved chunk (after Task 2.2 approval),
      run Task 3.1's template. Expect ~15-25 iterations.

- [ ] Between chunks, **pause for user checkpoint approval**
      by default. User can batch-approve a run of mechanical
      chunks (e.g., "merge chunks 5-7 without pausing") to
      speed up.

---

## Phase 4: Cleanup

**Scope:** After all chunks merge, verify main content
matches sentinel tip, delete the catchup branch, update
plan.md, and resume backlog work.

### Task 4.1: Content verification

**Files:** None modified.

**Steps:**

- [ ] **Step 1: Fetch all branches.**

```bash
git fetch origin main sentinel/monorepo-plan sentinel/main-catchup-2026-04-08
```

- [ ] **Step 2: Diff main against the original sentinel
      tip.**

```bash
git diff --stat origin/main sentinel/monorepo-plan
```

      Expected:
      - Empty diff (main content == sentinel tip) if ALL
        chunks landed, including the final chunks for
        `docs/plan.md` and `docs/superpowers/`.
      - OR: a diff showing only `docs/plan.md` and
        `docs/superpowers/` if user opted to keep those
        sentinel-only.

      Verify the diff matches user intent.

- [ ] **Step 3: Run full build on main.**

```bash
git checkout origin/main
nix flake check
devenv test
nix build .#checks.x86_64-linux.cache-hit-parity
```

      Expected: all green. Main is now the functional
      equivalent of sentinel tip.

### Task 4.2: Branch cleanup

**Files:** None modified.

**Steps:**

- [ ] **Step 1: Decide sentinel promotion strategy.** Three
      options:

      (a) **Promote catchup branch to new sentinel.** Rename
      `sentinel/main-catchup-2026-04-08` to
      `sentinel/monorepo-plan-v2` (or keep the old name
      after force-resetting it — though force-reset of a
      pushed branch is awkward). Old `sentinel/monorepo-plan`
      stays frozen for historical reference.

      (b) **Rebase the old sentinel onto new main.** Take
      the old `sentinel/monorepo-plan` and rebase it onto
      updated main. The rebase should no-op for any commits
      whose content already landed via PRs (common case).

      (c) **Keep both.** Old sentinel frozen, catchup branch
      stays as the working reference. Future sentinel work
      branches off new main directly.

      Recommendation: (a) is cleanest. The user already said
      "deferred" in the initial directive, so pause for
      their decision here.

- [ ] **Step 2: Execute the chosen strategy.** Details
      depend on the user's choice.

- [ ] **Step 3: Delete the catchup branch on origin** (if
      not promoted):

```bash
git push origin --delete sentinel/main-catchup-2026-04-08
git branch -D sentinel/main-catchup-2026-04-08
```

### Task 4.3: Update plan.md and memory

**Files:**

- Modify: `docs/plan.md`
- Modify: `memory/project_plan_state.md`
- Modify: `memory/project_merge_to_main_strategy.md` (mark
  done)
- Delete: `docs/superpowers/plans/2026-04-08-sentinel-to-
main-merge.md` (this plan)
- Delete: `dev/notes/merge-chunks-2026-04-08.md` (chunk
  proposal, no longer needed)
- Delete: `dev/notes/pr-template.md` (or keep if useful for
  future PRs — user's call)

**Steps:**

- [ ] **Step 1: Mark the merge plan done in docs/plan.md.**
      Update "Next action" section to flag the next work
      item (likely `ai.claude.*` passthrough Tasks 3-7).

- [ ] **Step 2: Update `memory/project_plan_state.md`.**
      Note that main is now caught up. Flag the new default
      working branch (sentinel name) if the user promoted
      one.

- [ ] **Step 3: Update `memory/project_merge_to_main_
    strategy.md`** with an outcome note:

```markdown
## Status: COMPLETED 2026-04-08

Executed as docs/superpowers/plans/2026-04-08-sentinel-to-
main-merge.md. Main caught up to sentinel tip across N PRs
(~X mechanical, ~Y needed minor fixes, ~Z produced backlog
items). Final sentinel strategy: <option a/b/c>.
```

- [ ] **Step 4: Delete the plan file.** The sentinel
      workflow convention is that plans live only while
      executing.

```bash
git rm docs/superpowers/plans/2026-04-08-sentinel-to-main-merge.md
```

      Whether this deletion goes on sentinel OR on main
      depends on the sentinel strategy. If plan.md stays
      sentinel-only, the plan directory also stays sentinel-
      only.

- [ ] **Step 5: Commit close-out.**

```bash
git add docs/plan.md
git commit -m "$(cat <<'EOF'
docs(plan): close out sentinel-to-main merge

Main caught up to sentinel tip across N PRs landed 2026-04-08
through <end date>. Functional equivalence verified via
nix flake check + devenv test + cache-hit-parity on main.

Resume backlog work on sentinel from here. Next action:
ai.claude.* full passthrough (Tasks 3-7 + Task D) per
memory/project_ai_claude_passthrough.md.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: Push.**

```bash
git push
```

---

## Out of scope (do NOT do in this plan)

- Rebasing `sentinel/monorepo-plan` onto updated main. That's
  deferred; the old sentinel stays frozen.
- Concurrent sentinel work. Assume nothing lands on
  `sentinel/monorepo-plan` between Phase 1 and Phase 4.
- Opening multiple PRs at once to speed things up. Always
  one at a time.
- Using `/stack-submit` or other batch-PR tooling. Each PR
  is created individually via `gh pr create`.
- Refactoring any file beyond what the original sentinel tip
  contained. The merge is a literal content transplant, not
  a cleanup pass.
- Addressing backlog items inline. Every deferred item gets
  a plan.md entry and a follow-up PR (or stays as backlog).
- GitHub PR templates. The repo doesn't have one; we're not
  adding one in this plan (deferred backlog item).

---

## Verification protocol (end of plan)

After Phase 4.3 closeout:

- [ ] `nix flake check` green on `origin/main`
- [ ] `devenv test` green on `origin/main`
- [ ] `nix build .#checks.x86_64-linux.cache-hit-parity` green
      on `origin/main`
- [ ] `git diff --stat origin/main sentinel/monorepo-plan`
      matches user intent (empty OR only plan.md/superpowers
      per chosen strategy)
- [ ] All Copilot reviews closed or resolved per PR
- [ ] All user reviews approved per PR
- [ ] plan.md "Next action" updated to next TOP-priority
      item (likely `ai.claude.*` passthrough)

## Commit count target

~20-30 commits total across all PRs plus cleanup work.
Per-chunk: 1 commit becomes 1 squash on main. Catchup branch
cleanup commits don't count against main. Ballpark: 17
chunks → 17 PRs → 17 squash commits on main, plus minor
fix-up commits on PR branches before merge.

## After this plan

Main is caught up. Sentinel is frozen (old name) or rolled
forward (promoted catchup branch). Backlog resumes:

- **`ai.claude.*` full passthrough** — Tasks 3-7 (memory,
  settings, mcpServers, skills, plugins) + Task D (devenv
  mirror). Draft a fresh plan from
  `memory/project_ai_claude_passthrough.md`.
- Other TOP-priority items remaining: consolidate fragment
  enumeration, drop standalone claude-code-buddy module,
  bundle any-buddy, claude-code npm contingency monitoring,
  DISABLE_AUTOUPDATER wrapper env.

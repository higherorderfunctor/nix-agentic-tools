---
name: living-workflow
description: >-
  Use to create, resume, or groom a "living plan" — a self-contained, resumable
  work plan whose machine state lives outside any repo (so it survives worktree
  teardown) and whose protocol is versioned and carried across Claude Code, Kiro
  CLI, and Claude web. Use when starting a multi-session plan, resuming one from
  its state.json, or grooming the living-workflow backlog. Triggers: "living
  plan", "living workflow", "rolling backlog", "resume the plan", "groom the
  backlog".
argument-hint: "<create | resume | groom> [workflow-name]"
disable-model-invocation: false
compatibility: "CLI mode needs a git repo; degrades to document-only in web mode"
---

# Living-workflow

A lightweight router for the living-plan workflow: **create** a new plan, **resume** an existing
one, or **groom** the living-workflow backlog. The full protocol lives in `references/` and is
loaded **progressively** — this file only routes; do not restate the protocol here.

## State root (CLI mode)

Machine-owned working state (`state.json` + the WAL journal, and — for the backlog — its `entries/`)
lives **out of any repo** under an XDG base:

- An **ordinary plan** is keyed by the clone it runs in:

  ```
  <state-root> = @XDG_STATE_BASE@/<clone-name>/<workflow-name>
  ```

- **THIS living-workflow backlog** (the framework channel) is a **first-party override** with **no
  clone segment** — it pairs with this installed skill (machine-global), so ALL living-workflow
  feedback lands in the ONE backlog regardless of which repo you reflect from:

  ```
  <state-root> = @XDG_STATE_BASE@/living-workflow-backlog
  ```

Resolve the parts:

- `@XDG_STATE_BASE@` is **baked at install time** to a standard XDG location (never a hardcoded home
  path); use it exactly as written.
- `<clone-name>` (ordinary plans only) — the root clone worktree directory name, stable across every
  linked worktree of a clone; fall back to the current directory's name if git can't provide it:

  ```bash
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common_dir" ]; then
    clone_name="$(basename "$(dirname "$(realpath "$common_dir")")")"
  else
    clone_name="$(basename "$PWD")"   # fallback: root clone worktree directory name
  fi
  ```

  This uses git's **common dir** (its parent's basename) as the namespace KEY, not the location.

- `<workflow-name>` — the plan's name.

An ordinary plan's state is **clone-scoped**: it survives worktree teardown and is shared across
worktrees of one clone running the same-named workflow. THIS backlog is **clone-less** (the
first-party override above) — one machine-global location. (Web / no-repo mode has no repo and no
XDG root — it keeps the in-doc state block; see the master.)

## Entry points

### Resume a plan (the most common)

1. Compute `<state-root>` (above) and read `<state-root>/state.json` plus its WAL journal.
   `current_position.next_action` is the authoritative steer; the register (`open_items`) is the
   live truth.
2. Load the **run-time** context only: `references/living-plan-bootstrap.md` (the master protocol) and
   `references/state.schema.json` (the harness). Do **not** load the changelog or the backlog-rules
   doc on a resume.

### Create a plan

1. Load `references/living-plan-bootstrap.md` + `references/state.schema.json`.
2. Follow the master's COLD START: resolve `execution_mode` (cli vs web-run), materialize the
   out-of-repo working dir at `<state-root>/`, init `state.json` from the schema, and validate it.

### Groom the backlog (edit-time only)

1. Read the backlog state from its **clone-less** root `@XDG_STATE_BASE@/living-workflow-backlog/`
   (`state.json` + the WAL journal + `entries/`). Load `references/living-workflow-backlog.md` (the
   grooming loop + backlog-specific rules) **in addition** to the master — this is the ONLY entry
   point that loads the backlog-rules doc.
2. Follow the grooming loop (cold-start reconcile → evaluate each entry → classify fold target →
   fold inline → drain), obeying the master's REFLECTION MODE and never-self-groom rules.

## Progressive disclosure

- **run-time** (create / resume): load `references/living-plan-bootstrap.md` +
  `references/state.schema.json`.
- **edit-time** (groom): ALSO load `references/living-workflow-backlog.md`.
- **modify-time** (reconcile a version pin, or migrate across a master version): load
  `references/changelog.md` (the judgment-based migration guide) — never on a run.

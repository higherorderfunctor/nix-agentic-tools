# Kickoff: should the factory emit steering/rules as copies instead of symlinks?

Created 2026-07-21 as the handoff from the session that landed `f12aa5f1`
(repo-local single-mechanism materialization) and `88f1fc8b` (comment
corrections). Branch: `refactor/ai-factory-architecture`.

**This is a decision brief, not an implementation task.** The previous session
deliberately stopped short of converting the factory. What is wanted first is a
genuine tradeoff analysis, because the obvious port has a real cost that was
only discovered at the end.

---

## Background in one paragraph

This repo's own generated instruction files were just moved off devenv `files.*`
(store symlinks) onto real-file copies materialized on shell entry, because Kiro
discovers steering by scanning a directory and the scan skips symlinks. The
**factory** — `packages/kiro-cli/lib/mkKiro.nix` and
`packages/claude-code/lib/mkClaude.nix` — still emits steering and rules as
`files.*` (devenv) / `home.file` (HM) entries, i.e. store symlinks, for every
downstream consumer. If the Kiro premise holds, the defect keeps shipping
outward even though this repo is now fine.

## The blocker that stopped the port

`checks/module-eval.nix:529-589` asserts on the **declarative attr shape**:

```nix
evaluated.config.home.file.".kiro/steering/instructions.md"
evaluated.config.files.".kiro/steering/AGENTS.md"
evaluated.config.home.file ? ".config/kiro/steering/"   # negative assertion
```

Converting the emitters to imperative `enterShell` (devenv) / `home.activation`
(HM) copies would leave those assertions inspecting **script text instead of an
attrset**. That is a real loss of test surface, across 6 emitters (4 devenv + 2
HM).

---

## What to actually investigate

### 1. Is the premise even true? (do this first — it gates everything)

Nobody has empirically tested whether Kiro reads a **symlinked steering file**.
The evidence today is:

- `kirodotdev/Kiro#2921` — open, "Follow symlinks for steering docs"
- `kirodotdev/Kiro#8121` — "Only a real file copy at `.kiro/steering/AGENTS.md`
  works"
- The repo's own (now corrected) comment claimed the opposite for months
- The hooks case IS confirmed in-repo

An actual probe against the installed Kiro would settle it. If steering symlinks
turn out to work, the whole conversion is unnecessary and the correct outcome is
to document that and close this out. **Do not skip this step to get to the fun
part.**

### 2. The tradeoff that actually matters: declarative vs imperative

This is what needs depth. At minimum:

| Axis          | `files.*` / `home.file` (today)                                   | imperative copy                                                   |
| ------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------- |
| Testability   | attrset, asserted directly by module-eval                         | script text                                                       |
| Lifecycle     | HM tracks managed files and **removes them on generation switch** | untracked; orphans linger when a consumer drops a rule            |
| Staleness     | symlink always points at current store path                       | copy is a point-in-time snapshot                                  |
| User edits    | impossible (read-only store)                                      | possible, and silently clobbered or preserved depending on design |
| Kiro reads it | **maybe not** (the whole problem)                                 | yes                                                               |
| Failure mode  | wrong content is impossible                                       | a failed copy leaves the old file in place, silently              |

The orphan/lifecycle row is the one most likely to be underestimated. This repo
solved it locally with `sync_dir` pruning, but a consumer's `~/.kiro/steering/`
may legitimately contain files the factory does not own, so blind pruning there
is **not** safe. Work out what is.

### 3. Is there a shape that keeps both?

The most promising direction, and the reason the port was deferred rather than
done: **keep the attrset as the source of truth and derive the copy script from
it.** Then `module-eval` still sees a structured value to assert on, and the
imperative step is a pure function of that value.

Sketch to evaluate (not endorse):

```nix
steeringFiles = { "<name>.md" = "<rendered text>"; ... };   # assertable
# devenv: enterShell installs each entry
# HM:     home.activation installs each entry
```

Open questions for that shape: where does the attrset live so both backends and
the checks can reach it; does it need to be an option (so consumers can
inspect/override) or just a `let` binding; and what do the existing assertions
become.

### 4. Backend asymmetry

devenv has `enterShell`; HM does not. HM needs `home.activation`, which has its
own constraints — including a recorded one in this project: **never `exit`
inside a `home.activation` block** (it aborts the whole activation; inline into
the `set -eu` script instead). Also determine ordering vs `home.file` linking,
and whether HM's own file cleanup would delete a copy it no longer manages.

### 5. Scope boundaries to decide explicitly

- **Claude Code does NOT need this.** Its docs explicitly support symlinks for
  `CLAUDE.md` and `.claude/rules/` ("symlinks are resolved and loaded normally,
  circular symlinks detected"). Converting `mkClaude.nix` would be uniformity,
  not a bug fix, and would change behavior for every consumer with nothing
  forcing it. Decide deliberately rather than by momentum.
- **Skills** (`.kiro/skills/**`) are emitted by a separate walker and are the
  same suspected defect class. In or out?
- **Agents** (`<configDir>/agents/`) — same question.

---

## Useful starting points

| What                                | Where                                                        |
| ----------------------------------- | ------------------------------------------------------------ |
| Steering/rules emitters (devenv, 4) | `packages/kiro-cli/lib/mkKiro.nix` ~:815-870                 |
| Steering emitters (HM, 2)           | same file, ~:612-670                                         |
| The real-file precedent (hooks)     | same file, ~:790-813 — already does the copy, with rationale |
| Claude emitters                     | `packages/claude-code/lib/mkClaude.nix` ~:686-726            |
| The assertions at risk              | `checks/module-eval.nix:529-589`                             |
| How this repo solved it locally     | `dev/tasks/generate.nix` (`sync_file` / `sync_dir`)          |
| Why, written up                     | `docs/plans/instruction-file-single-mechanism.md`            |
| Corrected claim + upstream refs     | `packages/kiro-cli/lib/mkKiro.nix` ~:794                     |

## Definition of done for the next session

A recommendation with evidence, not code: premise confirmed or refuted; the
tradeoff table filled in with what is actually true here; a verdict on whether a
shape exists that keeps the assertions; and an explicit scope call on Claude /
skills / agents. Implementation only after that lands.

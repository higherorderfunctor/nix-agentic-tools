# Single-mechanism materialization for generated instruction files

Status: **LANDED (repo-local) / factory conversion DEFERRED** · 2026-07-21 ·
branch `refactor/ai-factory-architecture`

- `f12aa5f1` — repo-local single-mechanism refactor. Verified: all four store
  paths bit-identical across the extraction (mechanism-only change); deleting
  `CLAUDE.md` + `.claude/rules/` + `.kiro/steering/` and entering the shell
  restored 1 + 15 + 16 files, zero symlinks; repeat runs write nothing; the
  `enterTest` guard was sabotage-tested and fires.
- `88f1fc8b` — corrected the false "steering loads fine as symlinks" claim in
  `mkKiro.nix` and `packages/kiro-cli/docs/kiro-auto-memory.md`.
- **NOT done:** converting the factory emitters. See "Deferred" at the end —
  this is the open question for the next session.

Two bugs found and fixed during implementation, worth remembering: `cmp` lives
in **diffutils**, not coreutils (the wrong path failed _silently_, because the
call sits in an `if` condition where a missing binary is just a false branch and
errexit never fires); and `.gitignore` listed `AGENTS.md` even though it is
git-tracked.

## Goal (from the user)

> don't commit generated files unless it's for copilot (github instructions).
> they should generate when you enter the repo or reload devenv.

Plus: one mechanism everywhere, because Kiro cannot follow store symlinks.

## Resulting policy

| Committed (generated, checked in) | Generated on entry (gitignored) |
| --------------------------------- | ------------------------------- |
| `README.md`, `CONTRIBUTING.md`    | `CLAUDE.md`                     |
| `AGENTS.md` (Copilot reads it)    | `.claude/rules/*.md`            |
| `.github/copilot-instructions.md` | `.kiro/steering/*.md`           |
| `.github/instructions/*.md`       |                                 |

## The bug being fixed

Two producers write the same paths:

1. `devenv.nix:286-307` `files.*` → **symlinks** into `/nix/store`
2. `dev/tasks/generate.nix` `generate:instructions:*` → **real file copies**

### Severity: latent, not active (corrected)

An earlier draft of this plan claimed Kiro's steering is broken right now. **It
is not.** `createSymlinkScript` (`files.nix:110-111`) skips a pre-existing
regular file with `Conflicting file … >&2`, and the generate tasks got there
first. Verified via `.devenv/state/files.json`: `managedFiles` (133 entries)
contains `CLAUDE.md` and the 15 `.claude/rules/*.md`, but **not** `AGENTS.md`,
`.github/copilot-instructions.md`, `.github/instructions/*`, or
`.kiro/steering/*`.

So today the tree is all regular files and devenv quietly logs a conflict on
every shell entry. The hazard is that this is **accidental**, not designed:
delete `.kiro/steering/` (or let `devenv:files:cleanup` drop a managed symlink)
and the next shell entry recreates it as a store symlink that Kiro cannot read —
silently, in a gitignored directory no check looks at.

### The content divergence is near-total

`files.*` writes raw `gen.*` text; the tasks copy `runFmt`-formatted derivation
output. Building the raw text and diffing against the tree: **`AGENTS.md`, all
15 `.claude/rules/*`, all 16 `.kiro/steering/*`, and `copilot-instructions.md`
all differ.** Only `CLAUDE.md` (24 bytes, `@AGENTS.md`) matches. Any naive flip
to `copyMode = "copy"` on the current `.text` entries would therefore corrupt
essentially every generated file.

### The repo currently documents the opposite, and is wrong

`packages/kiro-cli/lib/mkKiro.nix:794-795`:

> "Only hooks need this — steering and agents load fine as symlinks."

Its own stated mechanism refutes it: Kiro discovers by scanning a directory with
`read_dir`, which _skips_ symlinks. Steering is discovered by the same scan.
Upstream corroborates: kirodotdev/Kiro#2921 (open, "Follow symlinks for steering
docs"), #8121 ("Only a real file copy … works").

**Fix that comment in the same commit.** Also echoed at
`lib/options-doc.nix:156-158`.

## The change

### 1. NEW `dev/instructions.nix`

Extract `fmtDrv`, `runFmt` and the four `instructions-*` derivations out of
`flake.nix` into one module imported by **both** `flake.nix` and `devenv.nix`.
This is what stops the two producers rendering different bytes — they become the
same derivation.

Move the four derivation bodies **verbatim**. Collapsing them into an
`install -D` helper is a worthwhile follow-up but is deliberately deferred:
keeping them byte-for-byte lets the migration be proven by _store-path hash
equality_ rather than a diff, so this commit changes the mechanism and nothing
else.

### 2. `devenv.nix`

- Delete the entire `files = …` block (`:284-307`). Skills / settings.json / MCP
  JSON keep their own `files.*` entries elsewhere — untouched.
- Replace the now-orphaned `gen` binding with `instr` (`deadnix` would otherwise
  fail the commit).
- `enterTest`: add a guard asserting the six representative outputs exist **and
  are not symlinks**. `test -f` alone is insufficient — it follows symlinks, so
  a regression to symlink mode would pass it.

### 3. `dev/tasks/generate.nix`

Add `sync_file` / `sync_dir` helpers and a leaf task:

```
generate:instructions:materialize
  after  = [ "devenv:files:cleanup" ]
  before = [ "devenv:enterShell" ]
```

`after devenv:files:cleanup` so that if cleanup ever drops a managed symlink,
materialization repairs it within the same shell entry — the migration can never
leave the tree short a gitignored file.

Deliberately **not** `before devenv:treefmt:run`: an unresolved task name in
`before` is a hard error (`Error::TasksNotFound`), so that would couple this
task to `treefmt.enable` staying true. It is also unnecessary — the content is
already a treefmt fixed point, so either order converges.

Deliberately a **leaf**, not the mid-graph `generate:instructions` aggregate:
devenv's `RunMode::All` walks incoming edges transitively from the root but
outgoing edges only from the root (cachix/devenv#2337).

Properties that matter:

- **No `nix build` at shell entry** — `${instr.*}` are eval-time store paths,
  realized as build inputs of the task script.
- **Idempotent** — `cmp` first, skip unchanged files. No mtime churn on every
  direnv reload.
- **Atomic** — `mktemp` + `mv`, so a concurrent agent session never reads a
  half-written file. This repo is routinely co-occupied. Temp files get a hidden
  `.` prefix so a crashed run cannot strand a visible `*.md.XXXXXX` in a
  gitignored dir where nothing would ever notice it.
- **Prunes orphans** — a renamed fragment used to strand a stale rule or
  steering file forever, invisible because those dirs are gitignored. Neither
  old mechanism did this.
- **`cd "$DEVENV_ROOT"`** — fixes a latent bug in the _existing_ tasks: direnv
  activates in subdirectories and a task's default cwd is the caller's cwd, so
  relative destinations could write to the wrong place.

### 4. Docs (same commit — change-propagation)

- `dev/fragments/devenv/files-internals.md:163-195` quotes the deleted block
  verbatim and claims "No manual regeneration needed"
- `dev/fragments/pipeline/generation-architecture.md:34`
- `devshell/docs-site/pages/devenv-footer.md:9`
- `.gitignore:22` comment
- `packages/kiro-cli/lib/mkKiro.nix:794-795` (the wrong claim)
- then regenerate

## Why not `files.<name>.copyMode = "copy"`

It genuinely exists in the pinned devenv (`files.nix:57-67`, enum
`symlink|seed|copy`) and would be nearly a one-word change. Rejected because:

- It `rm -rf`s then `cp`s **unconditionally on every entry** — a read race for
  co-occupied agent sessions, and mtime churn on every reload.
- It cannot prune orphans.
- `files.<name>.source` does exist in this version (mkKiro uses it), but it only
  takes a path. Feeding `copyMode` _formatted_ content would require
  `builtins.readFile` on the built derivation — IFD on every devenv eval.

## Honest downsides

1. Shell entry now depends on the instruction derivations building. A treefmt
   failure inside `runFmt` previously broke only an explicit task; now it blocks
   entering the shell.
2. Editing a fragment costs ~3 s of rebuilds before the shell is usable
   (measured 0.75 s × 4).
3. Repo-local only. `mkKiro.nix:815-845` and `mkClaude.nix:689-724` still emit
   steering/rules as store symlinks for every downstream consumer — if the Kiro
   premise holds, the real bug keeps shipping. Explicit non-goal.
4. Skills stay symlinks (`.kiro/skills/**` included) — same suspected defect,
   out of scope.
5. Still no CI staleness gate comparing `nix build .#instructions-*` to the
   committed tracked files.

## Verification before landing

- **Store-path hash equality**, not a diff: because the four bodies move
  verbatim, each rebuilt `instructions-*` must come out at the _same store path_
  as today — `apni0mmw…-instructions-agents` and the other three. Any hash
  change means the refactor altered content and must be explained.
- `devenv test` (exercises the new enterTest guard)
- `nix flake check`
- `git add dev/instructions.nix` before building — flakes only see tracked
  files.
- Land or drop the pre-existing dirty
  `.github/instructions/kiro-cli.instructions.md` first, or it is
  indistinguishable from this change in review.

## Update Pipeline Architecture

> **Last verified:** 2026-09-21 — flat model package names may contain dots; the
> package worker quotes them as one Nix attribute component.
>
> **Settled — do not relitigate.** Gating the PR on a passing build was tried
> and rejected. It parks every later bump of that input behind one broken
> package — measured on PR #1527, red from 2026-09-07 to 2026-09-09 on a single
> `versionCheckHook` mismatch — and it makes the sweep, not the PR list, the
> thing a human has to poll. The Renovate shape is: the bot writes the change,
> branch CI judges it.
>
> Full lineage: `git show ed5898b1:dev/fragments/pipeline/update-pipeline.md`.

### Execution models: local Ninja and CI matrix

Local updates use Ninja as a DAG executor. CI uses one independent runner per
input or package, discovered from the same lock and owner registry; see
`ci-update-workflow.md` for publication, receipts, and checkout isolation.
`dependsOn` remains local scheduling policy: predecessor branches do not feed
changes into another target's worktree. CI package workers omit only the final
informational build; hashes, extracted files, and formatting remain preparation
work, while native PR CI validates the completed branch. Local input
verification reduces evaluator workers when the core-derived count would violate
the 60% memory budget. If no viable evaluator can start, that setup failure
holds the input back instead of being classified as an executed, ordinary red
build. Before each verifier attempt, the updater enumerates the package
universe. The pinned producer must then report exactly one evaluation per
attribute, and every successful evaluation needs cached/local or build evidence;
aliases may share one build through a common derivation path. Empty, partial, or
malformed coverage is incomplete verification and holds the input back after the
retry. The retry also distinguishes Nix's fixed-output hash mismatch from a
compiler or test failure. Missing cargoDeps/pnpmDeps fixers can still require
human repair (issue #1570), but a known unresolved hash now holds the input
branch back; a fully covered update with an ordinary build failure remains
eligible for a red PR.

Verifier failures can overlap. `run_nfb_build` returns incomplete coverage (4)
before an observed fixed-output mismatch (3), so code 4 does not mean there is
nothing to repair. Keep the input worker's repair attempt before re-verifying;
skipping repair solely for code 4 can strand a repairable update. Setup failure
(2) still exits before repair because verification could not start.

The local pipeline uses the Ninja DAG. A nix expression
(`config/generate-update-ninja.nix`) reads `flake.lock` and
`config.update.targets` (the `.#updateTargets` flake output) to emit
`.update.ninja` with dependency edges (e.g., agnix and git-absorb depend on
`rust-overlay` input being updated first, via their `dependsOn`).
`update-init.sh` runs once as the root target to clean stale state (abort stuck
git ops, delete old `update/*` branches, clear the report file). Every package
depends on that initialization plus its explicit `dependsOn` predecessors. It
does not depend on the separate nixpkgs or nix-update input targets: their
branches never feed state into the package worktree, so those edges would only
serialize independent work.

The CI package and update validators accept single dots within package names,
including model versions. Registry keys remain flat names; `update-pkg.sh`
quotes the entire name as one Nix attribute for evaluations, builds, and
nix-update. An unquoted name containing a dot would select a nested path
instead. Conversely, nix-eval-jobs quotes dotted flat names in result receipts;
the shared package coverage validator decodes that single component before
comparing it with enumeration.

Targets fall into three categories:

- **Inputs** (`update-input.sh <name>`) — `nix flake update <name>` in a
  worktree, then `devenv update` to sync `devenv.lock`. The `llm-agents` input
  additionally regenerates Semble's committed upstream-template snapshot from a
  separate derivation. It does not rewrite the human-reviewed content hashes, so
  a changed template reaches the update PR but fails its coverage check until
  the local derivative is reviewed.
- **Packages** (`update-pkg.sh <name> [flags] [git-url]`) — runs `nix-update` in
  a worktree, optionally preceded by a rev bump for main-tracking packages. The
  Beads binary target is the one grouped package: its `passthru.updateScript`
  runs independent Beads and Dolt release updaters in sequence, so either
  upstream can move while the target still produces one branch, one build of
  `.#beads`, and one PR. The paired Dolt remains a nested package dependency,
  not a second registry row or Ninja edge. The `treefmt-nix` input target waits
  for the other isolated targets, then the final `update-report` target runs
  `update-report.sh` to print a summary grouped by status. There is no
  base-checkout format/build finalizer because it cannot observe changes
  committed only on target branches.

### Worktree isolation

Every update target runs in its own **ephemeral** git worktree under
`$WORKTREES_DIR/update-<name>/` — a binned temp root (default
`${TMPDIR:-/tmp}/nat-update-worktrees`, override `NAT_UPDATE_WORKTREES_DIR`)
deliberately OUTSIDE the flake root: devenv/Nix enumerates all untracked +
gitignored files under the flake root on every shell entry
(`git ls-files --others`; cachix/devenv#257, #2042), so in-tree worktrees were
re-scanned on every `direnv reload`. Each worktree checks out a named branch
`update/<name>` reset to the current branch HEAD. `.pre-commit-config.yaml` is
symlinked from the main tree so hooks work in worktrees. Worktrees are torn down
on exit (`teardown_worktree`) and any registration stranded by a crash or wiped
temp is reaped by `git worktree prune` in `update-init.sh`, so nothing persists
between runs.

After each target finishes preparation (and any enabled verification), it leaves
the resulting commits on its named branch and emits a single report line. The
pipeline never merges those branches itself; the CI workflow's PR-creation step
pushes each `update/<name>` branch that has commits ahead of the base SHA and
opens (or updates) one PR per dependency.

### Rev bump flow (main-tracking packages)

For packages that track a git repo's HEAD (no tagged releases), `update-pkg.sh`
receives the repo URL as a trailing argument:

1. `git ls-remote <url> HEAD` fetches the latest commit SHA.
2. The recipe file to bump comes from the package's declared
   `config.update.targets.<name>.file`, read via
   `nix eval --raw .#updateTargets.<name>.file`. Every main-tracking package
   declares one, so this is the live path; `resolve_recipe_file`
   (`dev/scripts/resolve-recipe-file.sh`) is a retained safety-net fallback that
   searches owner package trees for the single `.nix` recipe pinning this
   upstream by matching the fetch block's identity — either
   `fetchFromGitHub { owner = "<owner>"; repo = "<repo>"; }` or
   `fetchgit { url = "…github.com/<owner>/<repo>.git"; }` — and requiring an
   inline 40-hex revision and **exactly one** match. 0 or >1 matches ⇒ the
   target is reported `HELD BACK` (never a silent guess).
   `checks.update-targets-parity` asserts the declared `file` is byte-identical
   to what the resolver would print, so the two paths can never diverge. `sed`
   then replaces the old `rev` in that resolved file.
3. `nix flake prefetch github:<owner>/<repo>/<new-rev>` fetches the new source
   hash. A failed, empty, malformed response or one without a hash holds the
   target back before `nix-update` can mistake a source mismatch for a
   dependency hash. Recipes with source-version markers also require the
   returned source tree; every marker is resolved from that same prefetch.
4. `sed` replaces the old `hash` in the overlay `.nix` file.
5. `git commit` creates a commit with the rev + src hash change.
6. `nix-update --version skip` runs to update dependency hashes (cargo, pnpm,
   vendor, etc.). If changes occur, they amend into the existing commit.

If the rev is unchanged (already at latest), steps 1-6 are skipped entirely and
the target reports NO UPDATES.

**Why the resolver is deterministic.** Step 2 replaced an earlier
`grep -rl "<repo-basename>" | head -1`, which matched any overlay merely naming
the basename (e.g. `effect-mcp.nix`'s "Mirrors context7-mcp.nix." comment) and
raced on `head -1`'s early pipe close. On 2026-07-15 that wrote context7's HEAD
rev into effect-mcp's `tim-smart/effect-mcp` fetch block, pinning a nonexistent
commit → source 404 → red CI (and silently froze packages whose mis-resolved
file had no `rev`, e.g. mcp-proxy). The `checks.update-targets-parity` flake
check now asserts every main-tracking target resolves to exactly one overlay
carrying an inline rev AND that its declared `file` matches that resolver
output, so the class fails at PR time rather than mid-pipeline.

### config.update.targets (single source of truth)

The per-package update config lives in `config.update.targets`, an option-merged
registry every package contributes a row to. It replaced the flat, top-level
`config/update-matrix.nix`, which was dissolved.

- **`lib/update.nix`** — a plain module declaring `options.update.targets`, an
  `attrsOf (submodule { file; flags; git; dependsOn; })`, plus the sibling
  `options.update.excludePatterns`. `file` is a repo-relative POSIX path STRING
  (never a Nix path literal), `null` for binary packages; `git` is the upstream
  URL for main-tracking rev-bump, `null` for binary packages; `dependsOn` names
  DAG predecessors (e.g. `["rust-overlay"]`). For the reference submodule shape,
  read the sibling registry in `lib/fragments-registry.nix`, which uses the same
  `attrsOf (submodule …)` shape and separates option declarations from
  contributions. Owner registries and workspace policy now compose through
  `lib/facets/registry.nix`; see `docs/repository-layout.md` for the settled
  ownership boundary.
- **`config/update-targets.nix`** — workspace exclusion policy only.
- **`packages/<owner>/registry.nix`** — each owner contributes its update rows.
  `file = repoPath ./packages/<namespace>/<package>/package.nix` derives the
  mutable repository-relative path from the module's actual location. Binary
  rows use `--use-update-script`, with `--override-filename` when needed.
  Multiple roles sharing a source have one update target; Python source slices
  can declare `passthru.updateSource` so completeness follows their common pin.
  Derive counts from `nix eval --json .#updateTargets`; the sweep also includes
  root input targets, so that count is not the sweep's PR ceiling.
- **`.#updateTargets`** — selected from `lib/facets/repository.nix`'s native
  module evaluation. It merges discovered owner registries with workspace policy
  ; ownership validation rejects competing package keys before priorities can
  hide them. `excludePatterns` remains available to the completeness check
  through the same result.
- **Consumers** — `update-matrix.py` reads `updateTargets` for the CI matrix.
  `config/generate-update-ninja.nix` reads the same registry for the ninja DAG
  (flags space-joined, git, and `dependsOn` → `update-<dep>` edges);
  `update-pkg.sh` reads `.#updateTargets.<name>.file` for the rev-bump target.
- **`checks/packaging/update-targets-parity.nix`** — the permanent bidirectional
  CI gate (and sole update-target check; the former
  `overlay-target-resolution.nix` folded into it). Packages → targets: every
  versioned flake package must have a same-name row, share a derivation, source,
  or update script with a targeted package, declare an existing flake input
  through `passthru.updateFlakeInput`, carry a non-empty
  `passthru.updateTargetExempt` reason, or match an explicit `excludePatterns`
  exemption. The first CI run proved the reverse direction by finding two
  previously unrecorded cases: `git-branchless` is owned by its flake input.
  (The other historical exemption, the repository-local `kiro-memory-distiller`,
  was removed on 2026-09-01 — the shape it illustrated, an in-repo package with
  no upstream release to sweep, has no current instance.) Targets → overlays:
  every main-tracking target (with a `git` URL) must declare a non-null `file`
  equal to `resolve_recipe_file(<git>, overlays, packages)`, and the resolved
  overlay must carry an inline 40-hex `rev`. A positive control removes the
  real, uniquely sourced `context7-mcp` row in memory and requires that its
  package become uncovered; this proves the reverse direction can fail without
  mutating the registry on disk.

### Report format

Every target writes exactly one line to `.update-report.txt`:

- `UPDATED: <name> | <version-detail>` — successfully updated.
- `NO UPDATES: <name>` — already at latest.
- `HELD BACK: <name> | <version-detail> (<reason>)` — the update was found but
  could not be WRITTEN: the lock update failed, a hash could not be derived, the
  formatter errored, or the commit failed. A failing BUILD is deliberately not
  on this list — see "What holds a target back" below.

`update-report.sh` sorts entries by status and prints a summary.

### What holds a target back

One rule: **hold back only when the PR cannot be written.**

| Failure                             | PR writable?                                  | Outcome                                        |
| ----------------------------------- | --------------------------------------------- | ---------------------------------------------- |
| `nix flake update` fails            | no — no lock to commit                        | `HELD BACK`                                    |
| source prefetch is incomplete       | no — source hash/markers are unresolved       | `HELD BACK`                                    |
| a dependency hash cannot be derived | no — the PR needs a value that does not exist | `HELD BACK`                                    |
| verifier setup cannot start         | no — validation never ran                     | `HELD BACK`                                    |
| verifier result coverage incomplete | no — validation may have terminated early     | `HELD BACK`                                    |
| formatter errors                    | no — tree left non-canonical                  | `HELD BACK`                                    |
| `git add` / `git commit` fails      | no                                            | `HELD BACK`                                    |
| everything written, build fails     | **yes**                                       | `UPDATED` — red PR, `::warning::` in the sweep |

The last row is the whole point. A bump whose hashes all resolved is a complete,
committable change; that it does not build is a fact about the code, and the six
required checks on the PR are what report it. Withholding the PR there converts
a visible red check into an invisible line in a sweep log.

**Errexit must stay ARMED inside a target body, and that is a property of the
SHAPE.** Bash disables `errexit` for any command whose status it tests — an `if`
or `while` condition, a `!` negation, or the left operand of `||`/`&&` — and
that suppression reaches inside a subshell and overrides a `set -e` written
there. `( … ) || rc=$?` is not a fix either; the `||` puts the subshell back in
a tested context. Only a standalone subshell works:

```bash
target_rc=0
set +e
(
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  …
)
target_rc=$?
set -e
```

Under the old `if ! ( … ); then` shape every bare command in a target body fell
through to the trailing `git commit`, whose success became the target's status.
A nixpkgs bump whose build verification FAILED therefore shipped as `UPDATED` —
sweep 34351134945 logged exactly that, with zero `HELD BACK:` lines in 12,274
lines of log, and it had been doing so since at least 69c00ef2 (2026-04-13).

`checks/shell/target-subshell-shape.nix` fails the build if the shape regresses,
and carries a positive control so it cannot pass vacuously when a body is
renamed or removed. **That gate is the rule; this paragraph only explains it.**
The rule lived as prose first and was broken twice within two days of being
written, each time caught by a reviewer rather than by a tool — shellcheck has
no diagnostic for it. The explicit `exit` calls still in those bodies are now
belt-and-braces, not the mechanism.

### Key files

| File                                         | Role                                                           |
| -------------------------------------------- | -------------------------------------------------------------- |
| `checks/packaging/update-targets-parity.nix` | Flake check: declared `file` == resolver output + inline rev   |
| `config/generate-update-ninja.nix`           | Generates `.update.ninja` DAG from flake.lock + updateTargets  |
| `config/update-targets.nix`                  | Workspace update exclusions                                    |
| `dev/scripts/resolve-recipe-file.sh`         | Deterministic recipe resolution (fetch-block identity + guard) |
| `dev/scripts/update-common.sh`               | Shared functions (worktree, version, report, colors)           |
| `dev/scripts/update-init.sh`                 | Pipeline initialization (clean stale state)                    |
| `dev/scripts/update-input.sh`                | Per-input update script                                        |
| `dev/scripts/update-pkg.sh`                  | Per-package update script (rev bump + nix-update)              |
| `dev/scripts/update-report.sh`               | Report printer                                                 |
| `lib/update.nix`                             | Declares `config.update.targets` (the option declaration)      |
| `packages/<owner>/registry.nix`              | Owner update targets, source paths, and cache metadata         |
| `.github/workflows/update.yml`               | CI workflow (Renovate-style per-dependency PRs)                |

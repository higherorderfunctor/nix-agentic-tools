## Update Pipeline Architecture

> **Last verified:** 2026-08-03 (commit pending — adds reverse package-to-target
> completeness coverage using derivation, source, update-script, flake-input,
> package-exemption, and registry-exemption properties). Prior: 2026-08-03
> (commit pending — limits package DAG edges to initialization plus explicit
> target-specific constraints and removes base-checkout finalizers that could
> not observe isolated update branches). Prior: 2026-08-03 (commit pending —
> repairs the always-uploaded hidden update-report artifact and makes its
> absence fail loudly). Prior: 2026-08-03 (commit pending — records the fifth
> required `devenv-test` context in the update workflow's auto-merge contract).
> Prior: 2026-08-03 (commit pending — moves the `gh` and `glab` update targets
> with their overlay files from `generic/` to `dev-tools/`). Prior: 2026-08-02
> (commit pending — the `llm-agents` input update regenerates Semble's
> upstream-template snapshot through its separate extraction derivation, while
> human-reviewed content hashes intentionally remain manual and make CI stop on
> unreviewed drift). Prior: 2026-07-27 (commit pending — re-points the
> reference-submodule-shape pointer from the gitignored
> `private/slice-fixture/lib/concerns.nix` at the tracked in-tree registries
> `lib/fragments-registry.nix` and `lib/checks.nix`; also deletes the hardcoded
> "29 packages — 16 main-tracking + 13 binary" target count, which had gone
> stale, in favour of a derivation command; prior 2026-07-24, dissolves
> `config/update-matrix.nix` into `config.update.targets`, now the single source
> of truth). If you touch `dev/scripts/update-*.sh`,
> `dev/scripts/resolve-overlay-file.sh`, `config/generate-update-ninja.nix`,
> `config/update-targets.nix`, `lib/update.nix`, any
> `overlays/**/<pkg>.update.nix`, or `.github/workflows/update.yml` and this
> fragment isn't updated in the same commit, stop and fix it.

### Execution model: ninja DAG

The update pipeline uses ninja as a DAG executor. A nix expression
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

Targets fall into three categories:

- **Inputs** (`update-input.sh <name>`) — `nix flake update <name>` in a
  worktree, then `devenv update` to sync `devenv.lock`. The `llm-agents` input
  additionally regenerates Semble's committed upstream-template snapshot from a
  separate derivation. It does not rewrite the human-reviewed content hashes, so
  a changed template reaches the update PR but fails its coverage check until
  the local derivative is reviewed.
- **Packages** (`update-pkg.sh <name> [flags] [git-url]`) — runs `nix-update` in
  a worktree, optionally preceded by a rev bump for main-tracking packages. The
  `treefmt-nix` input target waits for the other isolated targets, then the
  final `update-report` target runs `update-report.sh` to print a summary
  grouped by status. There is no base-checkout format/build finalizer because it
  cannot observe changes committed only on target branches.

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

After each target finishes its update + build verification in the worktree, it
leaves the resulting commits on its named branch and emits a single report line.
The pipeline never merges those branches itself; the CI workflow's PR-creation
step pushes each `update/<name>` branch that has commits ahead of the base SHA
and opens (or updates) one PR per dependency.

### Rev bump flow (main-tracking packages)

For packages that track a git repo's HEAD (no tagged releases), `update-pkg.sh`
receives the repo URL as a trailing argument:

1. `git ls-remote <url> HEAD` fetches the latest commit SHA.
2. The overlay file to bump comes from the package's declared
   `config.update.targets.<name>.file`, read via
   `nix eval --raw .#updateTargets.<name>.file`. Every main-tracking package
   declares one, so this is the live path; `resolve_overlay_file`
   (`dev/scripts/resolve-overlay-file.sh`) is a retained safety-net fallback
   that deterministically locates the single overlay `.nix` pinning this
   upstream by matching the fetch block's identity — either
   `fetchFromGitHub { owner = "<owner>"; repo = "<repo>"; }` or
   `fetchgit { url = "…github.com/<owner>/<repo>.git"; }` — and requiring
   **exactly one** match. 0 or >1 matches ⇒ the target is reported `HELD BACK`
   (never a silent guess). `checks.update-targets-parity` asserts the declared
   `file` is byte-identical to what the resolver would print, so the two paths
   can never diverge. `sed` then replaces the old `rev` in that resolved file.
3. `nix flake prefetch github:<owner>/<repo>/<new-rev>` fetches the new source
   hash.
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
  read the sibling option-merged registries `lib/fragments-registry.nix` and
  `lib/checks.nix` — same `attrsOf (submodule …)` declaration, same
  central-contribution split. Both are tracked. This bullet used to cite
  `private/slice-fixture/lib/concerns.nix` instead; `/private/` is gitignored
  local working material, so that pointer resolves for nobody but its author.
  The fixture itself is described in `docs/package-restructure.md`.
- **`config/update-targets.nix`** — the central contribution: every package's
  row EXCEPT effect-mcp, plus the `excludePatterns` list carried over from the
  dissolved matrix. Rows split into main-tracking (a `git` URL and a non-null
  `file`) and binary (`git = null`, `file = null`). **No total is written here
  on purpose.** A hardcoded one rots by construction — this bullet carried "29
  packages — 16 main-tracking + 13 binary" long after the sweep had grown past
  it. Derive it instead:

  ```bash
  nix eval --json .#updateTargets --apply 'ts: with builtins;
    let n = attrNames ts; in {
      total = length n;
      mainTracking = length (filter (k: ts.${k}.git != null) n);
    }'
  ```

  `.#updateTargets` is the merged registry, so that count includes effect-mcp's
  co-located row; this file carries one fewer. It is not the size of a sweep
  either — the ninja DAG adds one Inputs target per root flake input, read from
  `flake.lock`, so a sweep's PR ceiling is targets PLUS inputs. The binary rows
  all pass `--use-update-script`, optionally with `--override-filename <path>`;
  that second flag is what lets several attributes of one upstream (`pnpm_10`,
  `pnpm_11`) each own a file and a sidecar.

- **`overlays/mcp-servers/effect-mcp.update.nix`** — effect-mcp's own row,
  co-located with the overlay it bumps:
  `config.update.targets.effect-mcp = { file = "overlays/mcp-servers/effect-mcp.nix"; flags = ["--version" "skip"]; git = "https://github.com/tim-smart/effect-mcp.git"; }`.
  The sidecar carries its own `git` URL; `resolve_overlay_file` skips
  `*.update.nix` files (update metadata, never source-pinning overlays), so the
  URL does not make it a second match for `tim-smart/effect-mcp`.
- **`.#updateTargets`** — a top-level flake output selected from an internal
  `updateRegistry` built from an explicit 3-module `lib.evalModules` list
  (`./lib/update.nix` + `./config/update-targets.nix` +
  `./overlays/mcp-servers/effect-mcp.update.nix`). Keeping the merged sibling
  `excludePatterns` in that internal binding lets the completeness check consume
  both halves without evaluating the modules twice. The barrel walker that would
  `readDir` every `<pkg>.update.nix` is deferred Track B — new contributions are
  added to that list by hand for now.
- **Consumers** — `config/generate-update-ninja.nix` reads `updateTargets` for
  the ninja DAG (flags space-joined, git, and `dependsOn` → `update-<dep>`
  edges); `update-pkg.sh` reads `.#updateTargets.<name>.file` for the rev-bump
  target.
- **`checks/update-targets-parity.nix`** — the permanent bidirectional CI gate
  (and sole update-target check; the former `overlay-target-resolution.nix`
  folded into it). Packages → targets: every versioned flake package must have a
  same-name row, share a derivation, source, or update script with a targeted
  package, declare an existing flake input through `passthru.updateFlakeInput`,
  carry a non-empty `passthru.updateTargetExempt` reason, or match an explicit
  `excludePatterns` exemption. The first CI run proved the reverse direction by
  finding two previously unrecorded cases: `git-branchless` is owned by its
  flake input, while the repository-local `kiro-memory-distiller` has no
  upstream release to track. Targets → overlays: every main-tracking target
  (with a `git` URL) must declare a non-null `file` equal to
  `resolve_overlay_file(<git>, overlays)`, and the resolved overlay must carry
  an inline 40-hex `rev`. A positive control removes the real, uniquely sourced
  `context7-mcp` row in memory and requires that its package become uncovered;
  this proves the reverse direction can fail without mutating the registry on
  disk.

### Report format

Every target writes exactly one line to `.update-report.txt`:

- `UPDATED: <name> | <version-detail>` — successfully updated.
- `NO UPDATES: <name>` — already at latest.
- `HELD BACK: <name> | <version-detail> (<reason>)` — update found but build or
  merge failed.

`update-report.sh` sorts entries by status and prints a summary.

### Key files

| File                                         | Role                                                               |
| -------------------------------------------- | ------------------------------------------------------------------ |
| `checks/update-targets-parity.nix`           | Flake check: declared `file` == resolver output + inline rev       |
| `config/generate-update-ninja.nix`           | Generates `.update.ninja` DAG from flake.lock + updateTargets      |
| `config/update-targets.nix`                  | Central `config.update.targets` rows (all packages but effect-mcp) |
| `dev/scripts/resolve-overlay-file.sh`        | Deterministic overlay resolution (fetch-block identity + guard)    |
| `dev/scripts/update-common.sh`               | Shared functions (worktree, version, report, colors)               |
| `dev/scripts/update-init.sh`                 | Pipeline initialization (clean stale state)                        |
| `dev/scripts/update-input.sh`                | Per-input update script                                            |
| `dev/scripts/update-pkg.sh`                  | Per-package update script (rev bump + nix-update)                  |
| `dev/scripts/update-report.sh`               | Report printer                                                     |
| `lib/update.nix`                             | Declares `config.update.targets` (the option declaration)          |
| `overlays/mcp-servers/effect-mcp.update.nix` | effect-mcp's co-located update-target contribution row             |
| `.github/workflows/update.yml`               | CI workflow (Renovate-style per-dependency PRs)                    |

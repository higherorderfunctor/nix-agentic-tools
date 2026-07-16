## Update Pipeline Architecture

> **Last verified:** 2026-07-16. If you touch
> `dev/scripts/update-*.sh`, `dev/scripts/resolve-overlay-file.sh`,
> `config/generate-update-ninja.nix`, `config/update-matrix.nix`, or
> `.github/workflows/update.yml` and this fragment isn't updated in
> the same commit, stop and fix it.

### Execution model: ninja DAG

The update pipeline uses ninja as a DAG executor. A nix expression
(`config/generate-update-ninja.nix`) reads `flake.lock` and
`config/update-matrix.nix` to emit `.update.ninja` with dependency
edges (e.g., Rust packages depend on `rust-overlay` input being
updated first). `update-init.sh` runs once as the root target to
clean stale state (abort stuck git ops, delete old `update/*`
branches, clear the report file).

Targets fall into three categories:

- **Inputs** (`update-input.sh <name>`) — `nix flake update <name>`
  in a worktree, then `devenv update` to sync `devenv.lock`.
- **Packages** (`update-pkg.sh <name> [flags] [git-url]`) — runs
  `nix-update` in a worktree, optionally preceded by a rev bump
  for main-tracking packages.
  The final target `update-report` runs `update-report.sh` to print
  a summary grouped by status.

### Worktree isolation

Every update target runs in its own git worktree under
`.worktrees/update-<name>/`. Each worktree checks out a named
branch `update/<name>` reset to the current branch HEAD.
`.pre-commit-config.yaml` is symlinked from the main tree so
hooks work in worktrees.

After each target finishes its update + build verification in
the worktree, it leaves the resulting commits on its named
branch and emits a single report line. The pipeline never merges
those branches itself; the CI workflow's PR-creation step pushes
each `update/<name>` branch that has commits ahead of the base
SHA and opens (or updates) one PR per dependency.

### Rev bump flow (main-tracking packages)

For packages that track a git repo's HEAD (no tagged releases),
`update-pkg.sh` receives the repo URL as a trailing argument:

1. `git ls-remote <url> HEAD` fetches the latest commit SHA.
2. `resolve_overlay_file` (`dev/scripts/resolve-overlay-file.sh`)
   deterministically locates the single overlay `.nix` pinning this
   upstream, by matching the fetch block's identity — either
   `fetchFromGitHub { owner = "<owner>"; repo = "<repo>"; }` or
   `fetchgit { url = "…github.com/<owner>/<repo>.git"; }` — and
   requiring **exactly one** match. 0 or >1 matches ⇒ the target is
   reported `HELD BACK` (never a silent guess). `sed` then replaces the
   old `rev` in that resolved file.
3. `nix flake prefetch github:<owner>/<repo>/<new-rev>` fetches
   the new source hash.
4. `sed` replaces the old `hash` in the overlay `.nix` file.
5. `git commit` creates a commit with the rev + src hash change.
6. `nix-update --version skip` runs to update dependency hashes
   (cargo, pnpm, vendor, etc.). If changes occur, they amend into
   the existing commit.

If the rev is unchanged (already at latest), steps 1-6 are
skipped entirely and the target reports NO UPDATES.

**Why the resolver is deterministic.** Step 2 replaced an earlier
`grep -rl "<repo-basename>" | head -1`, which matched any overlay merely
naming the basename (e.g. `effect-mcp.nix`'s "Mirrors context7-mcp.nix."
comment) and raced on `head -1`'s early pipe close. On 2026-07-15 that
wrote context7's HEAD rev into effect-mcp's `tim-smart/effect-mcp` fetch
block, pinning a nonexistent commit → source 404 → red CI (and silently
froze packages whose mis-resolved file had no `rev`, e.g. mcp-proxy). The
`checks.overlay-target-resolution` flake check now asserts every
main-tracking matrix entry resolves to exactly one overlay carrying an
inline rev, so the class fails at PR time rather than mid-pipeline.

### Report format

Every target writes exactly one line to `.update-report.txt`:

- `UPDATED: <name> | <version-detail>` — successfully updated.
- `NO UPDATES: <name>` — already at latest.
- `HELD BACK: <name> | <version-detail> (<reason>)` — update
  found but build or merge failed.

`update-report.sh` sorts entries by status and prints a summary.

### Key files

| File                                   | Role                                                            |
| -------------------------------------- | --------------------------------------------------------------- |
| `checks/overlay-target-resolution.nix` | Flake check: every matrix pkg resolves to one overlay w/ rev    |
| `config/generate-update-ninja.nix`     | Generates `.update.ninja` DAG from flake.lock + matrix          |
| `config/update-matrix.nix`             | Declares packages with nix-update flags and git URLs            |
| `dev/scripts/resolve-overlay-file.sh`  | Deterministic overlay resolution (fetch-block identity + guard) |
| `dev/scripts/update-common.sh`         | Shared functions (worktree, version, report, colors)            |
| `dev/scripts/update-init.sh`           | Pipeline initialization (clean stale state)                     |
| `dev/scripts/update-input.sh`          | Per-input update script                                         |
| `dev/scripts/update-pkg.sh`            | Per-package update script (rev bump + nix-update)               |
| `dev/scripts/update-report.sh`         | Report printer                                                  |
| `.github/workflows/update.yml`         | CI workflow (Renovate-style per-dependency PRs)                 |

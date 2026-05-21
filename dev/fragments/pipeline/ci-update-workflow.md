## CI Update Workflow

> **Last verified:** 2026-05-20. If you touch
> `.github/workflows/update.yml`, `dev/scripts/update-common.sh`,
> or the PR creation logic, and this fragment isn't updated in the
> same commit, stop and fix it.

### Design: Renovate-style per-dependency PRs

The CI update workflow creates one PR per updated dependency,
matching Renovate's model. Each dependency is independently
validated on both platforms (x86_64-linux + aarch64-darwin) via
the normal ci.yml PR pipeline. A failed darwin build only holds
back that specific dependency, not the entire batch.

### Workflow phases

**Phase 1 — Ninja pipeline** (ubuntu runner):

The workflow runs the ninja DAG. Each target updates its
dependency in an isolated worktree and leaves the resulting
commits on a per-dependency branch (`update/<name>`). Branches
are not pushed or merged at this stage — that happens in Phase 2.

**Phase 2 — PR creation** (same ubuntu runner):

After ninja completes, the workflow iterates all `update/*`
branches. For each branch with commits ahead of the base SHA:

1. Force-pushes the branch to origin.
2. Creates a PR against the working branch (or updates an
   existing PR's title if one already exists for that branch).

On re-run, branches are force-updated and PRs are reused. Same
behavior as Renovate's rebasing strategy.

**Phase 3 — Validation** (triggered automatically):

PRs trigger ci.yml's `pull_request` event, which runs builds on
both linux and darwin runners. PRs that pass both can be merged.

### GitHub App token

PRs created with the default `GITHUB_TOKEN` do NOT trigger
cross-workflow events (GitHub security feature to prevent
recursive workflow triggers). This workflow uses a GitHub App
token (`nix-agentic-tools-bot`) instead. App installation tokens
DO trigger `pull_request` events in ci.yml.

The App needs these permissions:

- `contents: write` — push branches
- `pull-requests: write` — create/update PRs

Self-triggering is prevented by checking the actor:
`github.actor != 'nix-agentic-tools-bot[bot]'`.

### IFD warm step

Before the ninja pipeline runs, a warm step forces all IFD
source fetches (see the IFD patterns fragment for details). This
ensures `nix-update` (which internally runs `nix-instantiate`)
can evaluate packages that use `builtins.readFile` on fetched
sources. Without this step, nix-update crashes on cold runners.

### Base SHA comparison

The workflow records the branch HEAD before the ninja pipeline
as `base_sha`. After ninja completes, each `update/*` branch is
compared against this SHA. Branches where HEAD equals `base_sha`
are skipped (no changes — the dependency was already at latest).
This avoids creating empty PRs or force-pushing unchanged
branches.

### Branch name extraction

`git branch --list 'update/*'` output includes markers for
worktree-checked-out branches (prefixed with `+`). The workflow
strips these with `tr -d ' *+'` before using the branch name.
Forgetting this causes branch operations to fail with cryptic
errors about branches named `+ update/foo`.

### Environment requirements

| Variable            | Source                             | Purpose                                              |
| ------------------- | ---------------------------------- | ---------------------------------------------------- |
| `CACHIX_AUTH_TOKEN` | Repository secret                  | Pushes fetched sources + built outputs               |
| `GITHUB_TOKEN`      | App token step output              | Authenticates git push + gh CLI                      |
| `NIX_PATH`          | `nixpkgs=flake:nixpkgs`            | Required by nix-update (uses `import <nixpkgs>`)     |
| `WORKTREE_LOCK`     | `$RUNNER_TEMP/nix-update-worktree` | Serializes `git worktree add` (not concurrency-safe) |

### Key files

| File                           | CI-relevant sections                                  |
| ------------------------------ | ----------------------------------------------------- |
| `.github/workflows/update.yml` | Full workflow definition                              |
| `dev/scripts/update-common.sh` | Shared worktree, version, and report helpers          |
| `dev/scripts/update-init.sh`   | Cleans stale `update/*` branches + detaches worktrees |

## CI Update Workflow

> **Last verified:** 2026-05-27. If you touch
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

### Build verification gate (`run_nfb_build`)

`update-input.sh` and the `final-build` ninja rule both invoke
`nix-fast-build` to verify peer packages still build after an
input change. Upstream has a known bug where `async_main`'s
`finally: stack.aclose()` can swallow non-zero exit on the
build-failure path — per-build failures silently exit 0. Effect:
a broken peer package would let `nixpkgs` (or any other input
update) ship as UPDATED instead of HELD BACK.

`run_nfb_build` in `update-common.sh` defends against this with
three independent gates — any of them tripping fails the build:

1. **Exit code** — `nix-fast-build`'s own exit code is non-zero.
2. **JSON result file** — `--result-file <path> --result-format json`
   is appended to the caller's command, then `jq` checks for any
   `success: false` entry. Empty/missing file is also a failure
   (we asked for one; not getting one means verification was
   incomplete).
3. **Stderr grep** — the consistent
   `ERROR:nix_fast_build:BUILD: N successes, M failures` line
   with `M > 0` is matched against captured stderr. This is the
   tripwire that caught CI run 26473689694 when (1) and (2)
   both missed.

`|| exit_code=$?` localizes errexit suppression to the single
nix-fast-build call — no blanket `set +e`. All three gates run
unconditionally so failure signals are always logged together.

### Sidecar logging and forensic preservation

Every ninja rule wraps its script invocation in
`2>&1 | tee .update-logs/<target>.log` to capture per-target
output independently of ninja's stdout capture (which buffers
until child exit). The `Diagnostic dump` step (`if: always()`)
in `update.yml` globs `.update-logs/*` and surfaces every file
under `::group::log: <name>` collapsible sections — works on
success, failure, cancel, and timeout.

`run_nfb_build` writes its forensic data
(`nfb-result-XXXXXX.json` + `nfb-stderr-XXXXXX.log`) into the
same `.update-logs/` dir. On gate failure the files are
preserved for the Diagnostic dump to surface; on success they
are cleaned up.

The directory is gitignored.

### Key files

| File                           | CI-relevant sections                                  |
| ------------------------------ | ----------------------------------------------------- |
| `.github/workflows/update.yml` | Full workflow definition                              |
| `dev/scripts/update-common.sh` | Shared worktree, version, and report helpers          |
| `dev/scripts/update-init.sh`   | Cleans stale `update/*` branches + detaches worktrees |

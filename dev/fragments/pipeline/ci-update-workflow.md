## CI Update Workflow

> **Last verified:** 2026-07-16. If you touch
> `.github/workflows/update.yml`, `dev/scripts/update-common.sh`,
> `dev/scripts/update-input.sh`, `dev/scripts/update-pkg.sh`, or the
> PR creation logic, and this fragment isn't updated in the same
> commit, stop and fix it.

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

### Formatter passes (per-input and per-package)

Both worktree update scripts run `nix fmt` before their commit so the
per-dependency PR ships treefmt-clean files. PR CI's `treefmt-check`
(`checks.formatting`) runs on each PR branch in isolation, and the
base-branch `full-format` ninja rule only runs post-merge — too late
to gate a PR — so each branch must normalize its own tree. The two
paths differ in their **trigger**:

- **`update-input.sh` (Phase 2.5)** runs `nix fmt` only when the input
  bump moves `formatter.<system>`'s store path (a new
  prettier/alejandra/biome version wants different output across the
  whole tree). Detail below.
- **`update-pkg.sh`** runs `run_build nix fmt` whenever the update left
  a dirty tree. The trigger is "the updateScript regenerated a file,"
  not "the formatter moved": a package's custom updateScript can emit
  non-canonical output even when the formatter is unchanged. The
  motivating case is `claude-code`'s `extraExtract`, which `cp`'s
  `jq`-pretty-printed JSON (every array multi-line) over
  `overlays/claude-code-extracted.json`; biome collapses short arrays
  (e.g. `effortLevels`) onto one line, so the raw `cp` drifts from
  treefmt-clean. The `extraExtract` hook also formats its own output
  directly (defense in depth — the hook stays correct when invoked
  outside the pipeline); the `update-pkg.sh` pass is the general net
  for any future package updateScript. Gated on a dirty tree so a
  no-op update doesn't create a spurious reformat commit.

#### Per-input formatter pass (`update-input.sh` Phase 2.5)

Between build verification and the commit, `update-input.sh`
conditionally runs `nix fmt` inside the per-input worktree —
only when the input bump actually moves `formatter.<system>`'s
store path — and `git add -A`'s any reformatted files into the
pending commit. The gate captures `nix eval --raw
.#formatter.x86_64-linux.outPath` before `nix flake update` and
again after build verification; identical store paths mean the
formatter hasn't changed and `nix fmt` is skipped. Most inputs
(devenv, git-branchless, rust-overlay, etc.) don't carry new
prettier / alejandra / biome versions, so unconditionally running
`nix fmt` per target added ~15–20 minutes per pipeline run for
no benefit.

When the formatter does move (typically a `nixpkgs` bump, or an
input that follows nixpkgs for treefmt-nix), the pass catches the
case where a new formatter version wants different output than
the existing repo files. Without it, the `update/<name>` PR ships
only the lock change and PR CI's `treefmt-check` fails because
the docs / other files no longer round-trip through the bumped
formatter.

`nix fmt` exits 0 on successful in-place formatting regardless
of whether files changed (we do not pass `--fail-on-change`), so
a non-zero exit here is a real formatter error and correctly
aborts the worktree subshell → reports HELD BACK.

This requires `projectRootFile = "flake.nix"` in `treefmt.nix`:
treefmt-nix's default `projectRootFile = ".git/config"` does not
exist inside a git worktree (where `.git` is a gitfile pointer,
not a directory), so the default would make `nix fmt` error in
every worktree.

The base-branch `full-format` ninja rule still runs after the
per-input pipeline as a safety net for the rare case where two
simultaneous input bumps interact in a way the per-input passes
do not catch on their own.

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
four independent gates — any of them tripping fails the build:

1. **Exit code** — `nix-fast-build`'s own exit code is non-zero.
2. **JSON result file** — `--result-file <path> --result-format json`
   is appended to the caller's command, then `jq` checks for any
   `success: false` entry. Empty/missing file is also a failure
   (we asked for one; not getting one means verification was
   incomplete).
3. **Stderr grep — build failures** — the consistent
   `ERROR:nix_fast_build:BUILD: N successes, M failures` line
   with `M > 0` is matched against captured stderr. This is the
   tripwire that caught CI run 26473689694 when (1) and (2)
   both missed.
4. **Stderr grep — evaluation failures** — the distinct
   `ERROR:nix_fast_build:EVAL: N successes, M failures` line with
   `M > 0` is matched against captured stderr. Eval-time throws
   (e.g. an input bump that breaks a package's `fetchPnpmDeps`)
   never become builds, so they are invisible to gates 1-3.

`|| exit_code=$?` localizes errexit suppression to the single
nix-fast-build call — no blanket `set +e`. All four gates run
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

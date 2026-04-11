# CI Update Pipeline v3 (nix-update era)

Supersedes: `2026-04-10-ci-update-pipeline-design.md` (v2, nvfetcher era)

## Problem

The v2 pipeline references nvfetcher, custom hash computation scripts
(`dev/scripts/update-hashes.sh`, `dev/scripts/update-locks.sh`), and a
`hashes.json` sidecar. All of those were deleted in the nix-update
migration. The pipeline must be rewritten around the new flow:
`nix flake update` + `devenv update` + `nix-update --flake <pkg> --commit`
per package.

The key behavioral change is that **nix-update modifies .nix files
in-place and commits per-package**. Phase 1 is no longer a side-effect-free
"update sources" step -- it produces a series of git commits inside the
runner's checkout.

## Pipeline overview

```
Phase 1 (ubuntu)          Phase 2 (per-platform matrix)     Phase 3 (ubuntu)
  nix flake update            nix-fast-build --skip-cached       git push
  devenv update               devenv print-dev-env
  nix-update loop (commits)   cachix daemon pushes builds
  git push staging branch
```

## Self-triggering prevention

The workflow commits and pushes. Without guards, this push re-triggers
the workflow, creating an infinite loop.

**Strategy: layered defense**

1. **`[skip ci]` in commit messages.** GitHub Actions natively skips
   workflows triggered by pushes where ALL commit messages in the push
   contain `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]`, or
   `[actions skip]`. nix-update's `--commit` flag generates per-package
   commit messages like `context7-mcp: 1.2.3 -> 1.2.4`. Phase 3 does a
   final `git commit --allow-empty -m "chore: update complete [skip ci]"`
   as the HEAD commit. However, since the push includes multiple commits
   (one per updated package), GitHub only checks HEAD -- the `[skip ci]`
   in the empty merge commit covers the entire push.

2. **Actor check in workflow `if:` guard.** If `[skip ci]` is somehow
   missed (e.g., a force push rewriting the message), a job-level
   condition prevents execution:
   ```yaml
   if: >-
     github.actor != 'github-actions[bot]'
     || github.event_name == 'workflow_dispatch'
   ```
   This allows manual dispatch to always run.

3. **Concurrency group with cancel-in-progress.** Already present in v2.
   If a second run somehow starts, it cancels the first (or vice versa).

## Phase 1: update sources (ubuntu-only)

### What it does

1. `nix flake update` -- updates `flake.lock` (includes nixos-mcp,
   serena-mcp, and all other flake input versions)
2. `devenv update` -- updates `devenv.lock` (separate lock for devenv
   inputs)
3. `nix-update --flake <pkg> --commit` loop -- for each package in
   `packages.x86_64-linux` (excluding `instructions-*`, `docs*`):
   - Checks upstream for new version
   - If changed: rewrites version, rev, hash, dep hashes inline in .nix
     files, generates lockfiles if needed, creates a git commit
   - If unchanged: prints "already up to date", no commit

### How nix-update modifies files in CI

nix-update operates on the working tree. When invoked with `--flake
<pkg> --commit`, it:

1. Evaluates `packages.x86_64-linux.<pkg>` to find the source file
2. Checks the upstream source for a newer version
3. If newer: modifies the .nix file in place (version string, `rev`,
   `hash`, dep hashes like `cargoHash`, `npmDepsHash`, `vendorHash`)
4. Runs `nix build` to verify the new hashes are correct
5. With `--commit`: runs `git add` on modified files and `git commit`
   with message `<pkg>: <old> -> <new>`

This means Phase 1 produces N git commits (one per updated package) in
the runner's local checkout. These commits exist only locally until
Phase 3 pushes them.

### Packages excluded from nix-update loop

- `instructions-*` -- generated derivations, not versioned packages
- `docs*` -- documentation build outputs
- `nixos-mcp` -- flake input (updated by `nix flake update`)
- `serena-mcp` -- flake input (updated by `nix flake update`)
- `agnix-lsp`, `agnix-mcp` -- mainProgram overrides of `agnix` base
  derivation (no independent version)

The exclusion pattern in the loop:

```bash
nix eval ".#packages.x86_64-linux" --apply 'builtins.attrNames' --json \
  | jq -r '.[]' \
  | grep -vE '^(instructions-|docs|nixos-mcp|serena-mcp|agnix-lsp|agnix-mcp|modelContextProtocol)$'
```

### How Phase 2 gets the updated code

**Decision: commit + push to a staging ref, then Phase 2 checks out
that ref.**

Alternatives considered:

| Approach | Pros | Cons |
|---|---|---|
| Upload artifact (entire repo) | Simple, no git state | ~500MB artifact, slow upload/download, no commit history |
| Upload artifact (changed files only) | Small artifact | Must list all changed files, fragile |
| Commit + push | Phase 2 gets full repo via checkout, commit history preserved | Must handle push conflicts, adds git operations |

The commit+push approach wins because nix-update already creates
commits, and Phase 2 needs a full repo (for `nix build`). The push
target is the same branch the workflow runs on.

Phase 1 pushes after the nix-update loop completes (but before Phase 2
starts). Phase 2 checks out the branch at that new HEAD.

### Error handling: nix-update failures

If `nix-update --flake <pkg>` fails for one package:

- **Current design**: `|| echo "SKIP: $pkg failed"` -- log and continue.
  A single package's upstream being unreachable should not block all
  other updates.
- The failed package gets no commit (nix-update only commits on success).
- Phase 2 still builds everything. If the old version of the failed
  package still builds, CI passes. If the old version is also broken
  (e.g., hash mismatch from a yanked release), Phase 2 catches it.

## Phase 2: build + cache (per-platform matrix)

Unchanged from v2 in concept. Each platform runner:

1. Checks out the branch (with Phase 1's commits)
2. Starts cachix-action in daemon mode (post-build-hook pushes every
   completed derivation)
3. Runs `nix run --inputs-from . nix-fast-build -- --skip-cached --no-nom
   --no-link --flake ".#packages.$SYSTEM"`
4. Runs `devenv print-dev-env` to warm devenv cache

### Matrix

| System | Runner |
|---|---|
| x86_64-linux | ubuntu-latest |
| aarch64-darwin | macos-latest |

### Error handling: build failures

- `nix-fast-build` exits non-zero if any package fails to build
- Successful builds are already in cachix (daemon pushed them)
- The job fails, blocking Phase 3
- Next run: `--skip-cached` skips packages already in cachix, retries
  only the failures
- `fail-fast: false` on the matrix so both platforms attempt their
  builds (a Linux failure should not prevent macOS builds from being
  cached)

### devenv warm step

```bash
nix profile install nixpkgs#devenv
devenv print-dev-env --verbose > /dev/null
```

After nix-fast-build, all overlay packages are in cachix. devenv
evaluation fetches them as substitutions (seconds, not hours). This
step verifies the devenv config evaluates cleanly and pushes the devenv
profile derivation to cachix via the daemon.

No `continue-on-error`. If devenv fails to evaluate, something is wrong
and must be fixed before merging.

## Phase 3: push (ubuntu-only)

Only runs if ALL Phase 2 jobs pass (default `needs:` behavior).

Phase 1 already pushed the commits. Phase 3's job is to verify success
and handle edge cases:

1. Nothing to do if Phase 1 push succeeded and no conflicts arose
2. If the branch has moved (another push happened during Phase 2):
   `git pull --rebase` before any additional push

In the simple case where Phase 1 pushed successfully, Phase 3 is a
no-op confirmation that all builds passed. It exists as a gating
mechanism: Phase 2 `needs: [update-sources]` and Phase 3
`needs: [update-sources, build]`.

Actually, Phase 3 can be simplified: **Phase 1 pushes its commits
immediately.** Phase 2 checks out that pushed state. If Phase 2 passes,
the commits are already on the branch. If Phase 2 fails, the commits
are on the branch but with known-broken builds -- the next CI run will
fix-forward or the user will intervene.

**Revised design**: Eliminate Phase 3. Phase 1 pushes. Phase 2 is
validation only.

**Downside**: If Phase 2 fails, the branch has broken commits. This is
acceptable for a feature branch (`refactor/ai-factory-architecture`).
For `main`, we would want the gated approach -- push only after builds
pass. Keep Phase 3 for future `main` branch support.

## Garnix evaluation

### What garnix provides

- **Persistent /nix/store**: No cold-cache penalty. Packages built in a
  previous run are still in the local store, so `nix build` is instant
  for unchanged packages. GHA runners are ephemeral -- even with cachix,
  every run downloads cached artifacts.
- **Native macOS hardware**: Real aarch64-darwin, not virtualized.
- **Parallel builds**: Evaluates all derivations and builds them in
  parallel, like Hydra.
- **Own cache**: `cache.garnix.io` with public key
  `cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=`.
- **Zero config**: Reads `flake.nix` directly. No workflow YAML for
  builds.
- **GitHub App**: Creates GitHub check suites, which can trigger GHA
  workflows via `on: check_suite`.

### How garnix would fit

```
Phase 1 (GHA, ubuntu):
  nix flake update + devenv update + nix-update loop
  Push commits to branch

Phase 2 (garnix, automatic):
  Garnix detects push, evaluates flake, builds all packages + checks
  Results appear as GitHub check suite

Phase 3 (GHA, triggered by check_suite:completed):
  Download from cache.garnix.io, push to cachix
  (so consumers use cachix, not garnix)
  Warm devenv cache
```

### Triggering GHA from garnix completion

Garnix is a GitHub App that creates check suites. GHA supports:

```yaml
on:
  check_suite:
    types: [completed]
```

This triggers once per non-GitHub-Actions check suite. If the only
external check suite is garnix, it fires exactly once when garnix
finishes all builds for a commit.

**Critical limitation**: `check_suite` event only triggers workflow runs
if the workflow file exists on the **default branch** (`main`). During
development on `refactor/ai-factory-architecture`, this trigger will not
fire. This means garnix integration cannot be tested until the workflow
is merged to `main`.

### Cache relay: garnix to cachix

Phase 3 would need to pull from garnix and push to cachix:

```bash
# Configure garnix as substituter
export NIX_CONFIG="extra-substituters = https://cache.garnix.io
extra-trusted-public-keys = cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="

# With cachix daemon active, nix build downloads from garnix
# and the daemon pushes to cachix. No compilation.
nix run --inputs-from . nix-fast-build -- \
  --skip-cached --no-nom --no-link \
  --flake ".#packages.x86_64-linux"
```

For private repos, garnix cache requires an auth token. For public
repos, cache.garnix.io is publicly readable.

### Pricing

| Tier | CI minutes/month | Cost | macOS |
|---|---|---|---|
| Free | 1,500 | $0 | Yes |
| Individual | 10,000 | $25/mo | Yes |
| Overage | Per-minute | $0.006/min | Yes |

This repo has ~29 packages across 2 platforms. A full rebuild takes
roughly 30-60 min per platform. Incremental runs (most packages cached)
take 5-10 min. At 2-3 runs/week, monthly usage is roughly 200-600 min
-- well within the free tier.

### Recommendation

**Ship GHA-only pipeline first (v3). Add garnix after merge to main.**

The `check_suite` trigger only works on the default branch, so garnix
integration cannot be tested on the feature branch. Ship v3 with GHA
builds, merge to main, then add garnix.

### Garnix failure visibility

`check_suite` fires on `completed` — both success AND failure. The
relay workflow handles both:

```yaml
on:
  check_suite:
    types: [completed]

jobs:
  relay:
    if: github.event.check_suite.app.slug == 'garnix-ci'
    steps:
      - name: Fail if garnix failed
        if: github.event.check_suite.conclusion != 'success'
        run: |
          echo "Garnix build failed: ${{ github.event.check_suite.conclusion }}"
          exit 1
      # ... cachix relay only on success ...
```

Failed garnix builds show as failed GHA jobs — visible in PR checks,
commit status, and notification emails. No silent failures.

### No idle runners

The GHA runner only spins up AFTER garnix completes (triggered by
`check_suite`). No polling, no idle-waiting. The relay job runs for
2-3 minutes (cache download + upload), not 30+ minutes of building.

### Adoption path

1. Ship v3 pipeline on GHA only (this design)
2. Merge to `main`
3. Install garnix GitHub App, add `garnix.yaml`
4. Add `check_suite`-triggered relay workflow
5. Monitor for 2 weeks
6. If stable, remove GHA build matrix (keep relay + devenv warm only)
6. If stable, remove GHA build matrix (keep relay + devenv warm only)

## Complete workflow YAML

```yaml
# CI pipeline v3: nix-update era
#
# Phase 1: update flake + devenv locks, nix-update per-package (ubuntu)
# Phase 2: build all packages + warm devenv cache (per-platform matrix)
#
# nix-update modifies .nix files inline and commits per-package.
# Phase 1 pushes these commits. Phase 2 validates builds.
name: Update

on:
  push:
    branches: [refactor/ai-factory-architecture]
  workflow_dispatch:

concurrency:
  group: update-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: write

env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true

jobs:
  # ── Phase 1: update sources + nix-update loop (ubuntu-only) ──────
  update-sources:
    runs-on: ubuntu-latest
    # Skip if this push was made by the bot (prevents self-triggering).
    # Manual dispatch always runs.
    if: >-
      github.actor != 'github-actions[bot]'
      || github.event_name == 'workflow_dispatch'
    env:
      BRANCH_NAME: refactor/ai-factory-architecture
    steps:
      - uses: actions/checkout@v6
        with:
          # Full history so nix-update can commit on top of the real branch.
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}

      - uses: cachix/install-nix-action@v31
        with:
          extra_nix_config: |
            accept-flake-config = true

      # Daemon mode: dep derivations built during nix-update (pnpmDeps,
      # cargoDeps, etc.) get pushed to cachix so Phase 2 runners don't
      # rebuild them.
      - uses: cachix/cachix-action@v17
        with:
          name: nix-agentic-tools
          authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}

      - name: Configure git
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"

      - name: Update flake inputs
        run: nix flake update

      - name: Commit flake.lock
        run: |
          git add flake.lock
          if ! git diff --staged --quiet; then
            git commit -m "chore(flake): update flake.lock [skip ci]"
          fi

      - name: Update devenv lock
        run: |
          nix profile install nixpkgs#devenv
          devenv update

      - name: Commit devenv.lock
        run: |
          git add devenv.lock
          if ! git diff --staged --quiet; then
            git commit -m "chore(devenv): update devenv.lock [skip ci]"
          fi

      # nix-update loop: updates each package's version + hashes inline
      # in the .nix source file. --commit creates one commit per package.
      # Packages with no upstream change print "already up to date" and
      # produce no commit.
      #
      # Excluded:
      #   instructions-*, docs* — generated, not versioned packages
      #   nixos-mcp, serena-mcp — flake inputs (updated by nix flake update)
      #   agnix-lsp, agnix-mcp — mainProgram overrides (share agnix version)
      #   modelContextProtocol — namespace, not a package
      - name: Run nix-update per package
        run: |
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          system="x86_64-linux"
          exclude='^(instructions-|docs|nixos-mcp|serena-mcp|agnix-lsp|agnix-mcp|modelContextProtocol)$'
          pkgs=$(nix eval ".#packages.${system}" --apply 'builtins.attrNames' --json \
            | jq -r '.[]' \
            | grep -vE "$exclude")

          failed=""
          for pkg in $pkgs; do
            echo "::group::Updating $pkg"
            if nix run --inputs-from . nix-update -- --flake "$pkg" --commit; then
              echo "::endgroup::"
            else
              echo "::endgroup::"
              echo "::warning::nix-update failed for $pkg"
              failed="$failed $pkg"
            fi
          done

          if [ -n "$failed" ]; then
            echo "::warning::Failed packages:$failed"
            echo "These packages were skipped. Their existing versions will be built in Phase 2."
          fi
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      # Push all commits (lock updates + per-package nix-update commits).
      # Phase 2 checks out this pushed state.
      # [skip ci] is in the lock commits but NOT in nix-update commits
      # (nix-update generates its own messages). The actor check above
      # prevents re-triggering.
      - name: Push updates
        run: |
          if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/$BRANCH_NAME)" ]; then
            git pull --rebase origin "$BRANCH_NAME" || true
            git push origin "HEAD:$BRANCH_NAME"
          else
            echo "No changes to push"
          fi

  # ── Phase 2: per-platform build + devenv cache ──────────────────
  build:
    needs: update-sources
    strategy:
      fail-fast: false
      matrix:
        include:
          - system: x86_64-linux
            runner: ubuntu-latest
          - system: aarch64-darwin
            runner: macos-latest
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v6
        with:
          # Ensure we get Phase 1's commits.
          ref: ${{ github.ref }}

      - uses: cachix/install-nix-action@v31
        with:
          extra_nix_config: |
            accept-flake-config = true

      # Daemon mode: pushes every completed derivation to cachix
      # immediately via post-build-hook. Even if a later step fails,
      # successful builds are already in the cache for next run.
      - uses: cachix/cachix-action@v17
        with:
          name: nix-agentic-tools
          authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}

      # Build ALL packages directly. Hashes are inline in .nix files
      # (updated by nix-update in Phase 1).
      # --inputs-from . resolves nix-fast-build from the flake input.
      # --skip-cached checks cachix substituter, skips cached packages.
      # No --cachix-cache: the daemon handles push (avoids double-push).
      # No continue-on-error: failures must block.
      - name: Build all packages
        run: |
          nix run --inputs-from . nix-fast-build -- \
            --skip-cached \
            --no-nom \
            --no-link \
            --flake ".#packages.${{ matrix.system }}"

      # Warm devenv cache AFTER building packages. Overlay packages
      # are cachix hits from the build step; only devenv-specific
      # glue (profile, shell-env, git-hook wrappers) builds locally.
      # Pushes devenv profile to cachix so `devenv shell` is instant
      # for consumers on all platforms.
      - name: Warm devenv cache
        run: |
          nix profile install nixpkgs#devenv
          devenv print-dev-env --verbose > /dev/null
        env:
          DEVENV_TUI: "false"
```

## Differences from v2

| v2 (current `update.yml`) | v3 (this design) | Reason |
|---|---|---|
| `nvfetcher -c config/nvfetcher/nvfetcher.toml` | Deleted | nvfetcher removed |
| `bash dev/scripts/update-locks.sh` | Deleted | nix-update handles lockfiles |
| `bash dev/scripts/update-hashes.sh` | Deleted | nix-update computes hashes inline |
| `actions/cache` for `hashes.json` | Deleted | No sidecar hashes |
| `nix develop .#ci -c` wrapper | Direct `nix` commands | CI shell no longer needed for these steps |
| 3-phase (update, build, commit) | 2-phase (update+push, build) | Phase 1 pushes directly; Phase 2 validates |
| Upload/download artifact for sources | Phase 1 pushes, Phase 2 checks out | Simpler, preserves commit history |
| Single commit "automated update" | Per-package commits from nix-update | Better git history, easier bisection |
| Phase 3 commit+push | Eliminated (push in Phase 1) | Simpler; acceptable for feature branch |

## Failure matrix

| Scenario | Behavior |
|---|---|
| nix-update fails for package X | Warning logged, X skipped. Other packages updated. X keeps old version. |
| nix flake update fails | Step fails. Workflow stops. No push. |
| devenv update fails | Step fails. Workflow stops. No push. |
| Push conflicts (branch moved) | `git pull --rebase` attempts to resolve. If rebase fails, step fails. |
| Package X fails to build (Phase 2) | nix-fast-build exits non-zero. Successful builds already in cachix. Job fails. |
| devenv eval fails (Phase 2) | Job fails. Packages still in cachix. |
| Linux passes, macOS fails | macOS job fails. Linux builds are in cachix. Commits are on branch (pushed by Phase 1). |
| All pass | All packages + devenv profile in cachix for both platforms. |
| Pipeline cancelled (new push) | Cachix daemon already pushed completed builds. In-progress build lost. Next run picks up via `--skip-cached`. |
| No changes upstream | nix-update reports "already up to date" for all packages. No commits created. "No changes to push" message. Phase 2 runs nix-fast-build with `--skip-cached` (all hits, fast). |

## Incremental behavior

When nothing changed upstream:

1. `nix flake update` -- no lock changes, no commit
2. `devenv update` -- no lock changes, no commit
3. nix-update loop -- "already up to date" for every package, no commits
4. Push step -- "No changes to push"
5. Phase 2 -- `nix-fast-build --skip-cached` checks cachix, finds all
   packages cached, completes in seconds
6. devenv warm -- all packages are cachix hits, completes in seconds

Total wall time for no-op run: ~5-8 minutes (dominated by nix-update
evaluation loop checking upstream versions).

## Open questions

1. **nix-update commit messages and `[skip ci]`**: nix-update's `--commit`
   produces messages like `agnix: 0.5.0 -> 0.5.1`. These do NOT contain
   `[skip ci]`. The push includes these commits, so GitHub will see
   commits without `[skip ci]` and WILL trigger the workflow. The actor
   check (`github.actor != 'github-actions[bot]'`) is the primary
   defense. Confirm that `github.actor` is reliably set to
   `github-actions[bot]` when the bot pushes with `GITHUB_TOKEN`.

2. **nix-update `--commit` message format**: Can we pass a custom commit
   message template that includes `[skip ci]`? nix-update supports
   `--commit-message` for custom templates. If so, use:
   ```
   nix run --inputs-from . nix-update -- \
     --flake "$pkg" \
     --commit \
     --commit-message "$pkg: {old_version} -> {new_version} [skip ci]"
   ```
   This would make `[skip ci]` the primary defense and the actor check
   a backup. Verify the template variable syntax.

3. **Phase 1 push timing**: Should Phase 1 push immediately after
   nix-update, or should we add a gating step? Current design pushes
   before builds. For `main`, we would want push-after-build (Phase 3
   pattern from v2). For the feature branch, push-first is acceptable.

4. **devenv install method**: `nix profile install nixpkgs#devenv` uses
   the runner's default nixpkgs. Should this be pinned with
   `--inputs-from .` to match the flake's nixpkgs? Yes, for
   reproducibility:
   ```bash
   nix profile install --inputs-from . nixpkgs#devenv
   ```

5. **modelContextProtocol sub-packages**: The overlay exposes individual
   MCP servers from the mono-repo (filesystem-mcp, memory-mcp,
   sequential-thinking-mcp, fetch-mcp, git-mcp, time-mcp) plus a
   `modelContextProtocol` namespace. nix-update should target the
   individual server names, not the namespace. Verify which attr names
   nix-update can handle.

## Future: garnix-backed Phase 2

When ready to adopt garnix, the workflow becomes:

```yaml
name: Update (garnix relay)

on:
  # Phase 1 trigger: same as now
  push:
    branches: [main]
  workflow_dispatch:

  # Phase 2 trigger: garnix check suite completes
  check_suite:
    types: [completed]

jobs:
  update-sources:
    if: >-
      github.event_name != 'check_suite'
      && github.actor != 'github-actions[bot]'
      || github.event_name == 'workflow_dispatch'
    # ... same Phase 1 as above ...

  # Replaces GHA build matrix. Runs after garnix completes.
  cache-relay:
    if: >-
      github.event_name == 'check_suite'
      && github.event.check_suite.conclusion == 'success'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: cachix/install-nix-action@v31
        with:
          extra_nix_config: |
            accept-flake-config = true
            extra-substituters = https://cache.garnix.io
            extra-trusted-public-keys = cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=
      - uses: cachix/cachix-action@v17
        with:
          name: nix-agentic-tools
          authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}
      # Download from garnix cache, cachix daemon pushes to our cache.
      # No compilation -- pure cache relay.
      - name: Relay garnix cache to cachix
        run: |
          for system in x86_64-linux aarch64-darwin; do
            nix run --inputs-from . nix-fast-build -- \
              --skip-cached \
              --no-nom \
              --no-link \
              --flake ".#packages.$system"
          done
      - name: Warm devenv cache
        run: |
          nix profile install --inputs-from . nixpkgs#devenv
          devenv print-dev-env --verbose > /dev/null
        env:
          DEVENV_TUI: "false"
```

**Caveat**: The `check_suite` trigger only fires when the workflow file
is on the default branch. This design cannot be tested on feature
branches. The cache-relay job for aarch64-darwin may not work from an
x86_64-linux runner (cannot build, only substitute). If garnix built it,
the substitution works. If garnix missed it, the relay fails. This
needs testing.

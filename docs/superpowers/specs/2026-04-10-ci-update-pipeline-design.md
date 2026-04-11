# CI Update Pipeline v2

## Problem

The update workflow (`update.yml`) evaluates the full devenv shell before
building packages. `devenv print-dev-env` takes 9 min on Linux and 2+ hours
(hangs) on macOS because it builds overlay packages (agnix Rust compile,
MCP server npm builds) from source. The `continue-on-error: true` on the
build step masks failures, allowing broken state to be committed.

## Root cause

devenv evaluates the entire `devenv.nix` — overlays, all packages in the
packages list, git-hooks, treefmt, skill symlinks, MCP configs — just to
run `nix-fast-build`, which doesn't need any of that. Every real-world Nix
overlay repo (catppuccin/nix, nixos-apple-silicon, nixpkgs-xr,
berberman/flakes) builds packages directly via `nix-fast-build` or
`nix build` without devenv.

## Solution

Build packages outside devenv first, push to cachix, then warm the devenv
cache last. By the time devenv evaluates, all overlay packages are cachix
substitutions instead of source builds.

## Pipeline

### Phase 1: update-sources (ubuntu-only, ~2 min)

No building. Updates source files only.

1. `nix flake update` — update flake.lock
2. `devenv update` — update devenv.lock (lock file only, no eval)
3. `nvfetcher` — update generated.nix
4. `bash dev/scripts/update-locks.sh` — regenerate npm lockfiles
5. Upload artifact: flake.lock, devenv.lock, overlays/sources/

All commands run inside `nix develop .#ci -c` (lightweight CI shell).

### Phase 2: build (per-platform matrix: linux + darwin)

1. **cachix-action** in daemon mode — registers post-build-hook that
   pushes every completed derivation to cachix immediately
2. **Compute dep hashes** — `nix develop -L .#ci -c bash dev/scripts/update-hashes.sh`
   (same as current, uses lightweight CI shell)
3. **Upload hashes artifact**
4. **Build ALL packages**:
   ```bash
   nix run --inputs-from . nixpkgs#nix-fast-build -- \
     --skip-cached --no-nom --no-link \
     --flake ".#packages.${{ matrix.system }}"
   ```
   - `--inputs-from .` pins nix-fast-build to the flake's nixpkgs
   - `--skip-cached` checks cachix substituter, skips cached packages
   - No `--cachix-cache` — cachix-action daemon handles push
   - No `continue-on-error` — failures block commit
   - On failure: successful builds already in cachix (daemon pushed them)
5. **Warm devenv cache**:
   ```bash
   nix profile install --inputs-from . nixpkgs#devenv
   devenv print-dev-env --verbose > /dev/null
   ```
   - Overlay packages are cachix hits from step 4
   - nixpkgs packages are upstream cache hits
   - Only devenv-specific glue (profile, shell-env, git-hook wrappers)
     builds locally — these are tiny
   - No `continue-on-error` — devenv must evaluate cleanly
   - Pushes devenv profile to cachix so `devenv shell` is instant for
     consumers on all platforms

### Phase 3: commit (ubuntu-only)

Only runs if ALL Phase 2 jobs succeed (default `needs:` behavior).

1. Download updated-sources artifact
2. Download per-platform hashes artifacts
3. Merge hashes with `jq -s '.[0] * .[1]'`
4. Commit + push (same as current)

## Failure scenarios

| Scenario | Behavior |
|---|---|
| Package X fails to build | nix-fast-build exits non-zero. Successful builds already in cachix. Job fails. No commit. Next run: `--skip-cached` skips cached, retries X. |
| devenv eval fails | Step fails. Job fails. No commit. Packages still in cachix. |
| Linux passes, macOS fails | macOS job fails. Commit doesn't run. Linux builds are in cachix. |
| All pass | Commit. All packages + devenv profile in cachix for both platforms. |
| Pipeline cancelled (new push) | cachix daemon already pushed completed builds. In-progress build lost (incomplete, can't push). Next run picks up via `--skip-cached`. |

## Changes from v1

| v1 (current) | v2 (new) | Reason |
|---|---|---|
| `nix profile add nixpkgs#devenv` before build | Moved to after build, pinned with `--inputs-from .` | Not needed for building |
| `devenv print-dev-env` before build (9min/2hr+) | After build (cache hits, seconds) | Build first, substitute later |
| `devenv tasks run build:all` | `nix run nixpkgs#nix-fast-build` directly | No devenv overhead |
| `continue-on-error: true` on build | Removed | Failures must block commit |
| `DEVENV_TUI: "false"` on build step | Only on devenv warm step | Build step no longer uses devenv |

## Files changed

- `.github/workflows/update.yml` — restructured build phase
- No `flake.nix` changes needed

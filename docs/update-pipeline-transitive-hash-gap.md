# Update pipeline: transitive-hash gap

> **Status:** open. Documented 2026-05-20 to resume in a future session.
> **Branch context:** `refactor/ai-factory-architecture`.

## TL;DR

The Renovate-style per-input update pipeline (`dev/scripts/update-*.sh`,
`config/generate-update-ninja.nix`, `.github/workflows/update.yml`)
updates the **directly named** dependency hash for each PR but
cannot refresh **transitive** hashes that change as a side effect
of that update. CI then validates a PR that the pipeline itself
can never have made pass.

Three concrete failure modes have been observed (PRs #144, #145,
#148 on 2026-05-20). Each maps to a distinct flavor of the same
architectural property:

- The update target runs in an isolated worktree branched from
  base. It only refreshes hashes for the package nix-update is
  pointed at. In CI mode `merge_to_branch` is a no-op
  (`dev/scripts/update-common.sh:117-120`), so no downstream
  worktree ever sees an in-flight upstream input bump.

## Failure modes observed

### Mode A — Cross-target propagation gap (PR #148: nixpkgs bump → effect-mcp pnpmDeps stale)

`update-input.sh` (the nixpkgs target) runs `nix flake update
nixpkgs` + `devenv update` and stops there
(`dev/scripts/update-input.sh:20-31`). It does not touch any
overlay package.

In CI mode, base never advances mid-pipeline, so
`update-effect-mcp` sets its worktree to old-nixpkgs base
(`dev/scripts/update-common.sh:75/79`). `nix-update` on effect-mcp
finds no change vs the stored `pnpmDeps.hash` (because it's still
evaluating against old nixpkgs) and reports `NO UPDATES`. No PR
is opened for effect-mcp.

When ci.yml builds the nixpkgs PR (which contains only the lock
update), the new nixpkgs ships a different `pnpm` (observed:
`pnpm-11.1.1` vs `pnpm-10.28.0`). Different pnpm version →
different offline-store layout → stored `pnpmDeps.hash` →
`ERR_PNPM_NO_OFFLINE_TARBALL` for `dataloader-1.4.0.tgz` →
`effect-mcp` build fails on both linux + darwin.

The ninja DAG declares `update-effect-mcp` ordered after
`update-nixpkgs` (`config/generate-update-ninja.nix:36-42`),
but in CI that edge is purely cosmetic — base does not advance,
so the second target cannot read the first's output.

### Mode B — Shared let-binding invisible to nix-update (PR #145: modelcontextprotocol rev → filesystem-mcp npmDepsHash stale)

`overlays/mcp-servers/modelcontextprotocol/default.nix:34`
declares

```nix
npmDepsHash = "sha256-bj6q6TWOmZT+MGVugutU6vCpwaxedcraLB1Q/UfPIvc=";
```

as a let-binding consumed by 4 `mkJsPackage` calls (filesystem,
memory, sequential-thinking, fetch).

The update target is `modelcontextprotocol-all-mcps`, the
meta-derivation at line 148. That derivation has `dontUnpack =
true; dontBuild = true;` and no `npmDepsHash` field of its own —
it only symlinks binaries from the six child packages.

`update-pkg.sh` Phase 0 sed-bumps `rev` + `src.hash`
(`dev/scripts/update-pkg.sh:39-55`). Phase 1 runs `nix-update
--flake modelcontextprotocol-all-mcps`
(`dev/scripts/update-pkg.sh:156`). `nix-update` introspects the
target derivation's attributes, finds no hash fields on
`all-mcps`, and exits with no changes. The shared `npmDepsHash`
in let-scope used by the children is **invisible** to it.

PR ships with stale `npmDepsHash` against a fresh
`package-lock.json` → hash mismatch on
`filesystem-mcp-0.6.3+b1e1eb1-npm-deps.drv` (darwin failure was
observed; the recorded npm tarball-instability issue
(`feedback_npm_hash_instability.md`) may amplify but is not the
root cause).

### Mode C — Upstream dep-floor skew (PR #144: mcp-proxy 0.10.0 → 0.12.0)

```
mcp-proxy>   - mcp>=1.27.1 not satisfied by version 1.26.0
mcp-proxy>   - uvicorn>=0.47.0 not satisfied by version 0.40.0
```

`pythonRuntimeDepsCheckHook` evaluating real upstream constraints
from `pyproject.toml` against `python3Packages.mcp` /
`python3Packages.uvicorn` shipped by the pinned nixpkgs. **Not a
hash class of problem.** The pipeline has no upstream-dep-floor
awareness; the consequence only surfaces in ci.yml's actual
build.

Resolutions:

- (preferred) Wait for nixpkgs unstable to ship `mcp ≥ 1.27.1` +
  `uvicorn ≥ 0.47.0`; bump nixpkgs first; this PR rebuilds clean.
- Override `mcp` / `uvicorn` in the overlay with newer versions.
- Skip the check (anti-pattern; masks real ABI risk).

## Summary table

| PR                   | What pipeline updates                                | What it should have updated                                               | Why it can't                                                                                        |
| -------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| #148 nixpkgs         | `flake.lock`, `devenv.lock`                          | `pnpmDeps.hash` on effect-mcp (+ possibly other pnpm/npm/cargo consumers) | Cross-target propagation: nixpkgs PR isolated to lock; downstream worktrees can't see it in CI mode |
| #145 mcp-servers rev | `rev`, `src.hash`, `upstream` literals on `all-mcps` | Shared `npmDepsHash` consumed by 4+ siblings                              | nix-update introspects target derivation attrs only — let-scope bindings on siblings invisible      |
| #144 mcp-proxy ver   | `rev`, `src.hash`                                    | `python3Packages.mcp` + `python3Packages.uvicorn` in nixpkgs              | Pipeline has no upstream-dep-floor awareness; not a hash problem at all                             |

## One-time manual exception applied 2026-05-20

Per `feedback_no_manual_hashes.md` ("all hashes/versions must come
from nix-update or eval-time computation") manual hash patching
is normally forbidden. The user authorized a one-time exception
on 2026-05-20 to land these three updates so the consumer can
move forward; the underlying gap remains open.

Applied:

- **#148 effect-mcp pnpmDeps.hash:** regenerated against the new
  nixpkgs by checking out the nixpkgs PR branch and running the
  empty-hash-then-build pattern (or `nix-update` if a
  newer-than-base nixpkgs makes it converge).
- **#145 filesystem-mcp npmDepsHash:** regenerated against the new
  upstream rev by setting the shared let-binding to `lib.fakeHash`,
  building, capturing the `got:` hash.
- **#144 mcp-proxy:** _not_ hash-patched. Held until nixpkgs ships
  newer mcp/uvicorn, OR overlay overrides are added in a future
  session. Decision tracked here.

## What a real fix would look like

Two pipeline gaps to close, ordered by impact:

### Gap 1 — Refresh downstream hashes on input bumps

When `update-input.sh` bumps `nixpkgs` (or `rust-overlay`, etc.),
the resulting PR should also re-run `nix-update --version skip`
against every overlay package whose hashes are derived from
content shipped by that input (pnpmDeps for pnpm consumers,
cargoHash for Rust consumers, npmDepsHash for npm consumers,
vendorHash for Go consumers). The simplest implementation: after
the input bump commits, iterate the matrix and run nix-update on
each entry that names that input as a dep edge in the ninja DAG.
Amend hash-only diffs into the input PR's commit.

Trade-off: an input bump PR becomes much larger (potentially 10+
hash changes) but ci.yml gets a coherent unit to validate.

### Gap 2 — Expose shared hashes per child

For `modelcontextprotocol/default.nix` specifically, the shared
`npmDepsHash` let-binding needs to either become per-child
(refactor each `mkJsPackage` to carry its own hash) or be
attached to `all-mcps` as a synthetic attribute that nix-update
can see and update. The current shape is invisible to
introspection-based tooling.

Trade-off: per-child hashes means 4× the storage and 4× the
update steps. The synthetic-attribute approach is cleaner but
requires a custom `updateScript` rather than `--use-update-script`

- nix-update.

### Gap 3 (long-tail) — Upstream-dep-floor awareness

Out of scope for the next session, but worth recording: ideally
`update-pkg.sh` would parse the new upstream's manifest
(`pyproject.toml`, `package.json`, `Cargo.toml`) for hardened
floors that exceed what nixpkgs currently ships, and surface that
as `HELD BACK: <name> | <version-detail> (upstream-dep-floor)`
before opening a PR that will inevitably fail in ci.yml. This
needs per-ecosystem parsing and a way to compare against nixpkgs
package versions at eval time.

## Code map

| File                                                        | Role                                                          |
| ----------------------------------------------------------- | ------------------------------------------------------------- |
| `dev/scripts/update-input.sh:20-31`                         | Where input bumps land — currently no downstream hash refresh |
| `dev/scripts/update-pkg.sh:39-55`                           | Rev bump + src.hash sed for main-tracking packages            |
| `dev/scripts/update-pkg.sh:156`                             | `nix-update` invocation — sees only target attrs              |
| `dev/scripts/update-common.sh:75/79`                        | `setup_worktree` checks out fresh from `$BRANCH`              |
| `dev/scripts/update-common.sh:117-120`                      | CI mode no-op for `merge_to_branch`                           |
| `config/generate-update-ninja.nix:36-42`                    | DAG edges — currently ordering-only, no content propagation   |
| `overlays/mcp-servers/modelcontextprotocol/default.nix:34`  | Shared `npmDepsHash` let-binding                              |
| `overlays/mcp-servers/modelcontextprotocol/default.nix:148` | `all-mcps` meta-derivation with no hash attrs                 |
| `overlays/mcp-servers/effect-mcp.nix:34-38`                 | `pnpmDeps.hash` that breaks on pnpm-version-change in nixpkgs |
| `overlays/mcp-servers/mcp-proxy.nix`                        | `pythonRuntimeDepsCheckHook` enforces upstream dep floors     |

## How to resume

1. Decide gap-1 first (downstream-refresh on input bumps) — biggest
   blast radius, every nixpkgs bump suffers from it.
2. Refactor modelcontextprotocol to make hashes introspectable
   (Gap 2) so nix-update can keep doing its job.
3. Decide policy for Gap 3 (upstream-dep-floor) — accept that
   some PRs will fail until nixpkgs catches up, or block them
   pre-PR.

When resuming, re-read `feedback_no_manual_hashes.md` — the
2026-05-20 manual patching was a one-time exception, not a
precedent.

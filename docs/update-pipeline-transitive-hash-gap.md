# Update pipeline: transitive-hash gap

> **Status:** open. Documented 2026-05-20 to resume in a future session.
> **Branch context:** `refactor/ai-factory-architecture`.

## TL;DR

The Renovate-style per-input update pipeline (`dev/scripts/update-*.sh`,
`config/generate-update-ninja.nix`, `.github/workflows/update.yml`)
updates the **directly named** dependency hash for each PR but
cannot refresh **transitive** hashes that change as a side effect
of that update, cannot see intra-derivation version coupling, and
cannot detect upstream constraint violations before opening the
PR. CI then validates PRs the pipeline itself can never have made
pass.

Four concrete failure modes have been observed (PRs #144, #145,
#148, #160 on 2026-05-20). Each maps to a distinct architectural
gap, and each has a real (non-patch) fix laid out below.

- The update target runs in an isolated worktree branched from
  base. It only refreshes hashes for the package nix-update is
  pointed at. In CI mode `merge_to_branch` is a no-op
  (`dev/scripts/update-common.sh:117-120`), so no downstream
  worktree ever sees an in-flight upstream input bump.
- Phase 2 `run_build` is a no-op in CI mode
  (`dev/scripts/update-common.sh:91-97`), so the pipeline never
  surfaces build-time signals (upstream constraint violations,
  cross-version skew) as `HELD BACK` — they leak into PR-CI as
  red builds instead.

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

**Why the pipeline didn't catch it:** `update-pkg.sh` Phase 1
runs `nix-update --version skip`, which only validates that
hashes resolve, not that the produced derivation builds. Phase 2
`run_build` is a no-op in CI mode
(`dev/scripts/update-common.sh:91-97`). The
"Fail if any updates were held back" gate at
`.github/workflows/update.yml:295-304` only fires when
`report_held_back` was called — and `report_held_back` is reached
only on `nix-update` errors (`dev/scripts/update-pkg.sh:181-189`),
never on downstream constraint failures. So the worktree branch
is pushed and the PR opens with no signal.

**Upstream status (as of 2026-05-20):**

| package                   | nixpkgs unstable | required by 0.12.0 | last bump cadence                      |
| ------------------------- | ---------------- | ------------------ | -------------------------------------- |
| `python3Packages.mcp`     | 1.26.0           | ≥ 1.27.1           | ~4 weeks (1.25→1.26 was 2026-01-27)    |
| `python3Packages.uvicorn` | 0.40.0           | ≥ 0.47.0           | no open PR for 0.47 series — long tail |

mcp is plausible 4–8 weeks out; uvicorn is unknown but slower.

### Mode D — Cross-package-version skew within a single overlay (PR #160: context7-mcp)

PR #160 was a **pnpmDeps-hash-only diff** with no rev change:

```diff
-      hash = "sha256-f3PXpCdmKh2LPD5VyFsRdLR7CEvh+GozkQFSeeNuj2c=";
+      hash = "sha256-RSmYKSndC2D5AGguoMEC7G8Dlr+61lNPrAR9ENBrB9Y=";
```

CI fails with `ERR_PNPM_NO_OFFLINE_TARBALL` on
`@inquirer/core@11.1.1.tgz`. The merged base hash (`f3PX…`) still
builds locally and via cache.nixos.org — but the new hash doesn't
work in CI either.

**Root cause:** `overlays/mcp-servers/context7-mcp.nix:50-54`
declares its own `pnpmDeps` via `ourPkgs.fetchPnpmDeps` **without
threading the matching `pnpm` interpreter**. The fetcher defaults
to `ourPkgs.pnpm` (= `pnpmLatest`), which moved from `pnpm_10` to
`pnpm_11` when nixpkgs unstable shifted its default. Meanwhile
the **parent derivation's `buildPhase`** still runs `pnpm_10`,
because nixpkgs's `pkgs/by-name/co/context7-mcp/package.nix:17`
hardcodes `pnpm = pnpm_10;` and our `overrideAttrs` doesn't
replace `nativeBuildInputs`.

Net effect:

- **Fetcher** produces an offline-store laid out for pnpm_11.
- **buildPhase** tries to consume it with pnpm_10 →
  `ERR_PNPM_NO_OFFLINE_TARBALL`.

Why `f3PX…` "works": it is the **pre-pnpm-default-bump pnpm_10
output hash**, still served by cache.nixos.org as an immortal
fixed-output substitute. The FOD substitutes from cache by
output hash **without ever running the build**, so pnpm_11 in
`nativeBuildInputs` is irrelevant — the substituted tarball was
built with pnpm_10 originally and is consumed by pnpm_10
buildPhase → consistent → works.

When the bot's `nix-update` ran on a fresh runner without that
substitute (or with `--option substitute false` semantics during
hash discovery), it forced an actual rebuild of the FOD, which
used pnpm_11 → produced `RSmYK…` → committed. PR CI on fresh
runners reproduces the same pnpm_11 store layout → still
unreadable by pnpm_10 buildPhase.

This is a **static evaluation bug in the overlay that was masked
by FOD caching**. Distinct from Mode A (target was correctly
opened by the pipeline; nothing transitive), Mode B (nix-update
saw the hash and updated it correctly given the inputs it had),
and Mode C (no Python constraint involved).

`effect-mcp.nix` is fine today because it uses
`mkDerivation` with `pnpm` and `pnpmConfigHook` both pulled from
the same `ourPkgs` attribute set — fetcher and build are bound
to the same pnpm. `context7-mcp.nix` is fragile because it uses
`overrideAttrs` against a nixpkgs derivation that pins one pnpm
version while the fetcher default tracks another.

## Summary table

| PR                   | Mode | What pipeline updates                                | What it should have done                                                        | Why it can't                                                                                                    |
| -------------------- | ---- | ---------------------------------------------------- | ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| #148 nixpkgs         | A    | `flake.lock`, `devenv.lock`                          | Refresh `pnpmDeps.hash` on effect-mcp (+ likely other pnpm/npm/cargo consumers) | Cross-target propagation: nixpkgs PR isolated to lock; downstream worktrees can't see it in CI mode             |
| #145 mcp-servers rev | B    | `rev`, `src.hash`, `upstream` literals on `all-mcps` | Refresh shared `npmDepsHash` consumed by 4+ siblings                            | nix-update introspects target derivation attrs only — let-scope bindings on siblings invisible                  |
| #144 mcp-proxy ver   | C    | `rev`, `src.hash`                                    | Detect dep-floor skew pre-PR, `HELD BACK (upstream-dep-floor)`                  | No pre-flight constraint check; Phase 2 `run_build` is no-op in CI                                              |
| #160 context7-mcp    | D    | `pnpmDeps.hash` (spurious regen)                     | Bind fetcher + buildPhase to same pnpm version                                  | Overlay's `fetchPnpmDeps` defaults to `pnpmLatest`; parent pins `pnpm_10`; nixpkgs default moved 10→11 silently |

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
- **#144 mcp-proxy:** _not_ hash-patched (Mode C — no hash patch
  resolves it). Left open as the canary for the real fix below.
- **#160 context7-mcp:** _not_ hash-patched (Mode D — manual hash
  patches recur on every nixpkgs default-pnpm bump). Left open as
  the canary for the real fix below.

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

### Gap 3 — Upstream-dep-floor pre-flight check (real fix for Mode C / #144)

**Insertion point:** between Phase 0 (rev bump commit at
`dev/scripts/update-pkg.sh:132-134`) and Phase 1 (nix-update at
line 140). Call it Phase 0.5.

**Mechanism:**

1. Add `parseRuntimeFloors` helper in `overlays/lib.nix`
   (alongside `readPyprojectVersion` at line 22). For Python:
   `builtins.fromTOML` on `pyproject.toml`, iterate
   `[project.dependencies]`, regex-extract `>=X.Y.Z` floors.
   Start strict on PEP 508 (`>=` only); generalize later.
2. For each `# upstream:` marker the script already parses at
   `update-pkg.sh:80-84`, locate the corresponding manifest in
   the freshly-fetched `$storePath`.
3. Evaluate each `python3Packages.<name>.version` via
   `nix eval --impure --raw` against the current flake's
   nixpkgs and compare with `lib.versionAtLeast`.
4. On mismatch: call
   `report_held_back "$name" "upstream-dep-floor" "$detail"`
   (refactor the rollback block at
   `dev/scripts/update-pkg.sh:186-190` into a function and call
   it from both Phase 0.5 and Phase 1 failure paths). The
   existing CI gate at
   `.github/workflows/update.yml:295-304` grep'es `^HELD BACK:`
   regardless of reason — no workflow change needed.

**Generalizes to ecosystems:**

- npm/pnpm: `readPackageJsonVersion` already in `overlays/lib.nix:14`;
  read `dependencies` + `peerDependencies` from `package.json` and
  compare against `nodePackages.<name>.version`.
- Cargo: `readCargoWorkspaceVersion` already in `overlays/lib.nix:27`;
  parse `[dependencies]` + `[workspace.dependencies]` from
  `Cargo.toml` and compare against the rust-overlay's toolchain.

**Auto-retry consideration:** ideally
`update-input.sh nixpkgs` (or, post-Gap 1, the in-flight bump
worker) would re-run Phase 0.5 against held-back packages whose
floors are now met and promote them from `HELD BACK` to
`UPDATED`. Defer until after the basic check lands and we measure
how often #144-class entries actually sit.

### Gap 4 — Cross-package-version skew in overlays (real fix for Mode D / #160)

This is two fixes — a one-line content fix for `context7-mcp.nix`
plus a structural guard to prevent recurrence.

**Content fix (`overlays/mcp-servers/context7-mcp.nix:50-54`):**

```nix
pnpmDeps = ourPkgs.fetchPnpmDeps {
  inherit (finalAttrs) pname version src;
  pnpm = ourPkgs.pnpm_10;   # match nixpkgs parent buildPhase pin
  fetcherVersion = 3;
  hash = "sha256-f3PXpCdmKh2LPD5VyFsRdLR7CEvh+GozkQFSeeNuj2c=";
};
```

Threading `pnpm` explicitly couples the fetcher to the same
pnpm version the parent buildPhase uses (verified upstream:
`pkgs/by-name/co/context7-mcp/package.nix:17` declares
`pnpm = pnpm_10;`). Reverts the hash to the working cached
output. No further patching needed across future nixpkgs default
pnpm bumps as long as nixpkgs continues to pin pnpm_10 for the
upstream — and if upstream switches, our fetcher follows their
choice via the same explicit binding.

**Structural guard (prevents Mode D from recurring elsewhere):**

Add a flake check `checks.pnpm-fetcher-parity` (sibling to the
existing `checks.cache-hit-parity` documented in
`.claude/rules/overlays.md`). For every overlay package whose
final `pnpmDeps` is a `fetchPnpmDeps` output, assert that the
fetcher's pnpm storeDir matches the buildPhase's pnpm storeDir.
Mechanically: evaluate
`drv.pnpmDeps.passthru.fetcherInfo.pnpm.outPath ==
(drv.nativeBuildInputs |> findPnpm |> .outPath)` (exact attribute
shape TBD by inspecting `fetchPnpmDeps`'s passthru). On
mismatch, fail the check with a drift report naming the offender
and both pnpm versions. Same shape as the cache-hit-parity check
and runs in the same CI job, so cost is one extra eval pass.

Equivalent npm guard for `fetchNpmDeps` is worth adding at the
same time (same risk shape: `npmDepsFetcherVersion` plus
defaulting to nixpkgs' current `nodejs`).

### Gap 5 (long-tail) — Build before opening PRs

Phase 2 `run_build` is a no-op in CI mode
(`dev/scripts/update-common.sh:91-97`). The pipeline therefore
opens PRs for dead-on-arrival updates (Mode C #144 is the
canonical case, but Mode A #148 also slipped through this
check). Enabling Phase 2 build in CI mode — even just
`nix build .#$name --no-link --max-jobs 1` — would catch most
Mode C/D failures at the bot stage and convert them to
`HELD BACK` instead of red PRs. Trade-off: meaningful CI runtime
cost (~ minutes per package per pipeline run). Defer until after
Gaps 3 + 4 land and we can measure how many remaining failures
this would catch.

## Code map

| File                                                                 | Role                                                                                                                |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `dev/scripts/update-input.sh:20-31`                                  | Where input bumps land — currently no downstream hash refresh                                                       |
| `dev/scripts/update-pkg.sh:39-55`                                    | Rev bump + src.hash sed for main-tracking packages                                                                  |
| `dev/scripts/update-pkg.sh:156`                                      | `nix-update` invocation — sees only target attrs                                                                    |
| `dev/scripts/update-common.sh:75/79`                                 | `setup_worktree` checks out fresh from `$BRANCH`                                                                    |
| `dev/scripts/update-common.sh:117-120`                               | CI mode no-op for `merge_to_branch`                                                                                 |
| `config/generate-update-ninja.nix:36-42`                             | DAG edges — currently ordering-only, no content propagation                                                         |
| `overlays/mcp-servers/modelcontextprotocol/default.nix:34`           | Shared `npmDepsHash` let-binding                                                                                    |
| `overlays/mcp-servers/modelcontextprotocol/default.nix:148`          | `all-mcps` meta-derivation with no hash attrs                                                                       |
| `overlays/mcp-servers/effect-mcp.nix:34-38`                          | `pnpmDeps.hash` that breaks on pnpm-version-change in nixpkgs                                                       |
| `overlays/mcp-servers/mcp-proxy.nix`                                 | `pythonRuntimeDepsCheckHook` enforces upstream dep floors (Gap 3 canary)                                            |
| `dev/scripts/update-pkg.sh:80-84`                                    | `# upstream:` marker parsing — reusable for Gap 3 manifest discovery                                                |
| `dev/scripts/update-pkg.sh:132-134`                                  | End of Phase 0 commit — Gap 3 Phase 0.5 inserts here                                                                |
| `dev/scripts/update-pkg.sh:179-189`                                  | Phase 2 build + held-back rollback (extract into shared function)                                                   |
| `dev/scripts/update-common.sh:91-97`                                 | CI-mode no-op for `run_build` — Gap 5                                                                               |
| `dev/scripts/update-common.sh:183-191`                               | `report_held_back` — extend reason taxonomy for Gap 3                                                               |
| `.github/workflows/update.yml:295-304`                               | "Fail if any updates were held back" gate — grep'es `^HELD BACK:`                                                   |
| `overlays/lib.nix:14-27`                                             | `readPackageJsonVersion`, `readCargoWorkspaceVersion`, `readPyprojectVersion` — reusable for Gap 3 manifest parsing |
| `overlays/mcp-servers/context7-mcp.nix:50-54`                        | Fetcher without `pnpm` binding — Gap 4 content fix lands here                                                       |
| Upstream `pkgs/by-name/co/context7-mcp/package.nix:17`               | nixpkgs's `pnpm = pnpm_10;` pin — the truth our overlay must follow                                                 |
| Upstream `pkgs/build-support/node/fetch-pnpm-deps/default.nix:16,29` | `pnpm ? pnpmLatest` default — the trap that produces Mode D                                                         |

## How to resume

Recommended sequencing (updated 2026-05-20 after the four-mode
RCA):

1. **Gap 4 (Mode D / #160)** — smallest blast radius. One-line
   content fix in `context7-mcp.nix` + structural-guard check.
   Land first to prove the guard-check pattern works.
2. **Gap 3 (Mode C / #144)** — Phase 0.5 manifest pre-flight.
   Reuses the same shape (parse, evaluate, `HELD BACK`).
3. **Gap 1 (Mode A / #148-class)** — downstream refresh on input
   bumps. Biggest impact, biggest work.
4. **Gap 2 (Mode B / #145)** — modelcontextprotocol shared hash.
   Self-contained but cosmetic compared to the others.
5. **Gap 5** — enable Phase 2 build in CI as a catch-all. Defer
   until 3 + 4 land and we can measure remaining failures.

When resuming, re-read `feedback_no_manual_hashes.md` — the
2026-05-20 manual patching was a one-time exception, not a
precedent.

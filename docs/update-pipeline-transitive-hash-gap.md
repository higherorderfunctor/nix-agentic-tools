# Update pipeline: transitive-hash gap

> **Status:** open. Documented 2026-05-20 to resume in a future session.
> **Branch context:** `refactor/ai-factory-architecture`.

## TL;DR

The Renovate-style per-input update pipeline (`dev/scripts/update-*.sh`,
`config/generate-update-ninja.nix`, `.github/workflows/update.yml`) updates the
**directly named** dependency hash for each PR but cannot refresh **transitive**
hashes that change as a side effect of that update, cannot see intra-derivation
version coupling, and silently disables build verification on every package. CI
then validates PRs the pipeline itself can never have made pass.

Four concrete failure modes have been observed (PRs #144, #145, #148, #160 on
2026-05-20). Each maps to a distinct architectural gap, and each has a real
(non-patch) fix laid out below.

- The update target runs in an isolated worktree branched from base. It only
  refreshes hashes for the package nix-update is pointed at. `merge_to_branch`
  is a no-op in CI mode (`dev/scripts/update-common.sh:117-120`); this part is
  by design — the Renovate model isolates each update as its own PR, so
  cherry-picks would defeat the model.
- `run_build` (Phase 2 build verification) is also a no-op in CI mode
  (`dev/scripts/update-common.sh:91-97`). **That part is dead-code.** Local-mode
  pipeline execution was deprecated some time ago (it OOMed), so every real run
  hits the CI branch. The `if [ -n "$CI_MODE" ]; then return 0; fi`
  short-circuit was kept as a no-op while local mode was being maintained; with
  local mode retired, it now silently disables Phase 2 for every package, every
  run. This is the bug behind Modes C and D (and would catch certain Mode A
  regressions for free if enabled).

## Failure modes observed

### Mode A — Cross-target propagation gap (PR #148: nixpkgs bump → effect-mcp pnpmDeps stale)

`update-input.sh` (the nixpkgs target) runs `nix flake update nixpkgs` +
`devenv update` and stops there (`dev/scripts/update-input.sh:20-31`). It does
not touch any overlay package.

In CI mode, base never advances mid-pipeline, so `update-effect-mcp` sets its
worktree to old-nixpkgs base (`dev/scripts/update-common.sh:75/79`).
`nix-update` on effect-mcp finds no change vs the stored `pnpmDeps.hash`
(because it's still evaluating against old nixpkgs) and reports `NO UPDATES`. No
PR is opened for effect-mcp.

When ci.yml builds the nixpkgs PR (which contains only the lock update), the new
nixpkgs ships a different `pnpm` (observed: `pnpm-11.1.1` vs `pnpm-10.28.0`).
Different pnpm version → different offline-store layout → stored `pnpmDeps.hash`
→ `ERR_PNPM_NO_OFFLINE_TARBALL` for `dataloader-1.4.0.tgz` → `effect-mcp` build
fails on both linux + darwin.

The ninja DAG declares `update-effect-mcp` ordered after `update-nixpkgs`
(`config/generate-update-ninja.nix:36-42`), but in CI that edge is purely
cosmetic — base does not advance, so the second target cannot read the first's
output.

### Mode B — Shared let-binding invisible to nix-update (PR #145: modelcontextprotocol rev → filesystem-mcp npmDepsHash stale)

`overlays/mcp-servers/modelcontextprotocol/default.nix:34` declares

```nix
npmDepsHash = "sha256-bj6q6TWOmZT+MGVugutU6vCpwaxedcraLB1Q/UfPIvc=";
```

as a let-binding consumed by 4 `mkJsPackage` calls (filesystem, memory,
sequential-thinking, fetch).

The update target is `modelcontextprotocol-all-mcps`, the meta-derivation at
line 148. That derivation has `dontUnpack = true; dontBuild = true;` and no
`npmDepsHash` field of its own — it only symlinks binaries from the six child
packages.

`update-pkg.sh` Phase 0 sed-bumps `rev` + `src.hash`
(`dev/scripts/update-pkg.sh:39-55`). Phase 1 runs
`nix-update --flake modelcontextprotocol-all-mcps`
(`dev/scripts/update-pkg.sh:156`). `nix-update` introspects the target
derivation's attributes, finds no hash fields on `all-mcps`, and exits with no
changes. The shared `npmDepsHash` in let-scope used by the children is
**invisible** to it.

PR ships with stale `npmDepsHash` against a fresh `package-lock.json` → hash
mismatch on `filesystem-mcp-0.6.3+b1e1eb1-npm-deps.drv` (darwin failure was
observed; the recorded npm tarball-instability issue
(`feedback_npm_hash_instability.md`) may amplify but is not the root cause).

### Mode C — Upstream dep-floor skew (PR #144: mcp-proxy 0.10.0 → 0.12.0)

```
mcp-proxy>   - mcp>=1.27.1 not satisfied by version 1.26.0
mcp-proxy>   - uvicorn>=0.47.0 not satisfied by version 0.40.0
```

`pythonRuntimeDepsCheckHook` evaluating real upstream constraints from
`pyproject.toml` against `python3Packages.mcp` / `python3Packages.uvicorn`
shipped by the pinned nixpkgs.

**Why the pipeline didn't catch it:** `update-pkg.sh` Phase 1 runs
`nix-update --version skip`, which only resolves the FOD source/hash — it does
not run the build, so `pythonRuntimeDepsCheckHook` is never invoked. Phase 2
`run_build` would invoke the build, but `run_build` returns 0 unconditionally
because of the leftover `CI_MODE` short-circuit at
`dev/scripts/update-common.sh:91-97`. Local-mode pipeline execution was
deprecated (OOMs), so every real run hits the no-op branch. The
`report_held_back` path at `dev/scripts/update-pkg.sh:181-189` is therefore
never reached for build-time failures, the worktree branch is pushed, and the PR
opens with no signal.

**Upstream status (as of 2026-05-20):**

| package                   | nixpkgs unstable | required by 0.12.0 | last bump cadence                      |
| ------------------------- | ---------------- | ------------------ | -------------------------------------- |
| `python3Packages.mcp`     | 1.26.0           | ≥ 1.27.1           | ~4 weeks (1.25→1.26 was 2026-01-27)    |
| `python3Packages.uvicorn` | 0.40.0           | ≥ 0.47.0           | no open PR for 0.47 series — long tail |

mcp is plausible 4–8 weeks out; uvicorn is unknown but slower. The PR can sit
`HELD BACK` until either ships.

### Mode D — Cross-package-version skew within a single overlay (PR #160: context7-mcp)

PR #160 was a **pnpmDeps-hash-only diff** with no rev change:

```diff
-      hash = "sha256-f3PXpCdmKh2LPD5VyFsRdLR7CEvh+GozkQFSeeNuj2c=";
+      hash = "sha256-RSmYKSndC2D5AGguoMEC7G8Dlr+61lNPrAR9ENBrB9Y=";
```

CI fails with `ERR_PNPM_NO_OFFLINE_TARBALL` on `@inquirer/core@11.1.1.tgz`. The
merged base hash (`f3PX…`) still builds locally and via cache.nixos.org — but
the new hash doesn't work in CI either.

**Root cause:** `overlays/mcp-servers/context7-mcp.nix:50-54` declares its own
`pnpmDeps` via `ourPkgs.fetchPnpmDeps` **without threading the matching `pnpm`
interpreter**. The fetcher defaults to `ourPkgs.pnpm` (= `pnpmLatest`), which
moved from `pnpm_10` to `pnpm_11` when nixpkgs unstable shifted its default.
Meanwhile the **parent derivation's `buildPhase`** still runs `pnpm_10`, because
nixpkgs's `pkgs/by-name/co/context7-mcp/package.nix:17` hardcodes
`pnpm = pnpm_10;` and our `overrideAttrs` doesn't replace `nativeBuildInputs`.

Net effect:

- **Fetcher** produces an offline-store laid out for pnpm_11.
- **buildPhase** tries to consume it with pnpm_10 →
  `ERR_PNPM_NO_OFFLINE_TARBALL`.

Why `f3PX…` "works": it is the **pre-pnpm-default-bump pnpm_10 output hash**,
still served by cache.nixos.org as an immortal fixed-output substitute. The FOD
substitutes from cache by output hash **without ever running the build**, so
pnpm_11 in `nativeBuildInputs` is irrelevant — the substituted tarball was built
with pnpm_10 originally and is consumed by pnpm_10 buildPhase → consistent →
works.

When the bot's `nix-update` ran on a fresh runner without that substitute (or
with `--option substitute false` semantics during hash discovery), it forced an
actual rebuild of the FOD, which used pnpm_11 → produced `RSmYK…` → committed.
PR CI on fresh runners reproduces the same pnpm_11 store layout → still
unreadable by pnpm_10 buildPhase.

This is a **static evaluation bug in the overlay that was masked by FOD
caching**. Distinct from Mode A (target was correctly opened by the pipeline;
nothing transitive), Mode B (nix-update saw the hash and updated it correctly
given the inputs it had), and Mode C (no Python constraint involved).

`effect-mcp.nix` is fine today because it uses `mkDerivation` with `pnpm` and
`pnpmConfigHook` both pulled from the same `ourPkgs` attribute set — fetcher and
build are bound to the same pnpm. `context7-mcp.nix` is fragile because it uses
`overrideAttrs` against a nixpkgs derivation that pins one pnpm version while
the fetcher default tracks another.

## Summary table

| PR                   | Mode | What pipeline updates                                | What it should have done                                                        | Why it can't                                                                                                                 |
| -------------------- | ---- | ---------------------------------------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| #148 nixpkgs         | A    | `flake.lock`, `devenv.lock`                          | Refresh `pnpmDeps.hash` on effect-mcp (+ likely other pnpm/npm/cargo consumers) | Cross-target propagation: nixpkgs PR isolated to lock; downstream worktrees can't see it in CI mode                          |
| #145 mcp-servers rev | B    | `rev`, `src.hash`, `upstream` literals on `all-mcps` | Refresh the (correctly) shared `npmDepsHash` let-binding                        | Matrix points at the meta-derivation `all-mcps` (no hash attrs); should point at any JS child so nix-update sees the literal |
| #144 mcp-proxy ver   | C    | `rev`, `src.hash`                                    | Build the package and let `pythonRuntimeDepsCheckHook` flag it → `HELD BACK`    | Leftover dead-code `CI_MODE` guard on `run_build` (`update-common.sh:91-97`) — local mode is deprecated                      |
| #160 context7-mcp    | D    | `pnpmDeps.hash` (spurious regen)                     | Bind fetcher + buildPhase to same pnpm version + build before PR                | Overlay's `fetchPnpmDeps` defaults to `pnpmLatest`; parent pins `pnpm_10`; nixpkgs default moved 10→11 silently              |

## One-time manual exception applied 2026-05-20

Per `feedback_no_manual_hashes.md` ("all hashes/versions must come from
nix-update or eval-time computation") manual hash patching is normally
forbidden. The user authorized a one-time exception on 2026-05-20 to land these
three updates so the consumer can move forward; the underlying gap remains open.

Applied:

- **#148 effect-mcp pnpmDeps.hash:** regenerated against the new nixpkgs by
  checking out the nixpkgs PR branch and running the empty-hash-then-build
  pattern (or `nix-update` if a newer-than-base nixpkgs makes it converge).
- **#145 filesystem-mcp npmDepsHash:** regenerated against the new upstream rev
  by setting the shared let-binding to `lib.fakeHash`, building, capturing the
  `got:` hash.
- **#144 mcp-proxy:** _not_ hash-patched (Mode C — no hash patch resolves it).
  Left open as the canary for the real fix below.
- **#160 context7-mcp:** _not_ hash-patched (Mode D — manual hash patches recur
  on every nixpkgs default-pnpm bump). Left open as the canary for the real fix
  below.

## What a real fix would look like

Five gaps to close, ordered by recommended sequencing below.

### Gap 1 — Refresh downstream hashes on input bumps

When `update-input.sh` bumps `nixpkgs` (or `rust-overlay`, etc.), the resulting
PR should also re-run `nix-update --version skip` against every overlay package
whose hashes are derived from content shipped by that input (pnpmDeps for pnpm
consumers, cargoHash for Rust consumers, npmDepsHash for npm consumers,
vendorHash for Go consumers). The simplest implementation: after the input bump
commits, iterate the matrix and run nix-update on each entry that names that
input as a dep edge in the ninja DAG. Amend hash-only diffs into the input PR's
commit.

Trade-off: an input bump PR becomes much larger (potentially 10+ hash changes)
but ci.yml gets a coherent unit to validate.

Note: Gap 5 (real Phase 2 build) does NOT cover Mode A, because input bumps
don't have a single target package to build — only the per-package targets do.
Gap 1 is the only fix for Mode A.

### Gap 2 — Point nix-update at a child instead of the meta-derivation

The shared `npmDepsHash` let-binding is correct as written.
`modelcontextprotocol/servers` is a workspace monorepo with a single
`package-lock.json` at the repo root. `fetchNpmDeps` reads that one lockfile and
produces content-addressed output. Verified 2026-05-20 by eval: all three JS
sub-packages (filesystem-mcp, memory-mcp, sequential-thinking-mcp) have
**different** npm-deps outPaths because the drv name embeds pname — but the
underlying content (and therefore the hash they all assert) is identical.

The mistake is in `config.update.targets` (`config/update-targets.nix`): it
points `nix-update` at `modelcontextprotocol-all-mcps`, the meta-derivation that
exists only to symlink binaries. `all-mcps` has no `npmDepsHash` attribute
itself, so nix-update sees nothing to refresh and exits clean. The shared
let-binding stays stale.

**Two-line fix:**

1. Expose one JS child as a top-level flake package next to the existing meta
   (`flake.nix:397`):

   ```nix
   modelcontextprotocol-all-mcps = pkgs.ai.mcpServers.modelContextProtocol.all-mcps;
   modelcontextprotocol-filesystem-mcp = pkgs.ai.mcpServers.modelContextProtocol.filesystem-mcp;
   ```

2. Replace the entry key in `config.update.targets`
   (`config/update-targets.nix`): `modelcontextprotocol-all-mcps` →
   `modelcontextprotocol-filesystem-mcp`. The `git` field stays the same.

Phase 0 of `update-pkg.sh` is unaffected: rev-bump greps for the repo name
"servers" in `overlays/`, finds the same file, and applies the same rev+src.hash
sed regardless of the config.update.targets key. The `# upstream:` markers
continue to drive per-child version re-derivation.

Phase 1 then runs `nix-update --flake modelcontextprotocol-filesystem-mcp`,
which finds the `npmDepsHash` literal on the child, reads the runtime FOD's
actual hash, and replaces the string in source. Because every JS child
references the same let-binding via `inherit npmDepsHash;`, updating one updates
them all.

Why this works: nix-update's update mechanism is **string-replacement on the
source file**, not symbolic introspection. It finds the stored hash literal as
text and replaces it. The let-binding hash literal exists exactly once in the
file, so the replacement is unambiguous and correct for all children.

No overlay refactor, no synthetic attr, no custom updateScript.

### Gap 3 (dropped) — was: Upstream-dep-floor pre-flight check

**Earlier proposal was a regex-based PEP 508 parser. Discarded as a smell.** PEP
508 includes range syntax (`>=X,<Y`), compatible release (`~=X.Y`), exclusions
(`!=`), environment markers (`; python_version<"3.13"`), extras
(`mcp[server]>=…`), and VCS/URL specifiers. A `>=X.Y.Z` regex silently
mis-handles all of these and produces both false positives and false negatives.

Reinventing PEP 508 in Nix would also be reinventing what
`pythonRuntimeDepsCheckHook` already does correctly. That hook is the canonical
evaluator; the right move is to **let it run** at update-bot time, which is
exactly what Gap 5 does. Equivalent applies to npm (`npmRuntimeDepsCheckHook`,
when present) and to Rust/Cargo (the resolver itself).

This entry is preserved so a future reader knows the regex approach was
considered and rejected.

### Gap 4 — Cross-package-version skew in overlays (real fix for Mode D / #160)

Two parts — a one-line content fix for `context7-mcp.nix` plus a structural
guard to prevent recurrence.

**Content fix (`overlays/mcp-servers/context7-mcp.nix:50-54`):**

```nix
pnpmDeps = ourPkgs.fetchPnpmDeps {
  inherit (finalAttrs) pname version src;
  pnpm = ourPkgs.pnpm_10;   # match nixpkgs parent buildPhase pin
  fetcherVersion = 3;
  hash = "sha256-f3PXpCdmKh2LPD5VyFsRdLR7CEvh+GozkQFSeeNuj2c=";
};
```

Threading `pnpm` explicitly couples the fetcher to the same pnpm version the
parent buildPhase uses (verified upstream:
`pkgs/by-name/co/context7-mcp/package.nix:17` declares `pnpm = pnpm_10;`).
Reverts the hash to the working cached output. No further patching needed across
future nixpkgs default pnpm bumps as long as nixpkgs continues to pin pnpm_10
for the upstream — and if upstream switches, our fetcher follows their choice
via the same explicit binding.

**Structural guard (prevents Mode D from recurring elsewhere):**

Add a flake check `checks.pnpm-fetcher-parity` (sibling to the existing
`checks.cache-hit-parity` documented in `.claude/rules/overlays.md`). For every
overlay package whose final `pnpmDeps` is a `fetchPnpmDeps` output, assert that
the fetcher's pnpm storeDir matches the buildPhase's pnpm storeDir.

Verified mechanism (research 2026-05-20): `fetchPnpmDeps.passthru` exposes ONLY
`fetcherVersion` and `serve` — `pnpm` is **not** on passthru. The reliable
attribute is `drv.pnpmDeps.nativeBuildInputs` filtered by `pname == "pnpm"`,
compared against the same filter applied to `drv.nativeBuildInputs`.

Consumer set in the overlay today: `context7-mcp` and `effect-mcp`. Hardcoded
list matches the cache-hit-parity convention; revisit if a third pnpm consumer
lands.

Live walkthrough against the pre-fix state confirms the check would flag
`context7-mcp` (fetcher=`pnpm-11.1.1`, build=`pnpm-10.33.4`) and pass
`effect-mcp` (both `pnpm-11.1.1`).

**No equivalent npm-side check is needed.** `fetchNpmDeps` uses a static Rust
prefetcher (`prefetch-npm-deps`) and takes no `nodejs` parameter — there is no
fetcher-vs-build tool drift to guard against. Mode D is pnpm-specific because
pnpm's offline store layout is version-keyed; npm's `package-lock.json`
resolution is not. Adding `npm-fetcher-parity` would be ceremony with no bug
class behind it.

### Gap 5 — Restore Phase 2 build verification (real fix for Mode C / #144 and safety net for D and future modes)

The `run_build` short-circuit at `dev/scripts/update-common.sh:91-97` is
leftover from a deprecated local-mode pipeline (retired due to OOMs). In current
all-CI execution it makes `run_build` an unconditional no-op, which is what
allows Mode C and Mode D failures to reach PRs.

**Content fix:** drop the `CI_MODE` short-circuit. Concretely, replace

```bash
run_build() {
  if [ -n "$CI_MODE" ]; then
    log_info "CI mode: skipping full build (PR pipeline validates)"
    return 0
  fi
  "$@"
}
```

with

```bash
run_build() {
  "$@"
}
```

(or just inline the build call at the existing Phase 2 site and delete the
helper entirely; either way, the dead branch goes). This makes
`update-pkg.sh:180`'s `nix build .#$name --no-link --log-format bar-with-logs`
actually run during the bot job, before the PR is opened.

The existing `report_held_back` machinery at `update-pkg.sh:181-189` already
catches the build failure cleanly: on non-zero exit it logs
`HELD BACK: <name> | <detail> (nix-update or build failed)`, resets the worktree
to base (so the PR-creation step at `update.yml:139-141` filters it out), and
the workflow's `^HELD BACK:` gate at `update.yml:295-304` turns the run red.
**No new code paths needed.**

What this catches automatically:

- **Mode C** — `pythonRuntimeDepsCheckHook` fires during the build's
  `pypaBuildPhase` follow-up, fails with the exact dep-floor message we saw on
  #144, build exits non-zero, `report_held_back` runs.
- **Mode D** — the build attempts to consume the FOD output, hits
  `ERR_PNPM_NO_OFFLINE_TARBALL`, fails, same path.
- **Any future class of build-time failure** specific to the targeted package
  (test failures, missing native deps, etc.) — caught for free because we're
  running the same build the consumer runs.

Cost analysis: each package bump pays one extra build in the bot job.
Cachix-action is already configured in `update.yml` and pushes successful
builds; ci.yml's PR check uses `nix-fast-build --skip-cached`, so the PR build
substitutes the cachix-served output → near-zero wall-clock cost in PR CI. The
marginal cost is the first build, which has to happen somewhere anyway.
Per-pipeline-run cost grows with the number of packages that actually update;
packages that report `NO UPDATES` skip Phase 2 (see `update-pkg.sh:174-176`).

Out-of-scope today: re-enabling local-mode execution. Local mode stays
deprecated; the `CI_MODE` guard removal is purely about killing the dead branch
that disables verification in the all-CI flow.

**Optional follow-up cleanup:** with local mode retired and Gap 5 landed, the
`CI_MODE` variable itself can be ripped out of `update-common.sh` entirely
(along with `merge_to_branch`'s local-cherry-pick code path that no longer
runs). That's a cosmetic cleanup, not load-bearing, and can wait.

## Code map

| File                                                                 | Role                                                                                                               |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `dev/scripts/update-input.sh:20-31`                                  | Where input bumps land — currently no downstream hash refresh (Gap 1)                                              |
| `dev/scripts/update-pkg.sh:39-55`                                    | Rev bump + src.hash sed for main-tracking packages                                                                 |
| `dev/scripts/update-pkg.sh:156`                                      | `nix-update` invocation — sees only target attrs                                                                   |
| `dev/scripts/update-pkg.sh:179-189`                                  | Phase 2 build + held-back rollback — already correct shape; Gap 5 just needs `run_build` to actually run           |
| `dev/scripts/update-common.sh:75/79`                                 | `setup_worktree` checks out fresh from `$BRANCH`                                                                   |
| `dev/scripts/update-common.sh:91-97`                                 | **Dead-code `CI_MODE` guard on `run_build`** — Gap 5 removes this short-circuit                                    |
| `dev/scripts/update-common.sh:117-120`                               | `merge_to_branch` no-op in CI — by design (Renovate model), don't touch                                            |
| `dev/scripts/update-common.sh:183-191`                               | `report_held_back` — already handles the build-failed case Gap 5 needs                                             |
| `config/generate-update-ninja.nix:36-42`                             | DAG edges — currently ordering-only, no content propagation (Gap 1)                                                |
| `.github/workflows/update.yml:295-304`                               | "Fail if any updates were held back" gate — grep'es `^HELD BACK:`, already wired for Gap 5                         |
| `overlays/lib.nix:14-27`                                             | `readPackageJsonVersion`, `readCargoWorkspaceVersion`, `readPyprojectVersion` — not needed for Gap 5; kept for ref |
| `overlays/mcp-servers/modelcontextprotocol/default.nix:34`           | Shared `npmDepsHash` let-binding (Gap 2)                                                                           |
| `overlays/mcp-servers/modelcontextprotocol/default.nix:148`          | `all-mcps` meta-derivation with no hash attrs (Gap 2)                                                              |
| `overlays/mcp-servers/effect-mcp.nix:34-38`                          | `pnpmDeps.hash` that breaks on pnpm-version-change in nixpkgs                                                      |
| `overlays/mcp-servers/mcp-proxy.nix`                                 | `pythonRuntimeDepsCheckHook` enforces upstream dep floors (Gap 5 canary)                                           |
| `overlays/mcp-servers/context7-mcp.nix:50-54`                        | Fetcher without `pnpm` binding — Gap 4 content fix lands here                                                      |
| Upstream `pkgs/by-name/co/context7-mcp/package.nix:17`               | nixpkgs's `pnpm = pnpm_10;` pin — the truth our overlay must follow                                                |
| Upstream `pkgs/build-support/node/fetch-pnpm-deps/default.nix:16,29` | `pnpm ? pnpmLatest` default — the trap that produces Mode D                                                        |

## Session log

### 2026-05-20 (evening) — RCA + Gap 4 content fix shipped

Doc evolution:

- Initial RCA + Modes A/B/C captured (`4a29a45`).
- Added Mode D + Gap 4 + Gap 5 (long-tail) after subagent RCAs (`2b0c13f`).
- Dropped regex-based Gap 3 (PEP 508 was a smell), promoted Gap 5 to the real
  Mode C/D fix after the user confirmed local-mode pipeline execution was
  deprecated and the `CI_MODE` guard on `run_build` is dead-code (`a6224dd`).
- Corrected Gap 4 structural-guard mechanism after research —
  `fetchPnpmDeps.passthru` does not expose pnpm; correct path is
  `nativeBuildInputs` filtered by `pname == "pnpm"`. Dropped the proposed
  `npm-fetcher-parity` check (`fetchNpmDeps` uses a static Rust prefetcher with
  no nodejs binding, no bug class to guard) (`8ac6eff`).
- Corrected Gap 2 (this commit) — verified via eval that the shared
  `npmDepsHash` let-binding is correct; the fix is a two-line config change, not
  a per-child refactor.

One-time manual hash exceptions landed (authorized; do not generalize per
`feedback_no_manual_hashes.md`):

- `b85b6c8` — #145 filesystem-mcp npmDepsHash regen.
- `07632c2` — #148 effect-mcp pnpmDeps.hash regen.

Real fixes shipped (originally as PRs, then cherry-picked directly per user
preference for landing on the dev branch without PR overhead):

- **Gap 4 content fix** in commit `51a8429`. Threads `pnpm = ourPkgs.pnpm_10;`
  into `overlays/mcp-servers/context7-mcp.nix` fetcher. Local build green,
  cachix HTTP/2 200 on the cache-served `f3PX…` outPath,
  `nix flake check --no-build` passes. PR #166 closed without merging; PR #160
  closed as superseded by this fix.

- **Gap 4 structural guard** in commit `1d864d3`. Adds
  `checks/pnpm-fetcher-parity.nix` asserting fetcher pnpm == buildPhase pnpm for
  every overlay package using `fetchPnpmDeps`. Positive test:
  `ok — every pnpmDeps fetcher uses the same pnpm as its consuming buildPhase`.
  Negative test (content fix reverted):
  `FAIL: context7-mcp: fetcher pnpm: pnpm-11.1.1, build pnpm: pnpm-10.33.4`. PR
  #168 closed without merging.

- **Gap 2 fix** in commit `4345fa3`. Adds `modelcontextprotocol-filesystem-mcp`
  as a top-level flake output and renames the update config entry
  (`config/update-matrix.nix` at the time, since dissolved into
  `config.update.targets`) to point at it (instead of the meta-derivation
  `all-mcps`, which has no `npmDepsHash` attribute). Negative test confirmed
  `nix-update --flake modelcontextprotocol-filesystem-mcp` correctly refreshes
  the shared let-binding. PR #167 closed without merging.

- **Gap 5 immediate fix** in commit `32a72c3`. Drops the dead-code `CI_MODE`
  short-circuit from `run_build` in `dev/scripts/update-common.sh`. Mode C
  (#144) and Mode D failures now hit `report_held_back` at the bot stage and the
  worktree resets to base, so bad PRs no longer force-push. Input-bump Phase 2
  (`update-input.sh:40`) also runs now — the full-platform `nix-fast-build`
  after a nixpkgs bump catches Mode A transitively. PR #170 closed without
  merging.

- **`CI_MODE` cleanup** in commit `a2ac7d2`. Deletes the `CI_MODE` and
  `MERGE_LOCK` variable declarations, the entire `merge_to_branch` function (its
  CI body was just a log + return 0; inlined at the two call sites), and the
  dead `rc=1`/`rc=2` dispatch arms in callers. Removes `UPDATE_CI=1` +
  `MERGE_LOCK` exports from `update.yml`. Updates
  `dev/fragments/pipeline/{ci-update-workflow,update-pipeline}.md`
  - regenerates ecosystem steering. `WORKTREE_LOCK` preserved (real concurrency
    safety; `git worktree add` is not thread-safe and ninja runs -j4). The
    `wt_head == base_head` early-return preserved at callers — defensive and
    what the held-back rollback path relies on.

Real fixes pending:

- **Gap 1** — design discussion needed (downstream refresh on input bumps;
  touches the DAG model). Less urgent now that `update-input.sh` Phase 2 build
  runs the full `nix-fast-build --flake .#packages.${system}` against every
  input bump, which catches Mode A transitively. Gap 1's narrower "refresh
  hashes inline in the input PR" work would still produce a coherent unit of
  validation rather than separate red/held-back PRs, but isn't blocking anything
  today.

## How to resume

State on `refactor/ai-factory-architecture` as of 2026-05-20 late evening:

1. ~~Gap 4 content fix~~ — commit `51a8429`.
2. ~~Gap 4 structural guard~~ — commit `1d864d3`.
3. ~~Gap 2 fix~~ — commit `4345fa3`.
4. ~~Gap 5 immediate fix~~ — commit `32a72c3`.
5. ~~`CI_MODE` cleanup~~ — commit `a2ac7d2`.
6. **Gap 1** — design discussion needed; not blocking.
7. **PR #144** stays open as the Mode C canary. Next pipeline run after these
   commits will convert it from a red PR to `HELD BACK (build failed)` because
   `update-pkg.sh`'s Phase 2 now actually runs the build, fails on the
   `pythonRuntimeDepsCheckHook` constraint, and resets the worktree to base
   before the PR-creation step sees it. The existing GitHub PR for #144 will
   stay at its current force-pushed state (not re-broken on each run); the
   workflow's `^HELD BACK:` gate will turn the run red until nixpkgs catches up
   on mcp/uvicorn versions.

### Held-back semantics refresher (`update-pkg.sh:179-191`)

When Phase 2 build fails, the rollback path does this in order:

1. `version_detail=$(parse_pkg_version ...)`
2. `git -C "$wt" reset --hard "$base_head"` — wipes the bot's Phase 0 (rev +
   src.hash) and Phase 1 (nix-update dep-hash) commits, putting the worktree
   branch back at base
3. `report_held_back "$name" "nix-update or build failed" "$version_detail"`
4. `exit 0` (so ninja moves on)

Later, the PR-creation step in `update.yml:139-141` filters `update/*` branches
on `wt_head == base_head` and skips the ones at base — so a held-back package
does **not** trigger `git push -f origin update/<name>` and does **not** call
`gh pr edit` / `gh pr create`. The existing GitHub PR (if any) for that package
stays at whatever state it was last force-pushed to; the held-back run turns the
pipeline red via the `^HELD BACK:` grep at `update.yml:295-304`.

This is why HELD BACK happens "before pushing" — the rollback is what makes the
package invisible to the push step.

### Environment notes for the next session

- `treefmt` CLI was misconfigured in the worktree-agent environment (PWD
  tree-root mismatch — agent worktrees live under
  `/home/caubut/Documents/projects/nix-agentic-tools/.claude/worktrees/` but the
  treefmt wrapper hardcodes `--tree-root` to `nix-agentic-tools-ideation`).
  Workaround used by all four agents: `nix fmt <files>`. Worth root-causing
  before another agent run.
- Worktrees agents create need `.pre-commit-config.yaml` symlinked from the
  parent checkout (devenv-generated, gitignored).
- Generated steering files (`.claude/rules/pipeline.md`,
  `.kiro/steering/pipeline.md`) are gitignored; only
  `.github/instructions/pipeline.instructions.md` is tracked. After fragment
  edits, run `devenv tasks run --mode before generate:instructions` locally to
  refresh the gitignored copies.

When resuming, re-read `feedback_no_manual_hashes.md` — the 2026-05-20 manual
patching was a one-time exception, not a precedent.

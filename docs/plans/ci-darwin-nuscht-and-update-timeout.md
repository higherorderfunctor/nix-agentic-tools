# CI darwin failure + update-pipeline timeout

> Branch: `refactor/ai-factory-architecture`. Diagnosis 2026-06-02.
> Trigger: the batch of dependency PRs merged ~15:24–15:32 on
> 2026-06-01 (esp. `nixpkgs` #193, `d233902…` → `64c08a7…`).
> Two independent failure modes, one shared trigger.

## Symptom

The last push (`998f81c`, a **docs-only** commit) shows:

- **CI** (`ci.yml`) run 26764860198 → **failure**.
- **Update** (`update.yml`) run 26764860677 → **cancelled** (30-min
  timeout, not a concurrency cancel — it was the last, non-superseded
  push and ran 15:32:28 → 16:03:23 ≈ 31 min).

## Root cause 1 — CI: `nuscht-search` SIGABRTs on exit (darwin only)

- Only the `build (aarch64-darwin)` job failed. Linux build,
  `nix flake check` (`test`), and `gitleaks` all green.
- `nix-fast-build` failed attrs:
  `.#packages.aarch64-darwin.docs-options-search` and `.docs`.
- `docs-options-search` = `optionsSearch` = the NuschtOS
  `github:NuschtOS/search` flake input (`nixpkgs.follows`), built via
  `pnpm run build:ci` → `ng build`. Decisive log:

  ```
  > Application bundle generation complete. [17.669 seconds]
  >  ELIFECYCLE  Command failed.
  > …/stdenv-darwin/setup: line 1773: 87784 Abort trap: 6   pnpm run build:ci
  ```

  The Angular bundle **builds successfully**, then the node process
  dies with **Abort trap: 6 (SIGABRT → exit 134)** during teardown.
  Closure has `nodejs-24.15.0` + `lmdb`/`msgpackr` native addons and
  libuv `File descriptor 22 opened in unmanaged mode twice` warnings —
  the node-24 native-addon abort-on-exit signature on macOS. `docs`
  fails only as a dependent.

- Why #193's own PR CI was green: its darwin "Build all packages" step
  ran **77 s** — it pulled the _old_ nuscht-search output from cachix
  (`--skip-cached`) and never rebuilt it. The merge produced a new
  closure; the merged-branch push is the first time this drv built.
  The failing output path (`m7f0ji…-nuscht-search-0.0.0`) is in **no
  cache** (404 on cachix + cache.nixos.org) — no green build to fall
  back on.

### Decision 1 (chosen → IMPLEMENTED, uncommitted): drop docs from the darwin build

Implemented in `flake.nix` working tree (subagent, validated: darwin has no
`docs*` attrs, linux retains all nine, treefmt clean). Not yet committed.

The doc site is a Linux-built/deployed artifact: `docs.yml` builds
`nix build .#docs` on `ubuntu-latest` (deploy-main + deploy-preview),
and `ci.yml`'s linux `build` job covers it too. Darwin coverage of the
docs/options-search adds no value and is the sole source of this
darwin-only JS-build fragility.

**Mechanism** (`flake.nix`, `packages = forAllSystems (system: …)`):
split the trailing `// { … }` so the `docs*` attrs live behind a
`lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux { … }` block;
`instructions-*` stay always-on. `supportedSystems` =
`["aarch64-darwin" "x86_64-linux"]`, so this means "Linux only".

**Safety**: `optionsSearch`/`siteCombined`/`docsOptions*` are `let`
locals — still defined; only the _exposed_ `packages.<darwin>.docs*`
attrs disappear. No `checks`/`apps`/`devShells` reference them
per-system (grep-verified). `nix-fast-build --flake .#packages
--systems aarch64-darwin` then never enumerates them.

Granularity: drop the **whole `docs*` family** (not just the two
failing attrs) — single conditional, future-proofs against another
`docs-site-*` derivation gaining a JS/native step.

## Root cause 2 — Update: `final-build` cache-cold rebuild → 30-min timeout

### Reconciliation with the prior 8→28m regression (RESOLVED, not recurring)

History (`.remember`): **2026-05-28** integrating `nix fmt` into the
Update pipeline (Phase 2.5, `bebb247`) made it hang ~30 min (expected
8); **2026-05-29** fixed by gating per-input `nix fmt` on a formatter
store-path change (`b2b62dc`). That fix **held** — post-fix completed
runs are back to baseline:

| run                              | dur    | note               |
| -------------------------------- | ------ | ------------------ |
| `claude-code (#211)` 05-29       | 7 min  | warm cache         |
| `workflow_dispatch` 06-01 15:03  | 9 min  | warm, pre-batch    |
| `docs(context7-mcp)` 06-01 15:32 | 30 min | **timeout (cold)** |

Today's 30 min is **not** the `nix fmt` regression returning:
`full-format`/`nix fmt` ran **2.7 s** this run, and the per-input gate
didn't fire (all inputs `NO UPDATES`). Different cause.

### Confirmed cause: cache-cold `final-build`

- `update.yml` job: `timeout-minutes: 30`.
- Step timing (run 26764860677): all per-input/per-pkg targets done by
  **15:36:40**; then **`final-build`** ran **silently ~27 min** until
  the timeout killed it (PID 10628 alive in the 16:03 process dump).
- `final-build` = `run_nfb_build … nix-fast-build --skip-cached --no-nom
--no-link --flake ".#packages.x86_64-linux"`. The captured
  `final-build.log` shows **16 derivations** built from scratch,
  dominated by **Rust recompiles** (28 fetches of Rust 1.96.0):
  `agnix`, `agnix-lsp`, `agnix-mcp`, `git-absorb`, plus the doc site
  (`docs`, `docs-options-search`, `docs-site`, `docs-site-reference`)
  and Go/Python MCP servers (`github-mcp`, `gitlab-mcp`, `serena-mcp`,
  `*filesystem-mcp`, `*all-mcps`).
- Why cold: the batch merged **`rust-overlay` #210 (→ Rust 1.96.0)** and
  **`nixpkgs` #193** together. Each per-PR CI only cached its package
  against its own base; the merged branch builds every Rust/overlay
  package against the **new toolchain + new nixpkgs** — a combination no
  PR ever built or pushed. So they all recompile. Recurs on every batch
  that bumps the Rust toolchain and/or nixpkgs.
- Aggravator: the trigger fires on **every push**, so the docs-only
  `998f81c` paid the full cold rebuild for nothing.

### Discovered inefficiency: `agnix` builds 3× — ROOT-CAUSED

`overlays/agnix.nix` builds ONE derivation with all three binaries
(`cargoBuildFlags = -p agnix-cli -p agnix-lsp -p agnix-mcp`). The
`agnix-lsp` / `agnix-mcp` attrs (`overlays/{lsp,mcp}-servers/agnix-*.nix`)
are thin `overrideAttrs` setting only `meta.mainProgram`. final-build
showed **three distinct `agnix-0.18.0+2c8f259` drv hashes** (`kxh812l1…`,
`3jrww6pz…`, `z7l2dkw6…`) → three full Rust compiles of identical source.

**Root cause (nix-diff confirmed):** the only differing derivation field
is the env var **`NIX_MAIN_PROGRAM`**. Current nixpkgs
`pkgs/stdenv/generic/make-derivation.nix` injects
`NIX_MAIN_PROGRAM = attrs.meta.mainProgram` into the build env, so
`meta.mainProgram` **is** now a derivation input. The premise that "a
meta-only override can't change the hash" is no longer true for
`mainProgram`. Each `overrideAttrs` re-runs `mkDerivation`, re-deriving
`NIX_MAIN_PROGRAM` from the new value → distinct hash → full recompile.
`inputDrvs`/`args` are byte-identical (same toolchain, same source +
vendor). The `guard`/`ensureUnfreeCheck` is **not** involved (agnix is
MIT/free, so unwrapped).

**Fix (verified empirically):** replace the `overrideAttrs` with a plain
attrset overlay so `mkDerivation` is NOT re-run — `NIX_MAIN_PROGRAM`
stays at the base `"agnix"`, the eval-time `meta.mainProgram` that
`lib.getExe` reads is still overridden:

```nix
# overlays/lsp-servers/agnix-lsp.nix
{agnix}: agnix // {meta = agnix.meta // {mainProgram = "agnix-lsp";};}
# overlays/mcp-servers/agnix-mcp.nix
{agnix}: agnix // {meta = agnix.meta // {mainProgram = "agnix-mcp";};}
```

All three then share ONE drv hash / ONE Rust compile;
`lib.getExe pkgs.ai.lspServers.agnix-lsp` still resolves to
`…/bin/agnix-lsp` (and `…/bin/agnix-mcp`). Tradeoff: the variant becomes
a plain attrset (keeps `type="derivation"`, `drvPath`, `outPath`,
`passthru`) so it loses `.overrideAttrs`/`.override` — nothing downstream
overrides these variants, so this is fine.

**Secondary finding:** `checks/cache-hit-parity.nix` does NOT catch this
(it compares standalone-vs-consumer per variant; both sides re-run the
same override, so each matches itself). Recommend adding a sibling
assertion: `agnix.drvPath == agnix-lsp.drvPath == agnix-mcp.drvPath`.

### Decision 2 (PENDING user choice)

Levers (not mutually exclusive):

- **Raise `timeout-minutes`** (30 → ~90). The cold rebuild is legitimate
  and self-healing (warms cachix so the next run is fast). Risk: a stuck
  worktree now burns the larger budget.
- **Gate the push trigger** to dependency-affecting paths
  (`flake.lock`/`overlays/**`/`config/update-matrix.nix`) or move to
  `schedule:` + `workflow_dispatch`. Stops trivial commits triggering
  it; does _not_ shorten a real cold rebuild.
- **Fix `agnix` 3×-build** — removes redundant Rust compiles everywhere.
- **Scope `final-build`** to skip the doc site (already built by ci.yml
  and docs.yml). Partial.

**Chosen (user, 2026-06-04):** **do NOT raise the timeout right now.** Fix
the `agnix` 3×-build (root-caused above) as the real lever — it removes
2 of 3 agnix Rust compiles from every cold `final-build` (and from
ci.yml). Re-evaluate timeout/trigger-gating afterward if cold runs still
crowd 30 min.

## Validation plan (after approval)

- `treefmt flake.nix`.
- `nix eval .#packages.aarch64-darwin --apply 'builtins.attrNames'`
  → assert no `docs*`/`docs` keys.
- `nix eval .#packages.x86_64-linux --apply 'builtins.attrNames'`
  → assert `docs`/`docs-options-search` still present.
- `nix flake check` (linux).

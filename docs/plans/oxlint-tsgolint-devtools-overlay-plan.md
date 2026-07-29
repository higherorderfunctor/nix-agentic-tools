# oxlint + tsgolint `devTools` Overlay Implementation Plan

> **✅ COMPLETED — 2026-07-21.** All tasks implemented, reviewed (opus
> whole-branch + Copilot), and merged into `refactor/ai-factory-architecture`:
> **PR #417** (feature) + **PR #422** (empirical update-path validation —
> confirmed the standard `nix-update` flow works for both packages, so no
> bespoke updateScript was needed). Step checkboxes below are ticked for the
> record.

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package HEAD-tracked `oxlint` (with working `--type-aware`/tsgo
linting + JS plugins) and its `tsgolint` backend as a new `pkgs.devTools.*`
overlay group in this repo, version-controlled via the update pipeline.

**Architecture:** Thin `overrideAttrs` of the current nixpkgs `oxlint` and
`tsgolint` derivations (which already do the pnpm/JS-plugin build and the
`tsgolint`-on-PATH wrapper), pinned to `oxc-project/oxc` and
`oxc-project/tsgolint` `main` revs. Every build input routes through a
repo-pinned `ourPkgs` for cachix cache-hit parity. oxlint imports the sibling
tsgolint derivation and injects it via `.override { tsgolint = …; }` so the two
stay in lockstep.

**Tech Stack:** Nix (flakes, overlays), nixpkgs `stdenv.mkDerivation` +
`buildGo126Module`, `rustPlatform.fetchCargoVendor`, `fetchPnpmDeps`, the repo's
ninja update pipeline (`nix-update`).

**Spec:** `docs/plans/oxlint-tsgolint-devtools-overlay.md` (read it first).

## Global Constraints

Every task's requirements implicitly include this section.

- **Cache-hit parity:** every build input MUST route through
  `ourPkgs = import inputs.nixpkgs { inherit (final.stdenv.hostPlatform) system; }`.
  Read ONLY `final.stdenv.hostPlatform.system` from `final`; never use
  `final`/`prev` for build inputs. (Gated by `checks.cache-hit-parity`.)
- **Overlay signature:** per-package files take `{inputs, final, ...}:` and are
  imported by `overlays/default.nix`.
- **Inline, nix-computed hashes/revs only:** `rev` from `git ls-remote`; all
  `hash`/`cargoDeps`/`pnpmDeps`/`vendorHash` values from the `lib.fakeHash` →
  build → read-mismatch loop. NEVER hand-author or guess a hash.
- **Flake source visibility:** flakes only see git-tracked files. `git add`
  every new `.nix` file BEFORE `nix build`/`nix flake check`, or nix won't see
  it.
- **tsgolint wiring:** oxlint injects tsgolint via `.override` importing the
  sibling file. oxlint.nix MUST NOT contain a
  `fetchFromGitHub { owner = "oxc-project"; repo = "tsgolint"; }` block (would
  break `checks.overlay-target-resolution`'s "exactly one overlay per repo"
  rule).
- **PATH-prefix, not env-var:** keep the inherited `--prefix PATH : tsgolint`
  wrapper; do NOT set `OXLINT_TSGOLINT_PATH`.
- **tsgolint version floor:** oxlint's optional peer floor is
  `oxlint-tsgolint >= 0.24.0`; HEAD is above it — fine.
- **Platforms:** x86_64-linux + aarch64-darwin. Build/verify locally on
  x86_64-linux only (single `nix build --max-jobs 1` is fine); darwin is
  validated by CI.
- **Commit convention:** Conventional Commits, lowercase imperative, no trailing
  period. Scope = `oxlint` / `tsgolint` / `devtools`.
- **Any new shell script** (bespoke updateScripts) uses full strict mode
  (`set -euETo pipefail; shopt -s inherit_errexit 2>/dev/null || :`) and
  absolute `${pkgs.<x>}/bin/<cmd>` store paths for external commands.

---

### Task 1: `tsgolint` overlay + `devTools` group scaffold

Creates the new group with tsgolint first (oxlint depends on it in Task 2).

**Files:**

- Create: `overlays/dev-tools/tsgolint.nix`
- Modify: `overlays/default.nix` (add `devToolDrvs` + `devTools` group)
- Modify: `flake.nix` (add `// pkgs.devTools` to the packages flatten, ~L399)
- Reference (read-only):
  `/nix/store/…-source/pkgs/by-name/ts/tsgolint/package.nix` in the pinned
  nixpkgs (the base being overridden); `overlays/git-absorb.nix` (pattern);
  `overlays/lib.nix` (`mkVersion`).

**Interfaces:**

- Produces: `overlays/dev-tools/tsgolint.nix` — a function
  `{inputs, final, ...}: <derivation>` evaluating to the tsgolint package.
  Consumed by Task 2's oxlint.nix
  (`import ./tsgolint.nix {inherit inputs final;}`) and exposed as
  `pkgs.devTools.tsgolint` → `.#tsgolint`.

- [x] **Step 1: Capture the current tsgolint main rev**

Run:

```bash
git ls-remote https://github.com/oxc-project/tsgolint.git HEAD | cut -f1
```

Record the 40-hex SHA as `TSGOLINT_REV`. Also record the newest tag for the
version string:

```bash
git ls-remote --tags --sort=-v:refname https://github.com/oxc-project/tsgolint.git 'refs/tags/v*' | head -1
```

Use its `vX.Y.Z` as the `upstream` base (e.g. `0.25.0`). Final version string
will be `"<tag>-unstable+<shortrev>"` — see Step 2.

- [x] **Step 2: Create `overlays/dev-tools/tsgolint.nix` with fake hashes**

```nix
# tsgolint — HEAD-tracked type-aware linting backend for oxlint, pinned
# against `ourPkgs` (this repo's nixpkgs) for cache-hit parity. Thin
# overrideAttrs of nixpkgs' tsgolint: swap src (main rev, submodules),
# version, and vendorHash; inherit the typescript-go submodule patch dance.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  vu = import ../lib.nix;

  rev = "TSGOLINT_REV";
  src = ourPkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "tsgolint";
    inherit rev;
    hash = ourPkgs.lib.fakeHash;
    fetchSubmodules = true;
  };
in
  ourPkgs.tsgolint.overrideAttrs (finalAttrs: _prev: {
    version = vu.mkVersion {
      upstream = "0.25.0-unstable"; # newest tag base from Step 1
      inherit rev;
    };
    inherit src;
    vendorHash = ourPkgs.lib.fakeHash;
  })
```

Replace `TSGOLINT_REV` with the SHA from Step 1 and `0.25.0-unstable` with the
tag base from Step 1.

- [x] **Step 3: Wire the `devTools` group in `overlays/default.nix`**

After the `gitToolDrvs` block, add:

```nix
  # ── Dev tools (linters/formatters) ─────────────────────────────────
  devToolDrvs = {
    tsgolint = import ./dev-tools/tsgolint.nix {
      inherit inputs final;
    };
  };
```

In the returned attrset (currently ending `gitTools = guard gitToolDrvs;`), add
a sibling:

```nix
  devTools = guard devToolDrvs;
```

- [x] **Step 4: Expose the group at flake level in `flake.nix`**

Find the packages flatten (search for `// pkgs.gitTools`). Add a line directly
after it:

```nix
      // pkgs.devTools
```

- [x] **Step 5: git add + build to surface the real src hash**

Run:

```bash
git add overlays/dev-tools/tsgolint.nix overlays/default.nix flake.nix
nix build .#tsgolint --max-jobs 1 2>&1 | tee /tmp/tsgolint-build.log
```

Expected: FAIL with a `hash mismatch in fixed-output derivation` for the
`fetchFromGitHub` src, printing `got: sha256-…`.

- [x] **Step 6: Paste the real src hash, rebuild to surface vendorHash**

Replace `ourPkgs.lib.fakeHash` on the `src` with the `got:` value from Step 5.
Then:

```bash
nix build .#tsgolint --max-jobs 1 2>&1 | tee /tmp/tsgolint-build.log
```

Expected: FAIL with a vendor hash mismatch (`got: sha256-…`) for the Go module
vendor.

- [x] **Step 7: Paste the real vendorHash, rebuild to green**

Replace the `vendorHash = ourPkgs.lib.fakeHash;` with the `got:` value from
Step 6. Then:

```bash
nix build .#tsgolint --max-jobs 1
```

Expected: PASS (produces `./result`).

If the build fails on `patches` (a missing `patches/000N-*.patch` path), the
upstream justfile patch set drifted at this rev — see spec Risk 3. Resolve by
checking `ls <src>/patches/` at the pinned rev and updating the inherited patch
list via an explicit `patches = [ … ];` override; record the deviation in the
spec.

- [x] **Step 8: Smoke test the binary**

Run:

```bash
./result/bin/tsgolint --help
```

Expected: usage/help text, exit 0 (a `headless` subcommand should be listed).

- [x] **Step 9: Commit**

```bash
git add overlays/dev-tools/tsgolint.nix overlays/default.nix flake.nix
git commit -m "feat(tsgolint): add HEAD-tracked tsgolint in new devTools overlay group"
```

---

### Task 2: `oxlint` overlay (wires in our tsgolint)

**Files:**

- Create: `overlays/dev-tools/oxlint.nix`
- Modify: `overlays/default.nix` (add `oxlint` to `devToolDrvs`)
- Reference (read-only):
  `/nix/store/…-source/pkgs/by-name/ox/oxlint/package.nix` in the pinned nixpkgs
  (base being overridden).

**Interfaces:**

- Consumes: `overlays/dev-tools/tsgolint.nix` from Task 1 via
  `import ./tsgolint.nix {inherit inputs final;}`.
- Produces: `pkgs.devTools.oxlint` → `.#oxlint`, an oxlint wrapped with our
  tsgolint on PATH.

- [x] **Step 1: Capture the current oxc main rev + version source**

Run:

```bash
git ls-remote https://github.com/oxc-project/oxc.git HEAD | cut -f1
```

Record as `OXC_REV`. Verify the oxlint version field location (Open Question 1)
at that rev:

```bash
# after src is fetched in Step 3 you can read it; for now note the candidate:
#   apps/oxlint/Cargo.toml → [package].version  (fallback: workspace version)
```

- [x] **Step 2: Create `overlays/dev-tools/oxlint.nix` with fake hashes**

```nix
# oxlint — HEAD-tracked JS/TS linter with type-aware (tsgo) support, pinned
# against `ourPkgs` for cache-hit parity. Thin override of nixpkgs' oxlint:
# inject our sibling tsgolint via .override (so --type-aware uses our HEAD
# backend, kept in lockstep), then overrideAttrs to swap src + the three
# hashes (src, cargoDeps, pnpmDeps). The pnpm/JS-plugin build, OXC_VERSION,
# the tsgolint PATH wrapper, and the --type-aware install check are inherited.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  vu = import ../lib.nix;
  tsgolint = import ./tsgolint.nix {inherit inputs final;};

  rev = "OXC_REV";
  src = ourPkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "oxc";
    inherit rev;
    hash = ourPkgs.lib.fakeHash;
  };
  version = vu.mkVersion {
    upstream = vu.readCargoVersion "${src}/apps/oxlint/Cargo.toml";
    inherit rev;
  };
in
  (ourPkgs.oxlint.override {inherit tsgolint;}).overrideAttrs (finalAttrs: _prev: {
    inherit version src;
    cargoDeps = ourPkgs.rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname version src;
      hash = ourPkgs.lib.fakeHash;
    };
    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = ourPkgs.pnpm_10;
      fetcherVersion = 3;
      hash = ourPkgs.lib.fakeHash;
    };
  })
```

Replace `OXC_REV` with the SHA from Step 1.

- [x] **Step 3: Add oxlint to `devToolDrvs` in `overlays/default.nix`**

```nix
  devToolDrvs = {
    oxlint = import ./dev-tools/oxlint.nix {
      inherit inputs final;
    };
    tsgolint = import ./dev-tools/tsgolint.nix {
      inherit inputs final;
    };
  };
```

- [x] **Step 4: git add + eval-check the version source**

Run:

```bash
git add overlays/dev-tools/oxlint.nix overlays/default.nix
nix eval --raw .#oxlint.version 2>&1 | tee /tmp/oxlint-version.log
```

Expected: EITHER a version like `1.74.0+abcdef1` (good — the
`apps/oxlint/Cargo.toml` field is correct), OR an eval error
`attribute 'version' missing` / file-not-found. If it errors, the version path
is wrong — switch `readCargoVersion "${src}/apps/oxlint/Cargo.toml"` to
`readCargoWorkspaceVersion "${src}/Cargo.toml"` and re-run. (This step may
trigger an IFD source fetch — that's expected.)

- [x] **Step 5: Build to surface the src hash**

Run:

```bash
nix build .#oxlint --max-jobs 1 2>&1 | tee /tmp/oxlint-build.log
```

Expected: FAIL with a `hash mismatch` for the oxc `fetchFromGitHub` src
(`got: sha256-…`).

- [x] **Step 6: Paste src hash, rebuild to surface cargoDeps hash**

Replace the `src` `hash` fakeHash with the `got:` value. Rebuild:

```bash
nix build .#oxlint --max-jobs 1 2>&1 | tee /tmp/oxlint-build.log
```

Expected: FAIL with a mismatch for the cargo vendor (`fetchCargoVendor`)
`got: sha256-…`.

- [x] **Step 7: Paste cargoDeps hash, rebuild to surface pnpmDeps hash**

Replace the `cargoDeps` fakeHash with the `got:` value. Rebuild:

```bash
nix build .#oxlint --max-jobs 1 2>&1 | tee /tmp/oxlint-build.log
```

Expected: FAIL with a mismatch for `pnpmDeps` (`fetchPnpmDeps`) `got: sha256-…`.

- [x] **Step 8: Paste pnpmDeps hash, rebuild — resolve versionCheckHook**

Replace the `pnpmDeps` fakeHash with the `got:` value. Rebuild:

```bash
nix build .#oxlint --max-jobs 1 2>&1 | tee /tmp/oxlint-build.log
```

Two possible outcomes:

- **PASS** — the inherited `versionCheckHook` accepted `oxlint --version` ==
  `<version>`. Continue to Step 9.
- **FAIL in `installCheckPhase` / versionCheckHook** with a version-mismatch
  (binary prints `1.74.0` but derivation `version` is `1.74.0+abcdef1`). Fix by
  stripping the hook (mirrors `overlays/git-tools/git-branchless.nix`): add to
  the `overrideAttrs` body:

```nix
    nativeInstallCheckInputs =
      builtins.filter
      (p: (p.pname or "") != "version-check-hook")
      (_prev.nativeInstallCheckInputs or []);
```

Then rebuild to PASS. (The `--type-aware` + `jsPlugins` sub-checks in
`installCheckPhase` are independent of versionCheckHook and still run.)

- [x] **Step 9: Verify the wrapper points `--type-aware` at OUR tsgolint**

Confirm the wrapper embeds our tsgolint store path (not a bare nixpkgs one):

```bash
grep -o '/nix/store/[^ ]*tsgolint[^ ]*/bin' result/bin/oxlint | head -1
nix eval --raw .#tsgolint.outPath
```

Expected: the path grepped from the wrapper is under the SAME store path as
`.#tsgolint.outPath` (proves the `.override` took effect).

- [x] **Step 10: End-to-end type-aware smoke test**

```bash
tmp=$(mktemp -d); cd "$tmp"
printf '{ "compilerOptions": { "strict": true, "skipLibCheck": true } }\n' > tsconfig.json
printf '{ "rules": { "typescript/no-unnecessary-type-assertion": "error" } }\n' > .oxlintrc.jsonc
printf 'const s: string = "x";\nconst r = s as string;\nexport {};\n' > input.ts
"$OLDPWD/result/bin/oxlint" --type-aware input.ts; echo "exit=$?"
cd "$OLDPWD"
```

Expected: nonzero exit, output naming `no-unnecessary-type-assertion` (proves
tsgolint is invoked at runtime). Also sanity-check
`./result/bin/oxlint --version`.

- [x] **Step 11: Commit**

```bash
git add overlays/dev-tools/oxlint.nix overlays/default.nix
git commit -m "feat(oxlint): add HEAD-tracked oxlint wired to our tsgolint backend"
```

---

### Task 3: Update-pipeline registration + empirical validation

Wires both into the auto-update loop and confirms the two spec validation
points, falling back to bespoke updateScripts only where the standard flow
proves wrong.

**Files:**

- Modify: `config/update-matrix.nix`
- Possibly create/modify: `overlays/dev-tools/tsgolint.nix` and/or
  `overlays/dev-tools/oxlint.nix` (bespoke `passthru.updateScript`, only if
  validation fails)
- Reference (read-only): `overlays/lib.nix` (`mkGitRevUpdateScript`,
  `mkUpdateScript`), `dev/scripts/update-pkg.sh`,
  `checks/overlay-target-resolution.nix`.

**Interfaces:**

- Consumes: `.#oxlint`, `.#tsgolint` targets from Tasks 1–2.
- Produces: `config/update-matrix.nix` entries so `generate-update-ninja` emits
  `update/oxlint` + `update/tsgolint` targets.

- [x] **Step 1: Add both entries to `config/update-matrix.nix`**

In the `nixUpdate` attrset's main-tracking section (alphabetical), add:

```nix
    oxlint = {
      flags = "--version skip";
      git = "https://github.com/oxc-project/oxc.git";
    };
    tsgolint = {
      flags = "--version skip";
      git = "https://github.com/oxc-project/tsgolint.git";
    };
```

- [x] **Step 2: Verify target-resolution + ninja generation**

```bash
git add config/update-matrix.nix
nix build .#checks.x86_64-linux.overlay-target-resolution --max-jobs 1 && cat result
```

Expected: PASS — output includes `ok  oxlint -> overlays/dev-tools/oxlint.nix`
and `ok  tsgolint -> overlays/dev-tools/tsgolint.nix`. If either fails to
"resolve to exactly one overlay with an inline rev", re-check the Global
Constraint (no second tsgolint fetch block in oxlint.nix; both revs are inline
40-hex).

Then:

```bash
nix run .#generate-update-ninja && grep -E 'update/(oxlint|tsgolint)' .update.ninja
```

Expected: both targets appear in the DAG.

- [x] **Step 3: Dry-validate the oxlint 3-hash bump (Validation Point 1)**

In an isolated worktree, force a re-resolve of all three hashes to confirm
`nix-update` handles src + cargoDeps + pnpmDeps together. Cheapest proxy: set
all three oxlint hashes back to `ourPkgs.lib.fakeHash`, then run the repo's
per-package update path against the current rev:

```bash
# from repo root, in a scratch copy — do NOT commit the fakeHash state
NAT_UPDATE_WORKTREES_DIR="${TMPDIR:-/tmp}/nat-update-wt" \
  bash dev/scripts/update-pkg.sh oxlint "--version skip" https://github.com/oxc-project/oxc.git 2>&1 | tail -40
```

Expected: the script rewrites all three hashes to real values and the build
verifies. If `nix-update` leaves any of the three as a fake/empty hash (build
still fails), the standard flow is insufficient → do Step 4a. Otherwise skip to
Step 5. Restore the real hashes afterward
(`git checkout overlays/dev-tools/oxlint.nix`).

- [x] **Step 4a: (only if Step 3 failed) Bespoke oxlint updateScript**

Switch the matrix entry to `oxlint = { flags = "--use-update-script"; };` (drop
`git`), and add to oxlint.nix's `overrideAttrs` body a `passthru.updateScript`
that: (1) `git ls-remote` the oxc rev, (2) sed the `rev`, (3)
`nix-prefetch-url`/`nix build .#oxlint.src` loop to fill `src`, `cargoDeps`,
`pnpmDeps` via successive fake-hash rebuilds captured in-script. Use
`overlays/lib.nix:mkGitRevUpdateScript` for the rev step; extend with three
`nix build … |& sed`-driven hash captures. Full strict mode + absolute store
paths per Global Constraints. Re-run Step 2's `generate-update-ninja` check.

- [x] **Step 4b: Validate the tsgolint submodule bump (Validation Point 2)**

Same worktree probe for tsgolint (src + vendorHash), which has
`fetchSubmodules=true`:

```bash
NAT_UPDATE_WORKTREES_DIR="${TMPDIR:-/tmp}/nat-update-wt" \
  bash dev/scripts/update-pkg.sh tsgolint "--version skip" https://github.com/oxc-project/tsgolint.git 2>&1 | tail -40
```

Expected: `nix-update` re-derives the submodule-aware src hash + vendorHash
correctly (it realizes the `fetchFromGitHub`, which respects `fetchSubmodules`).
If the committed src hash ends up WRONG (source 404 / hash mismatch on verify),
the pipeline's `nix flake prefetch` pre-step poisoned it → switch tsgolint to
`flags = "--use-update-script";` (drop `git`) with a bespoke
`passthru.updateScript` using
`${pkgs.nix-prefetch-git}/bin/nix-prefetch-git --fetch-submodules` for the src
hash + a fake-hash rebuild for `vendorHash`. Full strict mode + absolute paths.
Restore real hashes afterward.

- [x] **Step 5: Commit**

```bash
git add config/update-matrix.nix overlays/dev-tools/oxlint.nix overlays/dev-tools/tsgolint.nix
git commit -m "feat(devtools): register oxlint + tsgolint in the update pipeline"
```

---

### Task 4: Docs wiring + full flake check

**Files:**

- Modify: `checks/cache-hit-parity.nix` (register `devToolPackages`)
- Modify: `overlays/default.nix` (header doc-comment: add `pkgs.devTools.*`)
- Modify: `dev/data.nix` (`overlayPackages` + descriptions)
- Modify: `overlays/README.md` (package index)
- Reference (read-only): `dev/generate.nix`, `flake.nix` docs generators.

**Interfaces:**

- Consumes: the completed overlay + matrix from Tasks 1–3.
- Produces: doc-data registration so generated README/docsite list the
  `dev-tools` group; the `cache-hit-parity` check actually covering the new
  packages; a green `nix flake check`.

- [x] **Step 1: Register the devTools packages in the cache-hit-parity check**

`checks/cache-hit-parity.nix` gates cache-hit parity via **hardcoded per-group
allowlists** (`aiCliPackages`, `gitToolPackages`, `mcpServerPackages`,
`agnixPackages`, `specialPackages`), aggregated into `allDrifts`. There is no
`devToolPackages`, so the check currently **skips `oxlint`/`tsgolint` entirely**
— the Global Constraint "a regression fails `checks.cache-hit-parity`" is false
for them until registered (surfaced by the Task 1 review).

Read the file first to match its exact evaluation shape (how each list is mapped
through the standalone-vs-consumer store-path comparison). Add a
`devToolPackages = ["oxlint" "tsgolint"];` list mirroring `gitToolPackages`, and
fold it into the same aggregation `gitToolPackages` feeds (`allDrifts`).

Also update the `overlays/default.nix` header doc-comment (the
`Aggregates derivations into grouped namespaces: …` block) to add
`pkgs.devTools.*`.

Verify the check now SEES them (is a live gate, not a no-op):

```bash
git add checks/cache-hit-parity.nix overlays/default.nix
nix build .#checks.x86_64-linux.cache-hit-parity --max-jobs 1 && cat result
```

Expected: PASS ("no drift"), with the drift logic now iterating oxlint +
tsgolint. To prove the gate is live, temporarily point one package's build input
at `final` instead of `ourPkgs`, re-run, confirm it FAILS, then revert.

- [x] **Step 2: Register the group in `dev/data.nix`**

In `overlayPackages`, add (alphabetically, kebab key):

```nix
    dev-tools = {
      packages = ["oxlint" "tsgolint"];
      suffix = null;
    };
```

If the doc generator reads per-package descriptions from a map like
`gitToolDescriptions`, add matching entries near it (find how `git-tools`
descriptions are threaded and mirror it):

```nix
    oxlint = "JS/TS linter with type-aware (tsgo) linting and JS plugins";
    tsgolint = "Type-aware linting backend for oxlint (typescript-go)";
```

- [x] **Step 3: Determine whether `overlays/README.md` is generated or
      hand-maintained**

Run:

```bash
grep -rn "overlays/README" dev/ flake.nix 2>/dev/null
```

- If a generator writes it → edit the generator's data source (likely
  `dev/data.nix` from Step 1) and regenerate in Step 4.
- If hand-maintained (no generator hit) → add a `devTools` group section and two
  rows to the package table in `overlays/README.md`:

```
| oxlint    | devTools | GitHub main | pnpm (nixpkgs override) | `oxlint`   | inherited installCheck | --type-aware |
| tsgolint  | devTools | GitHub main | go (nixpkgs override)   | `tsgolint` | upstream               | --help       |
```

- [x] **Step 4: git add and run the full flake check**

```bash
git add dev/data.nix overlays/README.md
nix flake check --max-jobs 1 2>&1 | tee /tmp/flake-check.log
```

Expected: PASS. Specifically `cache-hit-parity` (both packages route through
`ourPkgs`) and `overlay-target-resolution` are green. If `cache-hit-parity`
reports drift, a build input is using `final`/`prev` instead of `ourPkgs` — fix
in the offending overlay file.

- [x] **Step 5: Regenerate docs if applicable**

If Step 2 found a generator:

```bash
devenv tasks run --mode before generate:repo
git diff --stat
```

Expected: README/docsite files regenerate with the `dev-tools` group; stage
them.

- [x] **Step 6: Commit**

```bash
git add checks/cache-hit-parity.nix dev/data.nix overlays/default.nix overlays/README.md README.md docs/ 2>/dev/null; git add -A
git commit -m "docs(devtools): document oxlint + tsgolint in the overlay index"
```

---

## Self-Review

**Spec coverage:**

- Two thin `ourPkgs` overrides (oxlint + tsgolint) → Tasks 1–2. ✓
- oxlint injects our tsgolint via `.override` → Task 2 Steps 2, 9. ✓
- `devTools` group across `default.nix` / `flake.nix` / `dev/data.nix` / README
  → Tasks 1 (Steps 3–4), 4. ✓
- tsgolint exposed as `pkgs.devTools.tsgolint` → Task 1 (in `devToolDrvs`). ✓
- Update-matrix (standard-first, bespoke fallback), both validation points →
  Task 3. ✓
- Risk 1 versionCheckHook → Task 2 Step 8. Risk 2 nix-update multi-hash → Task 3
  Steps 3/4a. Risk 3 patch drift → Task 1 Step 7. Risks 4–5 accepted (no
  action). ✓
- Verification (`nix build`, `nix flake check`, `--type-aware` smoke, ninja dry
  check) → Tasks 1 Step 8, 2 Step 10, 3 Step 2, 4 Step 3. ✓
- Open Q1 (oxlint version source) → Task 2 Step 4. Open Q2 (tsgolint version
  source) → Task 1 Step 1. Open Q3 (README generated?) → Task 4 Step 2. ✓

**Placeholder scan:** `OXC_REV` / `TSGOLINT_REV` / `0.25.0-unstable` are
captured live in the respective Step 1s (nix-computed rev / real tag), not
authored guesses; all hashes come from the fakeHash loop. No `lib.fakeHash` may
remain in a committed file. No TBD/TODO. ✓

**Type consistency:** `devToolDrvs`, `devTools`, `pkgs.devTools`, `dev-tools`
(docs key) used consistently; `import ./tsgolint.nix {inherit inputs final;}`
signature matches Task 1's produced interface; `readCargoVersion`/`mkVersion`
match `overlays/lib.nix`. ✓

# Spec: `devTools` overlay group — HEAD-tracked `oxlint` + `tsgolint`

**Date:** 2026-07-20 **Status:** Design approved (awaiting spec review →
implementation plan) **Branch context:** `refactor/ai-factory-architecture`

> Working doc. Per repo convention plan/spec docs stay **untracked** (not
> committed, not in PRs) unless explicitly requested.

## Goal

Package `oxlint` in this repo behind an overlay so its version is controlled
here (decoupled from the nixpkgs pin), with type-aware (tsgo) linting working
out of the box. Package its type-aware backend `tsgolint` alongside it.

## Approved decisions

| Decision          | Choice                                                                                                                 |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Version tracking  | **HEAD-track both** oxlint (`oxc-project/oxc` main) and tsgolint (`oxc-project/tsgolint` main)                         |
| Namespace         | New **`devTools`** overlay group (`pkgs.devTools.*`)                                                                   |
| tsgolint exposure | Exposed as `pkgs.devTools.tsgolint` (so the update pipeline can version-control it independently)                      |
| Build approach    | **Override the current nixpkgs derivations** via the `ourPkgs` cache-hit-parity pattern — do NOT re-derive from source |

The HEAD choice is deliberate and informed: upstream has no nightly channel (its
"edge" is weekly stable releases), and oxlint↔tsgolint type-aware is explicitly
exempt from semver. The user accepts the resulting brittleness (see Risks) in
exchange for tracking unreleased commits.

## Background — why this collapses to thin overrides

The current nixpkgs `oxlint` (1.73.0 in this repo's pinned nixpkgs;
`stdenv.mkDerivation`, not `buildRustPackage`) already does everything asked:

- builds via `pnpm --filter oxlint-app run build` — the JS-plugin-capable
  runtime (the standalone Rust binary leaves `jsPlugins` **inert**),
- sets `env.OXC_VERSION`,
- **wraps the binary with `tsgolint` on `PATH`** via
  `makeBinaryWrapper … --prefix PATH : "${lib.makeBinPath [ tsgolint ]}"`, and
- runs an `installCheckPhase` that actively exercises `oxlint --type-aware`
  **and** a `jsPlugins` smoke test.

`oxlint` takes `tsgolint` as a plain function argument, so an overlay can swap
in its own tsgolint with `.override { tsgolint = …; }` — no source patching.

Both existing external overlays (`charter-developer-platform`, `nixos-config`)
predate this and are obsolete: old `buildRustPackage`, tsgolint only as a test
input (no runtime wrapper), no JS plugins.

### Research-validated wiring detail

Keep the inherited **PATH-prefix** wrapper; do **not** set
`OXLINT_TSGOLINT_PATH`. oxlint's discovery order is env-var →
`node_modules/.bin/tsgolint` → PATH. PATH-prefix installs our Nix tsgolint as a
_fallback_ that still lets a project's own pinned `node_modules/.bin/tsgolint`
win — least-surprising. The env-var override would force ours and hard-error if
wrong. (Source: `crates/oxc_linter/src/tsgolint.rs`.)

## Architecture

Two new per-package overlay files under a new `overlays/devTools/` dir, imported
by `overlays/default.nix` into a `devTools` group. oxlint imports the sibling
tsgolint derivation and wires it via `.override`, so `--type-aware` uses **our**
HEAD tsgolint (kept in lockstep).

### `overlays/devTools/oxlint.nix` (new)

Shape (grounded in `git-absorb.nix` + nixpkgs `oxlint` package.nix):

```nix
{inputs, final, ...}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  vu = import ../lib.nix;
  tsgolint = import ./tsgolint.nix {inherit inputs final;};   # sibling derivation

  rev = "<40-hex oxc main>";
  src = ourPkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "oxc";
    inherit rev;
    hash = "<sri>";
  };
  version = vu.mkVersion {
    upstream = vu.readCargoVersion "${src}/apps/oxlint/Cargo.toml"; # verify field/path at impl
    inherit rev;
  };
in
  (ourPkgs.oxlint.override {inherit tsgolint;}).overrideAttrs (finalAttrs: _prev: {
    inherit version src;
    cargoDeps = ourPkgs.rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname version src;
      hash = "<sri>";
    };
    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = ourPkgs.pnpm_10;
      fetcherVersion = 3;
      hash = "<sri>";
    };
    # env.OXC_VERSION = finalAttrs.version in the base → follows `version`
    # automatically via the fixpoint; no need to re-set.
  })
```

Three hashes change on every rev bump: `src`, `cargoDeps` (fetchCargoVendor),
`pnpmDeps` (fetchPnpmDeps). All build inputs route through `ourPkgs` (cache-hit
parity). The inherited installPhase wrapper picks up our `tsgolint` arg; the
inherited installCheck gates `--type-aware`.

### `overlays/devTools/tsgolint.nix` (new)

```nix
{inputs, final, ...}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  vu = import ../lib.nix;

  rev = "<40-hex tsgolint main>";
  src = ourPkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "tsgolint";
    inherit rev;
    hash = "<sri>";
    fetchSubmodules = true;      # typescript-go submodule — load-bearing
  };
in
  ourPkgs.tsgolint.overrideAttrs (finalAttrs: _prev: {
    version = vu.mkVersion {
      upstream = "<tsgolint version source — verify>";   # see Open questions
      inherit rev;
    };
    inherit src;
    vendorHash = "<sri>";
    # patches/prePatch/postPatch inherited; the base's `patches` reference
    # `finalAttrs.src + "/patches/…"` and follow the new src via the fixpoint.
  })
```

Two hashes change on bump: `src` (submodule-aware) and `vendorHash`.

### Group wiring

- `overlays/default.nix`: add
  ```nix
  devToolDrvs = {
    oxlint   = import ./devTools/oxlint.nix   {inherit inputs final;};
    tsgolint = import ./devTools/tsgolint.nix {inherit inputs final;};
  };
  ```
  and in the return set `devTools = guard devToolDrvs;`.
- `flake.nix` (~L399): add `// pkgs.devTools` to the packages flatten so
  `nix build .#oxlint` / `.#tsgolint` work with no further edits.
- `dev/data.nix` `overlayPackages`: add a **`dev-tools`** entry (kebab-case,
  matching the existing `ai-clis` / `git-tools` keys) with
  `packages = ["oxlint" "tsgolint"]`; add description strings (mirrors
  `gitToolDescriptions`) for the generated docs/README.
- `overlays/README.md`: new group + 2 rows in the package table.

## Update-pipeline strategy

Register in `config/update-matrix.nix`. Start both as **standard main-tracking
git-entries**, validate empirically, fall back to bespoke only where the
standard flow proves wrong:

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

Both satisfy `checks.overlay-target-resolution`: each resolves to exactly one
overlay with an inline 40-hex `rev`, and `oxc` vs `tsgolint` are distinct
owner/repo. **Constraint:** oxlint.nix must wire tsgolint by importing the
sibling derivation, **not** by inlining a second `oxc-project/tsgolint` fetch
block — else tsgolint's URL would match two files and fail the "exactly one"
rule.

Validation points (must confirm during implementation):

1. **oxlint 3-hash bump** — does `nix-update --version skip` update `src` +
   `cargoDeps` (fetchCargoVendor) + `pnpmDeps` (fetchPnpmDeps) in one pass on an
   `overrideAttrs` overlay? No existing package here combines cargo-vendor
   - pnpm. If not, switch oxlint to a bespoke `--use-update-script`.
2. **tsgolint submodule hash** — the pipeline's rev-bump pre-step runs
   `nix flake prefetch github:owner/repo/rev`, which does **not** fetch
   submodules → wrong intermediate `src` hash. `nix-update --version skip` may
   self-correct it (it rebuilds the fetchFromGitHub derivation, which respects
   `fetchSubmodules`). If it does not fully correct, switch tsgolint to a
   bespoke `--use-update-script` using `nix-prefetch-git --fetch-submodules` for
   the src hash + a vendorHash recompute.

## Risks & mitigations (all consequences of HEAD-tracking; accepted)

1. **`versionCheckHook`** (inherited) asserts `oxlint --version` == derivation
   `version`. `mkVersion` yields `1.74.0+abc1234`; `OXC_VERSION` carries that
   into `--version`. If oxlint re-formats/drops the `+build` metadata → hook
   fails. Mitigation: set `OXC_VERSION` to the clean upstream version and strip
   `versionCheckHook` from `nativeInstallCheckInputs` (as `git-branchless.nix`
   already does), or accept the `+rev` form if it round-trips. Decide at impl
   after observing `oxlint --version`.
2. **`nix-update` multi-hash** on the oxlint override (see Validation 1).
3. **tsgolint hardcoded 5-patch list** is upstream-justfile-derived; a HEAD that
   adds/renames a patch breaks the build → held-back PR. Inherent.
4. **type-aware semver-exempt desync**: oxlint-main and tsgolint-main can drift
   mid-week; the inherited `--type-aware` install check catches it at build time
   → held-back PR rather than a broken binary. This is the safety net that makes
   HEAD-tracking-both tolerable.
5. **Heavier closure**: nodejs-slim + tsgolint (Go + embedded typescript-go, ~22
   MB) vs the old static Rust binary.

## Verification plan

- `nix build .#oxlint .#tsgolint` (single `--max-jobs 1`; guarded local build is
  fine). Inherited installCheck already proves `--type-aware` + `jsPlugins`.
- `nix flake check` → `cache-hit-parity` (all inputs via `ourPkgs`) +
  `overlay-target-resolution` (both resolve to unique overlays with revs).
- Smoke: `result/bin/oxlint --version`; `oxlint --type-aware` on a TS fixture
  with a `typescript/*` rule; confirm the wrapper points `--type-aware` at _our_
  tsgolint (not a nixpkgs one).
- `nix run .#generate-update-ninja` dry check that oxlint + tsgolint appear as
  update targets.

## Out of scope (YAGNI)

- `oxfmt` (oxc's formatter) — not requested; the `devTools` name leaves room if
  wanted later.
- `oxc-vscode` extension (separately packaged as
  `vscode-extensions.oxc.oxc-vscode`).
- A separate LSP package — the LSP is `oxlint --lsp` on the same binary.
- Consumer HM/module wiring — this spec packages the overlay only. Consumers
  (charter, nixos-config) adopt `pkgs.devTools.oxlint` separately.

## Open questions (verify at implementation, non-blocking)

1. **oxlint version source** — is the release version in
   `apps/oxlint/Cargo.toml [package].version`, or the workspace version, or a
   `package.json`? Pick the field `mkVersion.upstream` reads.
2. **tsgolint version source** — tsgolint's nixpkgs derivation hardcodes
   `version` and derives `tag = v${version}`. HEAD has no tag; determine a clean
   upstream string (VERSION file? `package.json` of the npm `oxlint-tsgolint`?
   most-recent tag baked by the updateScript?). Fallback:
   `mkVersion { upstream = "<latest-tag>-unstable"; rev; }`.
3. Whether `overlays/README.md` is hand-maintained or generated (edit source
   accordingly).

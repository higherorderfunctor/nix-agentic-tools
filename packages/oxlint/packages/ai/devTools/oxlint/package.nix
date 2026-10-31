# cspell:ignore andrewbranch Funtar
# oxlint — HEAD-tracked JS/TS linter with type-aware (tsgo) support.
# Thin override of nixpkgs' oxlint:
# inject our sibling tsgolint via .override (so --type-aware uses our HEAD
# backend, kept in lockstep), then overrideAttrs to swap src + the three
# hashes (src, cargoDeps, pnpmDeps). The pnpm/JS-plugin build, OXC_VERSION,
# the tsgolint PATH wrapper, and the --type-aware install check are inherited.
{
  inputs,
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  rustToolchainChannel = "1.99.1";
  rustPlatform = packageLib.mkRustPlatform {
    channel = rustToolchainChannel;
    inherit pkgs;
    pname = "oxlint";
    recipeFile = repoPath ./package.nix;
  };
  vu = packageLib;
  tsgolint = import ../../../../../tsgolint/packages/ai/devTools/tsgolint/package.nix {inherit inputs packageLib pkgs repoPath;};

  rev = "6c680c7a62f9423078f7bdb288c31761c3763d12";
  unpatchedSrc = pkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "oxc";
    inherit rev;
    hash = "sha256-ifX2HYCWTJvAwohHVoz06ppwTsSxlb1q+AKwT90k4zY=";
  };
  # Keep pnpm responsible for patching every peer variant. A name-only key
  # follows upstream versions; context application and the behavioral probe
  # decide compatibility, not a separately maintained version gate.
  napiPatch = ../../../../patches/oxlint-napi-rs-cli.patch;
  napiPatchPath = "patches/${builtins.baseNameOf napiPatch}";
  napiPatchHash = builtins.hashFile "sha256" napiPatch;
  verifyNapiPatch = ''
    node ${../../../../src/verify-napi-patch.mjs} node_modules/.pnpm
  '';
  src = pkgs.applyPatches {
    src = unpatchedSrc;
    postPatch = ''
      if [ -e ${napiPatchPath} ]; then
        echo "oxlint: upstream already owns ${napiPatchPath}; reconcile the patches" >&2
        exit 1
      fi
      install -Dm644 ${napiPatch} ${napiPatchPath}
      apply_patch_meta() {
        awk -v pkg="@napi-rs/cli" \
            -v val="$1" -v q="$2" -v tag="$3" -v ph="${napiPatchHash}" \
            -f ${../../../../src/oxlint-pnpm-patch-meta.awk} "$4" > "$4.tmp"
        mv "$4.tmp" "$4"
      }
      apply_patch_meta "${napiPatchPath}" '"' "" pnpm-workspace.yaml
      apply_patch_meta "${napiPatchHash}" "'" stamp pnpm-lock.yaml
    '';
  };
  version = vu.mkVersion {
    # upstream: readCargoVersion @ apps/oxlint/Cargo.toml
    upstream = "1.90.0";
    inherit rev;
  };
in
  (pkgs.oxlint.override {
    inherit rustPlatform tsgolint;
    inherit (rustPlatform.rust) cargo rustc;
  }).overrideAttrs (finalAttrs: prev: {
    inherit version src;
    passthru = (prev.passthru or {}) // rustPlatform.passthru;
    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname version src;
      hash = "sha256-LIVlLts8/z7hYvSS62b6dWCEwE6CI+aqRnxub3H8QTM=";
    };
    pnpmDeps = pkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = pkgs.ai.generic.pnpm_11;
      fetcherVersion = 4;
      postInstall = verifyNapiPatch;
      hash = "sha256-FMD1r2kpEDa1GMCgRAw6XEm7iDJZYK4ydwAGrfsj8TA=";
    };
    # Validate cached dependency materialization too, before compiling Rust.
    preBuild = verifyNapiPatch + (prev.preBuild or "");
    # Oxc declares pnpm@12.3.2 in `packageManager`, and we DELIBERATELY stay on
    # pnpm 11 until a swap is validated against this consumer. pnpm 12 needs a
    # non-empty registry base: given an empty one, every request becomes a
    # relative URL (measured: metadata fetches against bare paths like
    # `/@andrewbranch%2Funtar.js`), and disabling pnpm's supply-chain check only
    # moves the failure to the tarball endpoint. The pinned fetcher passes
    # `--registry` only when NIX_NPM_REGISTRY is set
    # (fetch-pnpm-deps/default.nix:167).
    # Replace nixpkgs Oxlint's own pnpm in BOTH places — the dependency fetcher
    # above and the build input here — so both phases use the same major.
    # checks/packaging/pnpm-fetcher-parity.nix asserts those two are the same store path,
    # so they can never drift apart silently.
    nativeBuildInputs =
      map
      (input:
        if (input.pname or "") == "pnpm"
        then pkgs.ai.generic.pnpm_11
        else input)
      (prev.nativeBuildInputs or []);
    # Strip versionCheckHook: `oxlint --version` prints the bare upstream
    # semver (e.g. 1.74.0) and drops the `+shortrev` build metadata that
    # `mkVersion` puts in the derivation version, so the hook never matches
    # and aborts installCheck. Same handling as
    # packages/git-branchless/packages/ai/gitTools/git-branchless/package.nix. The inherited installCheckPhase
    # (`--type-aware` via our tsgolint + the jsPlugins smoke) is independent
    # and still runs.
    nativeInstallCheckInputs =
      builtins.filter
      (p: (p.pname or "") != "version-check-hook")
      (prev.nativeInstallCheckInputs or []);
    # Base meta.changelog is `…/releases/tag/${src.tag}`, but our rev-based src
    # has no `tag`, so accessing meta.changelog coerces null → eval throw.
    # Re-point it at the pinned commit (also re-anchors meta.position here).
    meta = prev.meta // {changelog = "https://github.com/oxc-project/oxc/commit/${rev}";};
  })

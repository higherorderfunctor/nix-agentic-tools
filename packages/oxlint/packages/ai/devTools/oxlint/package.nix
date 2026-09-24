# cspell:ignore andrewbranch Funtar
# oxlint — HEAD-tracked JS/TS linter with type-aware (tsgo) support, pinned
# against `ourPkgs` for cache-hit parity. Thin override of nixpkgs' oxlint:
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
  ourPkgs = pkgs;
  vu = packageLib;
  tsgolint = import ../../../../../tsgolint/packages/ai/devTools/tsgolint/package.nix {inherit inputs packageLib pkgs repoPath;};

  rev = "4e77d59bc02f9218b4bb6b89ca08b4f21dd21380";
  unpatchedSrc = ourPkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "oxc";
    inherit rev;
    hash = "sha256-xX0HVAYKlKnOH/Gro7OKtzGoeh8Ocpx9NRHzXrMd2Os=";
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
  src = ourPkgs.applyPatches {
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
    upstream = "1.85.0";
    inherit rev;
  };
in
  (ourPkgs.oxlint.override {inherit tsgolint;}).overrideAttrs (finalAttrs: prev: {
    inherit version src;
    cargoDeps = ourPkgs.rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname version src;
      hash = "sha256-QCWzjecI8E/iemfMKnt2okidYbUcc8j7vB/V4wbh91M=";
    };
    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = ourPkgs.pnpm_11;
      fetcherVersion = 4;
      postInstall = verifyNapiPatch;
      hash = "sha256-JwzpLHXuWygjFINd6QREvw2x/LOe0MXM/5rU51Nic10=";
    };
    # Validate cached dependency materialization too, before compiling Rust.
    preBuild = verifyNapiPatch + (prev.preBuild or "");
    # Oxc declares pnpm@12.3.2 in `packageManager`, and we DELIBERATELY stay on
    # pnpm 11. nixpkgs' fetcher interpolates `--registry="$NIX_NPM_REGISTRY"`
    # unconditionally (fetch-pnpm-deps/default.nix:149) and that variable has no
    # default anywhere in nixpkgs, so the fetcher hands pnpm an EMPTY registry
    # base. pnpm 11 falls back to the default registry; pnpm 12's Rust rewrite
    # does not, and every request becomes a relative URL — measured, the install
    # dies with metadata fetches against bare paths like `/@andrewbranch%2Funtar.js`.
    # Disabling pnpm's supply-chain check does NOT work around it: the same
    # empty-base failure just resurfaces one stage later at the tarball endpoint.
    #
    # Revisit when the nixpkgs pin carries a registry-guard fix; the swap then
    # needs a `NIX_NPM_REGISTRY` default supplied here in the same change.
    # Replace nixpkgs Oxlint's own pnpm in BOTH places — the dependency fetcher
    # above and the build input here — so both phases use the same major.
    # checks/packaging/pnpm-fetcher-parity.nix asserts those two are the same store path,
    # so they can never drift apart silently.
    nativeBuildInputs =
      map
      (input:
        if (input.pname or "") == "pnpm"
        then ourPkgs.pnpm_11
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

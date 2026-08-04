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

  rev = "9c8c5e521b97f4ef08af75fab11d6a065bdc8ae4";
  unpatchedSrc = ourPkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "oxc";
    inherit rev;
    hash = "sha256-EIlFBCkMBAESeK2cW/sKUYp3WRkW6LwSOi77ZryWK0Q=";
  };
  # @napi-rs/cli 3.8.2's filesystem reconciliation probes a process
  # incarnation with execFile(/bin/ps) on Darwin. Node can reject that spawn
  # synchronously under Nix's Seatbelt profile, before the callback's existing
  # error fallback runs. Patch the dependency through pnpm's native
  # patchedDependencies mechanism so every peer variant gets the same fix and
  # the dependency layer owns it; do not admit a host executable into the
  # build. The fetcher FOD still holds the original registry bytes rather than
  # prepatched content; pnpm applies this patch while materializing its virtual
  # store. A failed probe still resolves to null, preserving napi-rs's
  # fail-closed stale-lock behavior. Drop this when the catch ships upstream.
  src = ourPkgs.applyPatches {
    src = unpatchedSrc;
    patches = [./oxlint-napi-rs-cli.patch];
  };
  version = vu.mkVersion {
    # upstream: readCargoVersion @ apps/oxlint/Cargo.toml
    upstream = "1.77.0";
    inherit rev;
  };
in
  (ourPkgs.oxlint.override {inherit tsgolint;}).overrideAttrs (finalAttrs: prev: {
    inherit version src;
    cargoDeps = ourPkgs.rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname version src;
      hash = "sha256-AJHfTJe1oyflsjqx128FfZJlqVH1hX2ityAoR9E3rXM=";
    };
    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = ourPkgs.pnpm_11;
      fetcherVersion = 4;
      hash = "sha256-JRdVGRAFSXqyFnH2QO1/JSpCYwnEECi9EWlKYzrGCdA=";
    };
    # Oxc declares pnpm 11.17.0. Replace nixpkgs Oxlint's pnpm 10 build input
    # as well as its dependency fetcher so both phases use the upstream major.
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
    # overlays/git-tools/git-branchless.nix. The inherited installCheckPhase
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

# pnpm 12 — override nixpkgs' source-built pnpm_12 now that it exists;
# the operator prefers compiling over unpacking upstream's native binaries.
# Our version, dependency pins, loader preparation, locked Rust platform and
# update script move. Nixpkgs owns the phases, install layout, completions
# and metadata.
# Use .override for version: the GitHub tag, majorVersion and upstream update
# selector read the ARGUMENT version, so overrideAttrs would keep the old tag.
# Historical binary/placeholder measurements:
# `git show 58e27237:packages/pnpm/packages/ai/generic/pnpm_12/package.nix`.
{
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) lib;
  sources = builtins.fromJSON (builtins.readFile ../../../../sources-12.json);
  srcHash = sources.srcHash or lib.fakeHash;
  sourcesFile = repoPath ../../../../sources-12.json;
  sidecarMajor = lib.versions.major sources.version;
  # Bootstrap with the pinned JavaScript implementation, never the Rust
  # pnpm being built. Fetch and configure must use the same store layout.
  pnpm = pkgs.ai.generic.pnpm_11;
  # Upstream's global virtual store nests package files inside the fetcher's
  # metadata tree, where nixpkgs would try to normalize non-JSON fixtures.
  pnpmInstallFlags = [
    "--config.enable-global-virtual-store=false"
    # Nix supplies Node; skip upstream's platform-specific runtime downloads
    # while retaining their entries for frozen-lockfile validation.
    "--no-runtime"
  ];
  pnpmWorkspaces = ["@pnpm/esm-loader"];

  # mkUpdateScript writes a version-only candidate; fake hashes let the fixers
  # evaluate it, then restore source before deriving its dependency trees.
  fixVendorHash = packageLib.mkHashFix {
    inherit pkgs sourcesFile;
    attr = "pnpm_12";
    name = "vendor-hash";
    pname = "pnpm_12";
    targets = [
      packageLib.hashFixTargets.src
      {
        attrPath = "cargoDeps";
        drvPattern = "-vendor";
        key = "cargoHash";
      }
      packageLib.hashFixTargets.pnpmDeps
    ];
  };
  package = pkgs.pnpm_12.override {
    inherit (sources) version;
    inherit srcHash;
    cargoHash = sources.cargoHash or lib.fakeHash;
    rustPlatform = packageLib.mkRustPlatform {inherit pkgs;};
  };
in
  assert lib.assertMsg (sidecarMajor == "12") ''
    pnpm_12: packages/pnpm/sources-12.json records version "${sources.version}" (major ${sidecarMajor}), but this attribute is pnpm_12.
    Either point the sidecar back at a 12.x release, or add a pnpm_${sidecarMajor} attribute and move it there.
  '';
  # No postPatch of our own: nixpkgs strips the cargo-sources block itself.
  # The removed copy: `git show f38b946f:packages/pnpm/packages/ai/generic/pnpm_12/package.nix`.
    package.overrideAttrs (finalAttrs: prev: {
      inherit pnpmInstallFlags pnpmWorkspaces;
      pnpmDeps = pkgs.fetchPnpmDeps {
        inherit (finalAttrs) src version;
        inherit pnpm pnpmInstallFlags pnpmWorkspaces;
        fetcherVersion = 4;
        hash = sources.pnpmDepsHash or lib.fakeHash;
        pname = "pnpm-${finalAttrs.version}";
      };
      nativeBuildInputs =
        (prev.nativeBuildInputs or [])
        ++ [
          pkgs.nodejs
          pnpm
          pkgs.pnpmConfigHook
        ];
      preBuild =
        (prev.preBuild or "")
        + ''
          (
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          node pnpm/esm-loader/scripts/bundle-runtime.mjs
          )
        '';
      doInstallCheck = true;
      # Upstream's passthru testVersion is separate from the package build.
      # Keep its install checks if introduced, and require our exact pin too.
      # Scoped in a subshell so strict mode does not leak into later hooks.
      postInstallCheck =
        (prev.postInstallCheck or "")
        + ''
          (
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          got=$("$out/bin/pnpm" --version)
          if [ "$got" != "${finalAttrs.version}" ]; then
            echo "pnpm_12: binary reports $got, sidecar pins ${finalAttrs.version}" >&2
            false
          fi
          "$out/bin/pnpx" --help >/dev/null
          )
        '';
      passthru =
        (prev.passthru or {})
        // {
          # Also discovered by fix_sidecar_hashes after nixpkgs input changes.
          inherit fixVendorHash;
          updateScript = packageLib.mkUpdateScript {
            inherit pkgs sourcesFile;
            pname = "pnpm_12";
            platforms = {};
            extraExtract = "${fixVendorHash}";
            # npm's per-major dist-tag picks the release; the source fixer then
            # fetches the matching GitHub tag and fails loudly if it is missing.
            versionCheck.cmd = "${pkgs.curl}/bin/curl -fsSL https://registry.npmjs.org/pnpm | ${pkgs.jq}/bin/jq -r '.[\"dist-tags\"][\"latest-12\"] // empty'";
          };
        };
    })

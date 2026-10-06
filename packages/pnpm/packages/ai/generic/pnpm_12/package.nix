# pnpm 12 — override nixpkgs' source-built pnpm_12 now that it exists;
# the operator prefers compiling over unpacking upstream's native binaries.
# Only our version, source/cargo hashes, locked Rust platform and update script
# move. Nixpkgs owns the phases, install layout, completions and metadata.
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

  # mkUpdateScript writes a version-only candidate; fake hashes let the fixers
  # evaluate it, then restore source before deriving its cargo vendor tree.
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
  # No postPatch of our own: nixpkgs' generic-rust.nix now deletes upstream's
  # "pnpm-managed cargo sources" block from .cargo/config.toml, which cargo
  # otherwise rejects as a duplicate of cargoSetupHook's git source. Our
  # former copy of that deletion ran second, found the block already gone
  # and failed patchPhase:
  # `git show a5475e4d:packages/pnpm/packages/ai/generic/pnpm_12/package.nix`.
    package.overrideAttrs (finalAttrs: prev: {
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

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
  # Upstream's global virtual store nests package files inside the fetcher's
  # metadata tree, where nixpkgs would try to normalize non-JSON fixtures.
  pnpmInstallFlags = [
    "--config.enable-global-virtual-store=false"
    # Nix supplies Node; skip upstream's platform-specific runtime downloads
    # while retaining their entries for frozen-lockfile validation.
    "--no-runtime"
  ];
  pnpmWorkspaces = ["@pnpm/esm-loader"];

  mkPnpm = {
    pnpm,
    sources,
    sourcesFile,
    update ? false,
  }: let
    srcHash = sources.srcHash or lib.fakeHash;
    sidecarMajor = lib.versions.major sources.version;
    rustPlatform = packageLib.mkRustPlatform {
      inherit pkgs sources sourcesFile;
      pname = "pnpm_12";
      targets = lib.optionals update (with packageLib.hashFixTargets; [cargoVendor pnpmDeps]);
    };
    package = pkgs.pnpm_12.override {
      inherit (sources) version;
      inherit srcHash;
      cargoHash = sources.cargoHash or lib.fakeHash;
      # Our release already carries the security updates in nixpkgs' 12.9.0
      # backport, which conflicts with our lock. Override the
      # builder input so source patching and cargo vendoring use the same lock.
      cargoPatches = [];
      inherit rustPlatform;
    };
  in
    assert lib.assertMsg (sidecarMajor == "12") ''
      pnpm_12: ${sourcesFile} records version "${sources.version}" (major ${sidecarMajor}), but this attribute is pnpm_12.
      Either point the sidecar back at a 12.x release, or add a pnpm_${sidecarMajor} attribute and move it there.
    '';
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
          (builtins.removeAttrs (prev.passthru or {}) ["updateScript"])
          // lib.optionalAttrs update (rustPlatform.passthru
            // {
              bootstrapPnpm = pnpm;
              updateScript = packageLib.mkUpdateScript {
                inherit pkgs sourcesFile;
                pname = "pnpm_12";
                platforms = {};
                extraExtract = "${rustPlatform.passthru.rustUpdateExtract}";
                # npm's per-major dist-tag picks the release; the source fixer then
                # fetches the matching GitHub tag and fails loudly if it is missing.
                versionCheck.cmd = "${pkgs.curl}/bin/curl -fsSL https://registry.npmjs.org/pnpm | ${pkgs.jq}/bin/jq -r '.[\"dist-tags\"][\"latest-12\"] // empty'";
              };
            });
      });

  # pnpm 12.16+ includes workspace catalogs and policies from other YAML files.
  # Fetch and configure both need pnpm >= 12.15.0 to read those includes;
  # nixpkgs' pnpm_12 is older. Build a frozen Rust stage with JavaScript pnpm 11,
  # then use that stage for both fetchPnpmDeps and pnpmConfigHook.
  bootstrapPnpm = mkPnpm {
    pnpm = pkgs.ai.generic.pnpm_11;
    sources = builtins.fromJSON (builtins.readFile ../../../../sources-12-bootstrap.json);
    sourcesFile = repoPath ../../../../sources-12-bootstrap.json;
  };
in
  mkPnpm {
    pnpm = bootstrapPnpm;
    sources = builtins.fromJSON (builtins.readFile ../../../../sources-12.json);
    sourcesFile = repoPath ../../../../sources-12.json;
    update = true;
  }

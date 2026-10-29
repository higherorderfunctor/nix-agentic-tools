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
    bootstrap ? false,
    pnpm,
    sidecar,
  }: let
    pname =
      if bootstrap
      then "pnpm_12-bootstrap"
      else "pnpm_12";
    sources = builtins.fromJSON (builtins.readFile sidecar);
    sourcesFile = repoPath sidecar;
    srcHash = sources.srcHash or lib.fakeHash;
    sidecarMajor = lib.versions.major sources.version;
    # pnpm 12 provisions its own Rust toolchain from `cargo`; Nix supplies Rust.
    prePnpmInstall = ''
      (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      if ! awk '
        /^cargo:$/ {
          if (seen++ || getline != 1 || $0 != "  enabled: true") exit 1
          cargo = 1
          next
        }
        cargo && /^[[:space:]]*(#|$)/ { next }
        cargo && /^[[:space:]]/ { exit 1 }
        { cargo = 0 }
        END { if (seen != 1) exit 1 }
      ' pnpm-workspace.yaml; then
        echo "${pname}: expected exactly cargo: followed by two-space enabled: true, with no other children in pnpm-workspace.yaml" >&2
        exit 1
      fi
      sed -i '/^cargo:$/,+1d' pnpm-workspace.yaml
      if grep -Eq '^cargo[[:space:]]*:' pnpm-workspace.yaml; then
        echo "${pname}: unexpected top-level cargo setting remains in pnpm-workspace.yaml" >&2
        exit 1
      fi
      )
    '';
    rustPlatform = packageLib.mkRustPlatform {
      inherit pkgs pname sources sourcesFile;
      targets = with packageLib.hashFixTargets; [cargoVendor pnpmDeps];
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
      ${pname}: ${sourcesFile} records version "${sources.version}" (major ${sidecarMajor}), but this stage requires pnpm 12.
      ${
        if bootstrap
        then "This is a frozen 12.x bootstrap stage; restore its 12.x pin and bump it deliberately when the bootstrap needs updating."
        else "Either point the sidecar back at a 12.x release, or add a pnpm_${sidecarMajor} attribute and move it there."
      }
    '';
      package.overrideAttrs (finalAttrs: prev: {
        inherit pnpmInstallFlags pnpmWorkspaces prePnpmInstall;
        pnpmDeps = pkgs.fetchPnpmDeps {
          inherit (finalAttrs) src version;
          inherit pnpm pnpmInstallFlags pnpmWorkspaces prePnpmInstall;
          fetcherVersion = 4;
          hash = sources.pnpmDepsHash or lib.fakeHash;
          pname = "pnpm-${lib.optionalString bootstrap "bootstrap-"}${finalAttrs.version}";
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
              echo "${pname}: binary reports $got, sidecar pins ${finalAttrs.version}" >&2
              false
            fi
            "$out/bin/pnpx" --help >/dev/null
            )
          '';
        passthru =
          (builtins.removeAttrs (prev.passthru or {}) ["updateScript"])
          // lib.optionalAttrs (!bootstrap) (rustPlatform.passthru
            // {
              updateScript = packageLib.mkUpdateScript {
                inherit pkgs pname sourcesFile;
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
  # On a cache miss, bootstrap pnpmDeps hash drift (e.g. a pnpm_11 or nixpkgs
  # fetcher change) can feed the main fixer; the next build fails on the main mismatch.
  bootstrapPnpm = mkPnpm {
    bootstrap = true;
    pnpm = pkgs.ai.generic.pnpm_11;
    sidecar = ../../../../sources-12-bootstrap.json;
  };
in
  mkPnpm {
    pnpm = bootstrapPnpm;
    sidecar = ../../../../sources-12.json;
  }

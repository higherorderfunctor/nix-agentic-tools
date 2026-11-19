# pnpm 12: `pkgs.ai.generic.pnpm_12`, compiled from source. Discovered by the
# native recipe tree; `packages/pnpm/registry.nix` registers its update target.
#
# Two pnpm builds meet here:
#
# - pnpm_12 itself overrides nixpkgs' source-built pnpm_12; the operator prefers
#   compiling the package we ship over unpacking upstream's native binary. Our
#   version, dependency pins, loader preparation, locked Rust platform and
#   update script move. Nixpkgs owns the phases, install layout, completions
#   and metadata.
# - `buildPnpm`, the pnpm that fetches and configures pnpm_12's JavaScript
#   dependencies, is upstream's prebuilt release binary of the version the
#   pinned tag names in `package.json` `packageManager`. Upstream builds each
#   release with that pnpm, so it always reads the tag's workspace and lockfile.
#   A from-source builder needs a new frozen stage whenever upstream's formats
#   move (12.15.0 cannot read the 13.0 lockfile committed from 12.20.0), and one
#   built by pnpm_11 changes pnpm_12 on every pnpm_11 bump.
#
# Data flow: `sources-12.json` pins the release and, under `builder`, the build
# pnpm's version and one tarball hash per system. `builderAssets` plus that
# version give the URL. `prePnpmInstall` refuses a `builder` version that is
# not the source's `packageManager`. On a release bump the update script
# restores the source hash, `fixBuilderPin` rewrites `builder` from the new
# source, and only then are the remaining pins repaired.
#
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
  inherit (pkgs) lib stdenv;
  inherit (stdenv.hostPlatform) system;
  pname = "pnpm_12";
  sources = builtins.fromJSON (builtins.readFile ../../../../sources-12.json);
  sourcesFile = repoPath ../../../../sources-12.json;
  srcHash = sources.srcHash or lib.fakeHash;
  sidecarMajor = lib.versions.major sources.version;
  # Upstream's global virtual store nests package files inside the fetcher's
  # metadata tree, where nixpkgs would try to normalize non-JSON fixtures.
  pnpmInstallFlags = [
    "--config.enable-global-virtual-store=false"
    # Nix supplies Node; skip upstream's platform-specific runtime downloads
    # while retaining their entries for frozen-lockfile validation.
    "--no-runtime"
  ];
  pnpmWorkspaces = ["@pnpm/esm-loader"];

  # Upstream's release asset name per Nix system: the one source for the
  # build pnpm's URL and platforms.
  builderAssets = {
    "aarch64-darwin" = "darwin-arm64";
    "x86_64-linux" = "linux-x64";
  };
  # Upstream's release tarball for one build pnpm version and asset name.
  builderUrl = version: asset: "https://github.com/pnpm/pnpm/releases/download/v${version}/pnpm-${asset}.tar.gz";
  # The URL comes from the table and the pinned version; only the hash comes
  # from the sidecar, so a hand-edited sidecar cannot re-point the fetch.
  builderSrc =
    if !(builderAssets ? ${system} && sources ? builder && sources.builder ? ${system})
    then throw "${pname}: no build pnpm pinned for ${system} under `builder` in ${sourcesFile}"
    else
      pkgs.fetchurl {
        url = builderUrl sources.builder.version builderAssets.${system};
        inherit (sources.builder.${system}) hash;
      };
  # Upstream's prebuilt pnpm for the pinned tag, used only at build time by
  # `fetchPnpmDeps` and `pnpmConfigHook` below.
  buildPnpm = stdenv.mkDerivation (finalAttrs: {
    pname = "pnpm";
    inherit (sources.builder) version;
    src = builderSrc;
    # The tarball holds `pnpm` and `dist/` at its root, with no top directory.
    sourceRoot = ".";
    # Stripping rewrites the Mach-O and its ad-hoc code signature; arm64
    # Darwin kills a binary whose signature no longer matches.
    dontStrip = true;
    # Linux only: the Darwin binary links system libraries and stays as
    # upstream signed it.
    nativeBuildInputs =
      [pkgs.makeWrapper]
      ++ lib.optionals stdenv.hostPlatform.isLinux [pkgs.autoPatchelfHook];
    # `libgcc_s.so.1` is the one needed library glibc does not provide.
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
    installPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preInstall
      mkdir -p "$out/libexec/pnpm"
      cp -r pnpm dist "$out/libexec/pnpm/"
      # A wrapper, not a symlink, so the executable starts from the path that
      # has `dist/` beside it whether or not the platform resolves links.
      makeWrapper "$out/libexec/pnpm/pnpm" "$out/bin/pnpm"
      runHook postInstall
    '';
    # Runs after autoPatchelf, so on Linux it also proves the interpreter and
    # `libgcc_s` were found. A mismatch means the URL served another release.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      got=$("$out/bin/pnpm" --version)
      if [ "$got" != "${finalAttrs.version}" ]; then
        echo "${pname}: build pnpm reports $got, ${sourcesFile} pins ${finalAttrs.version}" >&2
        exit 1
      fi
      runHook postInstallCheck
    '';
    # `fetchPnpmDeps` reads `pnpm.nodejs-slim` for its state-database helper.
    passthru = {inherit (pkgs.pnpm_12) nodejs-slim;};
    meta = {
      description = "Upstream's prebuilt pnpm, used to build pnpm_12";
      license = lib.licenses.mit;
      mainProgram = "pnpm";
      platforms = builtins.attrNames builderAssets;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  });

  # Runs before both the dependency fetch and the offline configure.
  prePnpmInstall = ''
    (
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    # A release bump that leaves `builder` behind would otherwise build with
    # a pnpm upstream did not use for this tag.
    wanted=$(${lib.getExe pkgs.jq} -r .packageManager package.json)
    if [ "$wanted" != "pnpm@${buildPnpm.version}" ]; then
      echo "${pname}: package.json names packageManager $wanted, ${sourcesFile} pins builder pnpm@${buildPnpm.version}" >&2
      exit 1
    fi
    # pnpm 12 provisions its own Rust toolchain from `cargo`; Nix supplies Rust.
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

  # Rewrites the sidecar's `builder` from the pinned source: the version its
  # `package.json` `packageManager` names, and that release's tarball hash for
  # every system in `builderAssets`. Run from the repository root, by the
  # update script and by hand. It builds `.src`, so the sidecar's source hash
  # must already be right. PATH-less like every update script.
  fixBuilderPin = pkgs.writeShellScript "fix-builder-pin-${pname}" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    src=$(${pkgs.nix}/bin/nix build --no-link --print-out-paths ".#${packageLib.ciAttr {
      inherit pkgs;
      attr = pname;
    }}.src")
    packageManager=$(${pkgs.jq}/bin/jq -r .packageManager "$src/package.json")
    # An exact release only: a range, a hash suffix or another tool has no
    # release tarball to pin.
    if [[ ! $packageManager =~ ^pnpm@([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
      echo "${pname}: package.json names packageManager $packageManager, expected pnpm@<major>.<minor>.<patch>" >&2
      exit 1
    fi
    version=''${BASH_REMATCH[1]}

    builder=$(${pkgs.jq}/bin/jq -n --arg version "$version" '{version: $version}')
    ${lib.concatStrings (lib.mapAttrsToList (assetSystem: asset: ''
        hash=$(${pkgs.nix}/bin/nix store prefetch-file --json --hash-type sha256 "${builderUrl "$version" asset}" \
          | ${pkgs.jq}/bin/jq -r .hash)
        builder=$(${pkgs.jq}/bin/jq --arg system "${assetSystem}" --arg hash "$hash" \
          '.[$system] = {hash: $hash}' <<<"$builder")
      '')
      builderAssets)}
    ${pkgs.jq}/bin/jq --argjson builder "$builder" '.builder = $builder' "${sourcesFile}" \
      > "${sourcesFile}.new"
    ${pkgs.coreutils}/bin/mv "${sourcesFile}.new" "${sourcesFile}"
    echo "${pname}: builder = pnpm@$version"
  '';
  # `fixBuilderPin` builds `.src`, and the pnpm dependency repair inside
  # `rustUpdateExtract` runs the build pnpm, so the source hash is restored
  # first and the builder pinned second. `rustUpdateExtract` repeats the source
  # repair and finds it done.
  fixSrcHash = packageLib.mkHashFix {
    inherit pkgs pname sourcesFile;
    attr = pname;
    name = "src";
    targets = [packageLib.hashFixTargets.src];
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
    ${pname}: ${sourcesFile} records version "${sources.version}" (major ${sidecarMajor}), but this attribute is pnpm 12.
    Either point the sidecar back at a 12.x release, or add a pnpm_${sidecarMajor} attribute and move it there.
  '';
    package.overrideAttrs (finalAttrs: prev: {
      inherit pnpmInstallFlags pnpmWorkspaces prePnpmInstall;
      pnpmDeps = pkgs.fetchPnpmDeps {
        inherit (finalAttrs) src version;
        inherit pnpmInstallFlags pnpmWorkspaces prePnpmInstall;
        pnpm = buildPnpm;
        fetcherVersion = 4;
        hash = sources.pnpmDepsHash or lib.fakeHash;
        pname = "pnpm-${finalAttrs.version}";
        # pnpm 12.19+ keeps a macOS-only clone cache, v11/dir-clone-cache,
        # derived from the content store; drop it so both systems share one
        # hash. `storePath` is fetchPnpmDeps' variable, so a rename fails
        # under nounset.
        preFixup = ''
          (
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          rm -rf "$storePath/v11/dir-clone-cache"
          )
        '';
      };
      # cargoSetupHook's cargoUseSystemLibs makes the vendored zstd-sys (in
      # the locks since 12.15) link system zstd; nixpkgs' generic-rust
      # supplies pkg-config, aws-lc and sqlite but no zstd.
      buildInputs =
        (prev.buildInputs or [])
        ++ [pkgs.zstd];
      nativeBuildInputs =
        (prev.nativeBuildInputs or [])
        ++ [
          pkgs.nodejs
          buildPnpm
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
        // rustPlatform.passthru
        // {
          inherit fixBuilderPin;
          updateScript = packageLib.mkUpdateScript {
            inherit pkgs pname sourcesFile;
            platforms = {};
            extraExtract = ''
              ${fixSrcHash}
              ${fixBuilderPin}
              ${rustPlatform.passthru.rustUpdateExtract}
            '';
            # npm's per-major dist-tag picks the release; the source fixer then
            # fetches the matching GitHub tag and fails loudly if it is missing.
            versionCheck.cmd = "${pkgs.curl}/bin/curl -fsSL https://registry.npmjs.org/pnpm | ${pkgs.jq}/bin/jq -r '.[\"dist-tags\"][\"latest-12\"] // empty'";
          };
        };
    })

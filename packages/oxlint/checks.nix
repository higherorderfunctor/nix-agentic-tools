{
  packageLib,
  pkgs,
  ...
}: let
  releases = {
    "3.10.1" = "sha256-7BFATrr7E3/mh9Yu8MNB0OqtKD8XXv8BZz4855i3pdk=";
    "3.10.4" = "sha256-TGIOOTGV8plTpjATQ3l747UAH+nBR3nIrsJo43FBHfY=";
  };
  package = pkgs.ai.devTools.oxlint;
  patch = ./patches/oxlint-napi-rs-cli.patch;
  verify = ./src/verify-napi-patch.mjs;
in {
  # Exercise the real offline configure hook and production preBuild probe,
  # without compiling Rust. This catches a probe scheduled before pnpm installs.
  checks.oxlint-napi-materialization = package.overrideAttrs (_: {
    name = "oxlint-napi-materialization";
    nativeBuildInputs = [pkgs.nodejs_24 package.pnpmDeps.pnpm pkgs.pnpmConfigHook];
    buildInputs = [];
    buildPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preBuild
    '';
    installPhase = ''
      ${(packageLib.patching {inherit pkgs;}).validateDependencies {
        patchedDependencies = ''<(${pkgs.yq-go}/bin/yq -o=json '.patchedDependencies' pnpm-workspace.yaml)'';
      }}
      mkdir "$out"
      cp -r node_modules "$out/"
    '';
    doInstallCheck = false;
    dontFixup = true;
  });
  checks.oxlint-napi-patch =
    pkgs.runCommand "oxlint-napi-patch" {
      nativeBuildInputs = [pkgs.nodejs pkgs.python3];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 ${./checks/patch-meta.py} ${./src/oxlint-pnpm-patch-meta.awk}
      ${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (version: hash: let
          source = pkgs.fetchurl {
            url = "https://registry.npmjs.org/@napi-rs/cli/-/cli-${version}.tgz";
            inherit hash;
          };
        in ''
          # Use two peers so checking only the first cannot pass this fixture.
          for peer in first second; do
            target="peers-${version}/@napi-rs+cli@${version}_$peer/node_modules/@napi-rs/cli"
            mkdir -p "$target"
            tar -xzf ${source} -C "$target" --strip-components=1
          done
          if node ${verify} "peers-${version}" >pristine.log 2>&1; then
            echo "unpatched ${version} unexpectedly passed the behavioral probe" >&2
            exit 1
          fi
          grep -F 'spawn EPERM' pristine.log
          ${(packageLib.patching {inherit pkgs;}).command {
            backend = "git";
            directory = "peers-${version}/@napi-rs+cli@${version}_first/node_modules/@napi-rs/cli";
            patchFiles = [patch];
          }}
          if node ${verify} "peers-${version}" >partial.log 2>&1; then
            echo "unpatched second peer unexpectedly passed" >&2
            exit 1
          fi
          grep -F 'spawn EPERM' partial.log
          ${(packageLib.patching {inherit pkgs;}).command {
            backend = "git";
            directory = "peers-${version}/@napi-rs+cli@${version}_second/node_modules/@napi-rs/cli";
            patchFiles = [patch];
          }}
          node ${verify} "peers-${version}"
        '')
        releases)}
      mkdir empty
      if node ${verify} empty >empty.log 2>&1; then
        echo "empty peer set unexpectedly passed" >&2
        exit 1
      fi
      grep -F 'no installed @napi-rs/cli peer variants' empty.log
      ${(packageLib.patching {inherit pkgs;}).validate "."}
      mkdir "$out"
      cp -r peers-* "$out/"
    '';
}

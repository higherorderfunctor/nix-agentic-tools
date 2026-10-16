{
  harness,
  lib,
  pkgs,
  ...
}: let
  kimchi = pkgs.ai.kimchi;
  # Exercise the actual files/settings emitted by each backend, with cheap
  # payloads that share a package name but have distinct store targets.
  delivery =
    map (backend: let
      payload = pkgs.linkFarm "kimchi-identity-${backend.name}" [
        {
          name = "index.js";
          path = pkgs.writeText "identity-${backend.name}.js" "export default () => {};";
        }
        {
          name = "package.json";
          path = pkgs.writeText "identity-package.json" (builtins.toJSON {
            name = "@kimchi-dev/kimchi-workflows";
            pi.extensions = ["./index.js"];
          });
        }
      ];
      evaluated = backend.evaluate {
        ai.kimchi = {
          enable = true;
          extensions.workflows = payload;
          native.settings.region = "us";
        };
      };
      files = harness.deliveredFiles evaluated.config;
      harnessDir = "${evaluated.config.ai.kimchi.configDir}/harness";
      settingsPath = "${harnessDir}/settings.json";
      settings =
        if backend.name == "user"
        then (harness.ownedDocument "kimchi" settingsPath evaluated).value
        else evaluated.config.ai.kimchi.files.${settingsPath}.content.value;
      source = lib.head settings.packages;
    in {
      inherit harnessDir source;
      extension = files."${harnessDir}/${source}".source;
    }) [
      {
        name = "user";
        evaluate = harness.evalHm;
      }
      {
        name = "project";
        evaluate = harness.evalDevenv;
      }
    ];
  layout = pkgs.writeText "kimchi-identity-delivery.json" (builtins.toJSON delivery);
in {
  # Uses the production source, dependency store and configure hook. No Bun or
  # Go compilation: frozen offline pnpm installation must apply the extended
  # upstream PI patch, even when the dependency store came from the cache.
  checks.kimchi-package-identity = pkgs.stdenvNoCC.mkDerivation {
    name = "kimchi-package-identity";
    inherit (kimchi) pnpmDeps src;
    nativeBuildInputs = [pkgs.gnupatch pkgs.nodejs kimchi.pnpmDeps.pnpm pkgs.pnpmConfigHook];
    dontFixup = true;
    buildPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preBuild
      manager=node_modules/@earendil-works/pi-coding-agent/dist/core/package-manager.js
      # Read Kimchi's piConfig from the real source manifest, just as its
      # bundled runtime does, rather than PI's standalone .pi defaults.
      export PI_PACKAGE_DIR="$PWD"
      cp ${kimchi.extractionSources.pi}/dist/core/package-manager.js "''${manager%.js}.pristine.js"
      if node ${./package-identity.mjs} "''${manager%.js}.pristine.js" ${layout} > pristine.log 2>&1; then
        echo 'unpatched PI unexpectedly deduplicates named local packages; reassess the patch' >&2
        exit 1
      fi
      grep -q 'project package must win' pristine.log
      # Apply the NAT diff on its own with zero fuzz as well as testing pnpm's
      # materialized upstream+NAT patch below. Both use the same real PI helpers.
      mkdir -p identity-source/dist/core
      cp ${kimchi.extractionSources.pi}/dist/core/package-manager.js identity-source/dist/core/
      chmod u+w identity-source/dist/core/package-manager.js
      patch -d identity-source -p1 --fuzz=0 < ${../packages/ai/kimchi/package-identity.patch}
      cp identity-source/dist/core/package-manager.js "''${manager%.js}.identity-only.js"
      node ${./package-identity.mjs} "''${manager%.js}.identity-only.js" ${layout}
      node ${./package-identity.mjs} "$manager" ${layout}
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      echo PASS > "$out"
      runHook postInstall
    '';
  };
}

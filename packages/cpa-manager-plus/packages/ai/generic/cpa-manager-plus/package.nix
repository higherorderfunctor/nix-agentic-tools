# cspell:ignore buildinfo httpapi seakee
{
  extractedLib,
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) fetchzip lib;
  pname = "cpa-manager-plus";
  sources = builtins.fromJSON (builtins.readFile ../../../../sources.json);
  sourcesFile = repoPath ../../../../sources.json;
  inherit (sources) version;
  # The patched tree is `src` itself, so the web app, the server, the
  # extractor and the settings check (which copy `package.src`) all read it.
  src = (packageLib.patching {inherit pkgs;}).source {
    src = fetchzip {
      name = "${pname}-${version}-source";
      url = "https://github.com/seakee/CPA-Manager-Plus/archive/v${version}.tar.gz";
      hash = sources.srcHash or lib.fakeHash;
      postFetch = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${lib.getExe pkgs.npm-lockfile-fix} "$out/package-lock.json"
      '';
    };
    patchFiles = [
      ../../../../patches/default-theme.patch
      ../../../../patches/passthrough-view.patch
    ];
  };
  modRoot = "apps/manager-server";
  goModPath = "${modRoot}/go.mod";
  npmDepsFix = packageLib.mkNpmDepsFix {
    attr = "${pname}.frontend";
    inherit pkgs pname sourcesFile;
  };
  extraction = extractedLib {inherit pkgs;};
  goUpdate = packageLib.mkGoUpdateExtract {
    attr = pname;
    inherit goModPath pkgs pname sourcesFile;
  };
  frontend = pkgs.buildNpmPackage {
    pname = "${pname}-web";
    inherit src version;
    npmDepsFetcherVersion = 2;
    npmDepsHash = sources.npmDepsHash or lib.fakeHash;
    env.VERSION = version;
    # The patches' own tests and the upstream test they extend; upstream's full
    # suite has a date-dependent failure (DemoPage.test.tsx) on 1.14.7.
    doCheck = true;
    checkPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preCheck
      npm --workspace apps/web exec -- vitest run \
        src/components/providers/PassthroughTable/PassthroughTable.test.tsx \
        src/features/aiProviders/AiProvidersPage.test.tsx \
        src/features/monitoring/services/monitoringMetaService.test.ts \
        src/services/api/passthrough.test.ts \
        src/stores/useThemeStore.test.ts
      runHook postCheck
    '';
    installPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preInstall
      install -Dm644 -t "$out" apps/web/dist/{apple-touch-icon.png,favicon.ico,index.html}
      mv "$out/index.html" "$out/management.html"
      runHook postInstall
    '';
  };
  goFloor = sources.goFloor or packageLib.goFloorUnknown;
  inherit
    (packageLib.mkGoToolchain {
      floor = goFloor;
      inherit pkgs pname;
    })
    buildGoModule
    ;
  package = buildGoModule {
    inherit modRoot pname src version;
    vendorHash = sources.vendorHash or lib.fakeHash;
    subPackages = ["cmd/cpa-manager-plus"];
    env.CGO_ENABLED = "0";
    ldflags = [
      "-X github.com/seakee/cpa-manager-plus/apps/manager-server/internal/buildinfo.Version=${version}"
    ];
    # Scoped: buildGoModule's own buildPhase reads the unset
    # $excludedPackages, so a leaked `set -u` fails the build.
    preBuild = ''
      (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      cp ${frontend}/* internal/httpapi/web/
      )
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preInstallCheck
      test "$("$out/bin/cpa-manager-plus" --version)" = "${version}"
      runHook postInstallCheck
    '';
    passthru = {
      inherit frontend goFloor goModPath;
      inherit (goUpdate) fixGoFloor fixVendorHash;
      extracted = extraction.goTestExtract {
        inherit package;
        packagePath = "internal/config";
        testFile = ../../../../extract/config_test.go;
      };
      goUpdateExtract = goUpdate.extract;
      fixNpmDepsHash = npmDepsFix;
      updateScript = packageLib.mkUpdateScript {
        extraExtract = ''
          ${npmDepsFix}
          ${goUpdate.extract}
        '';
        inherit pkgs pname sourcesFile;
        platforms = {};
        versionCheck.cmd = packageLib.ghLatestVersionCmd {
          inherit pkgs;
          repo = "seakee/CPA-Manager-Plus";
        };
      };
    };
    meta = {
      description = "CPA Manager Plus dashboard and management server";
      homepage = "https://github.com/seakee/CPA-Manager-Plus";
      license = lib.licenses.mit;
      mainProgram = pname;
    };
  };
in
  package

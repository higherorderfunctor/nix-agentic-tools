{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs) fetchzip lib;
  vu = packageLib;
  pname = "anthropic-cli";
  sources = builtins.fromJSON (builtins.readFile ../../../sources.json);
  sourcesFile = repoPath ../../../sources.json;
  goUpdate = vu.mkGoUpdateExtract {
    attr = pname;
    inherit pkgs;
    inherit pname sourcesFile;
  };
  goFloor = sources.goFloor or vu.goFloorUnknown;
  inherit
    (vu.mkGoToolchain {
      floor = goFloor;
      inherit pkgs;
      inherit pname;
    })
    buildGoModule
    ;
in
  buildGoModule {
    inherit pname;
    inherit (sources) version;
    src = fetchzip {inherit (sources.src) url hash;};
    vendorHash = sources.vendorHash or lib.fakeHash;
    subPackages = ["cmd/ant"];
    doInstallCheck = true;
    installCheckPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preInstallCheck
      test "$($out/bin/ant --version)" = "ant version ${sources.version}"
      runHook postInstallCheck
    '';
    passthru = {
      inherit (goUpdate) fixGoFloor fixVendorHash;
      inherit goFloor;
      goUpdateExtract = goUpdate.extract;
      updateScript = vu.ghArchiveUpdateScript {
        extraExtract = "${goUpdate.extract}";
        inherit pkgs;
        inherit pname sourcesFile;
        repo = "anthropics/anthropic-cli";
      };
    };
    meta = {
      description = "Official CLI for the Claude Platform";
      homepage = "https://github.com/anthropics/anthropic-cli";
      license = lib.licenses.asl20;
      mainProgram = "ant";
    };
  }

{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs) fetchzip lib;
  vu = packageLib;
  pname = "cli-proxy-api";
  sources = builtins.fromJSON (builtins.readFile ../../../../sources.json);
  sourcesFile = repoPath ../../../../sources.json;
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
    subPackages = ["cmd/server"];
    ldflags = ["-X main.Version=${sources.version}"];
    postInstall = ''
      (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mv "$out/bin/server" "$out/bin/${pname}"
      )
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preInstallCheck
      "$out/bin/${pname}" -h >help.txt 2>&1
      grep -F "CLIProxyAPI Version: ${sources.version}" help.txt
      grep -F -- "-config string" help.txt
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
        repo = "router-for-me/CLIProxyAPI";
      };
    };
    meta = {
      description = "OpenAI-compatible proxy for AI CLI subscriptions and APIs";
      homepage = "https://github.com/router-for-me/CLIProxyAPI";
      license = lib.licenses.mit;
      mainProgram = pname;
    };
  }

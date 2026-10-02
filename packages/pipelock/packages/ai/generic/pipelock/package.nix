{
  inputs,
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    overlays = [inputs.go-overlay.overlays.default];
  };
  inherit (ourPkgs) fetchzip lib;
  vu = packageLib;
  pname = "pipelock";
  sources = builtins.fromJSON (builtins.readFile ../../../../sources.json);
  sourcesFile = repoPath ../../../../sources.json;
  goUpdate = vu.mkGoUpdateExtract {
    attr = pname;
    pkgs = ourPkgs;
    inherit pname sourcesFile;
  };
  goFloor = sources.goFloor or vu.goFloorUnknown;
  buildGoModule = vu.mkGoBuilder {
    floor = goFloor;
    pkgs = ourPkgs;
    inherit pname;
  };
in
  buildGoModule {
    inherit pname;
    inherit (sources) version;
    src = fetchzip {inherit (sources.src) url hash;};
    vendorHash = sources.vendorHash or lib.fakeHash;
    # cmd/ also holds the enterprise license service, playgrounds and verifiers.
    subPackages = ["cmd/pipelock"];
    # No `tags`: the `enterprise` tag compiles in Elastic-License code, so the
    # default build is the Apache-2.0 Community edition.
    ldflags = [
      # The CLI and proxy expose separate version fields.
      "-X github.com/luckyPipewrench/pipelock/internal/cliutil.Version=${sources.version}"
      "-X github.com/luckyPipewrench/pipelock/internal/proxy.Version=${sources.version}"
    ];
    doInstallCheck = true;
    installCheckPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preInstallCheck
      $out/bin/pipelock --version
      runHook postInstallCheck
    '';
    passthru = {
      inherit (goUpdate) fixGoFloor fixVendorHash;
      inherit goFloor;
      goUpdateExtract = goUpdate.extract;
      updateScript = vu.ghArchiveUpdateScript {
        extraExtract = "${goUpdate.extract}";
        pkgs = ourPkgs;
        inherit pname sourcesFile;
        repo = "luckyPipewrench/pipelock";
      };
    };
    meta = {
      description = "Agent egress firewall: forward proxy with hostname, SSRF and DLP checks";
      homepage = "https://github.com/luckyPipewrench/pipelock";
      license = lib.licenses.asl20;
      mainProgram = pname;
    };
  }

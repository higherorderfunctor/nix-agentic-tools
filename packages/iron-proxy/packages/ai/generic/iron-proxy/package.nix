{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs) fetchzip lib;
  vu = packageLib;
  pname = "iron-proxy";
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
    # The vendor tree holds github.com/1Password/connect-sdk-go and
    # github.com/1password/onepassword-sdk-go. On a case-insensitive macOS
    # store, Nix's case hack renames one of them and -mod=vendor fails;
    # the module cache escapes capitals (1!password), so no collision.
    proxyVendor = true;
    # Upstream's release builds only this command.
    subPackages = ["cmd/iron-proxy"];
    # Upstream releases are static (CGO_ENABLED=0).
    env.CGO_ENABLED = "0";
    ldflags = [
      "-X github.com/ironsh/iron-proxy/internal/version.Version=${sources.version}"
    ];
    doInstallCheck = true;
    installCheckPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preInstallCheck
      # `version` prints the bare stamped version, so it must equal the pin.
      test "$($out/bin/iron-proxy version)" = "${sources.version}"
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
        repo = "paradigmxyz/iron-proxy";
      };
    };
    meta = {
      description = "Egress proxy for sandboxed agents: allowlisted hosts and secret injection";
      homepage = "https://github.com/paradigmxyz/iron-proxy";
      license = lib.licenses.asl20;
      mainProgram = pname;
    };
  }

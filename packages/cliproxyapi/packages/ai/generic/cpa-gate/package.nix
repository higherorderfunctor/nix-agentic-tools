# cpa-gate: Caddy with the cpa_gate handler from src/cpa-gate, which stands in
# front of CLIProxyAPI. NOT a security boundary while a harness shares its uid;
# see docs/cliproxyapi-front-gate.md.
#
# The package and update tradeoffs are in docs/cliproxyapi-front-gate.md.
{
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) lib;
  vu = packageLib;
  pname = "cpa-gate";
  pins = builtins.fromJSON (builtins.readFile ../../../../gate.json);
  goUpdate = vu.mkGoUpdateExtract {
    attr = pname;
    inherit pkgs pname;
    sourcesFile = repoPath ../../../../gate.json;
  };
  goFloor = pins.goFloor or vu.goFloorUnknown;
  toolchain = vu.mkGoToolchain {
    floor = goFloor;
    inherit pkgs pname;
  };
  # Runs from the repository root, both for a direct package update and the
  # nixpkgs input's sidecar regeneration.
  updateScript = pkgs.writeShellScript "cpa-gate-update" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    (
      cd ${repoPath ../../../../src/cpa-gate}
      # A Caddy that needs a newer Go fails here instead of downloading one.
      export GOTOOLCHAIN=local
      ${toolchain.go}/bin/go get github.com/caddyserver/caddy/v2@v${pkgs.caddy.version}
      ${toolchain.go}/bin/go mod tidy
    )
    ${goUpdate.extract}
  '';
in
  toolchain.buildGoModule {
    inherit pname;
    # The same Caddy version and build tags as nixpkgs' caddy.
    inherit (pkgs.caddy) tags version;
    src = ../../../../src/cpa-gate;
    vendorHash = pins.vendorHash or lib.fakeHash;
    # `gate` as well, so the check phase runs its tests.
    subPackages = ["cmd/cpa-gate" "gate"];

    passthru = {
      inherit (goUpdate) fixGoFloor fixVendorHash;
      inherit goFloor updateScript;
      goUpdateExtract = goUpdate.extract;
      regenerateExtracted = updateScript.overrideAttrs (prev: {
        passthru =
          (prev.passthru or {})
          // {
            sidecars = map repoPath [../../../../gate.json ../../../../src/cpa-gate/go.mod ../../../../src/cpa-gate/go.sum];
          };
      });
      updateFlakeInput = "nixpkgs";
    };

    meta = {
      description = "Caddy with the cpa_gate handler for CLIProxyAPI";
      mainProgram = pname;
    };
  }

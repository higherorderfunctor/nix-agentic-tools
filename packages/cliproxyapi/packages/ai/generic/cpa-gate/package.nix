# cpa-gate: Caddy with the cpa_gate handler from src/cpa-gate, which stands in
# front of CLIProxyAPI. NOT a security boundary while a harness shares its uid;
# see docs/cliproxyapi-front-gate.md.
#
# It is its own Caddy main (cmd/cpa-gate, the file xcaddy generates), not
# `caddy.withPlugins`: that takes a plugin only as `module@version`, fetched
# into one fixed-output tree, so an in-repo module would need a tagged,
# fetchable release before every hash. Here `buildGoModule` vendors only the
# dependencies, so `vendorHash` moves with go.mod, not with gate edits.
#
# Caddy is the version nixpkgs ships: src/cpa-gate/go.mod requires it, and
# `cliproxyapi-gate-pins` fails when nixpkgs moves. `passthru.updateScript`
# moves go.mod to the nixpkgs version and re-derives gate.json.
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
      inherit goFloor;
      goUpdateExtract = goUpdate.extract;
      # Runs from the repository root, as every update script does.
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
    };

    meta = {
      description = "Caddy with the cpa_gate handler for CLIProxyAPI";
      mainProgram = pname;
    };
  }

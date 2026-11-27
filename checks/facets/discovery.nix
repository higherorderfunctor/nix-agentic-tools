{
  lib,
  pkgs,
  ...
}: let
  discover = import ../../lib/testing/discover.nix {inherit lib;};
  world = (import ../../lib/facets.nix {inherit lib;}).realizeChecks {
    context = {inherit lib pkgs;};
    index.owners = [];
    rootModules = discover ./discovery-fixtures;
  };
in {
  checks.facet-check-discovery = assert lib.assertMsg (builtins.attrNames world.checks == ["discovered"]) "facet discovery must register only the immediate active/default.nix module";
    pkgs.runCommandLocal "facet-check-discovery" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      test -e ${world.checks.discovered}
      touch "$out"
    '';
}

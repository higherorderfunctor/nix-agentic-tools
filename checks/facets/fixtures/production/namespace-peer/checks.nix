{
  lib,
  packages,
  pkgs,
  ...
}: let
  inherit (packages.ai) devTools;
  inherit (packages.ai.mcpServers.modelContextProtocol) fixture_mcp;
in {
  imports = [./checks/native-module.nix];
  checks = {
    native-package-namespaces = assert lib.isDerivation devTools."literal.name" && devTools."literal.name".name == "facet-dotted";
    assert lib.isDerivation devTools.literal.name && devTools.literal.name.name == "facet-nested";
    assert devTools."literal.name".drvPath != devTools.literal.name.drvPath;
    assert lib.isDerivation devTools.peer-tool && devTools.peer-tool.name == "facet-peer";
    assert lib.isDerivation fixture_mcp && fixture_mcp.name == "facet-mcp";
      pkgs.runCommandLocal "facet-native-package-namespaces" {
        nativeBuildInputs = [devTools.alpha-tool devTools.peer-tool];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        test -e ${devTools.alpha-tool}/passed
        test -e ${devTools.peer-tool}/passed
        mkdir -p "$out"
        touch "$out/passed"
      '';
  };
}

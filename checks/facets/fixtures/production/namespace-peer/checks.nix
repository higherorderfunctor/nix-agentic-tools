{
  packages,
  pkgs,
  ...
}: let
  inherit (packages.ai) devTools;
  inherit (packages.ai.mcpServers.modelContextProtocol) fixture_mcp;
in {
  imports = [./checks/native-module.nix];
  checks.native-package-namespaces =
    pkgs.runCommandLocal "facet-native-package-namespaces" {
      # Building alpha forces its sibling and ancestor dependencies in the native scopes.
      nativeBuildInputs = [devTools.alpha-tool];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      expect_marker() {
        local expected="$1" artifact="$2" regression="$3"
        diff -u --label "expected marker: $expected" --label "$regression" \
          <(printf '%s\n' "$expected") "$artifact"
      }

      # Both paths must resolve to their own recipes, not aliases of one another.
      expect_marker literal-dot "${devTools."literal.name"}" 'literal dotted name split into a nested path'
      expect_marker nested-path "${devTools.literal.name}" 'nested path flattened into a dotted name'
      expect_marker mcp-namespace "${fixture_mcp}" 'nested namespace case or package underscore changed'
      mkdir -p "$out"
      touch "$out/passed"
    '';
}

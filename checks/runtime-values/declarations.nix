{
  lib,
  harness,
  ...
}: let
  rv = import ../../lib/runtime-values {inherit lib;};
  inherit (harness) mkTest;
  backends = [(harness.evalHm {}) (harness.evalDevenv {})];
  roots = [
    ["ai" "codex" "environmentVariables"]
    ["ai" "copilot" "environmentVariables"]
    ["ai" "environmentVariables"]
    ["ai" "kimchi" "apiKey"]
    ["ai" "kimchi" "environmentVariables"]
    ["ai" "kimchi" "gitTokens"]
    ["ai" "kiro" "environmentVariables"]
    ["ai" "mcpServers"]
    ["glab"]
  ];
  audit = options: rv.checkOptions {inherit options roots;};
  setOption = options: path: option:
    if path == []
    then option
    else options // {${lib.head path} = setOption options.${lib.head path} (lib.tail path) option;};
  withType = options: path: type:
    setOption options path ((lib.getAttrFromPath path options) // {inherit type;});
  mcp = import ../../lib/mcp.nix {inherit lib;};
  servers = ["context7-mcp" "github-mcp" "gitlab-mcp" "kagi-mcp"];
  mcpViolations = lib.concatMap (name: let
    definition = mcp.loadServer name;
    evaluated = lib.evalModules {modules = [{options = definition.settingsOptions;}];};
    keys = builtins.attrNames definition.meta.credentialVars;
  in
    rv.checkOptions {
      inherit (evaluated) options;
      roots = map (key: [key]) keys;
    })
  servers;
in {
  checks = {
    runtime-values-declarations = mkTest "runtime-values-declarations" (
      lib.all (backend: let
        inherit (backend) options;
      in
        audit options
        == []
        && audit (withType options ["ai" "environmentVariables"] (lib.types.attrsOf lib.types.str)) == ["ai.environmentVariables"]
        && audit (withType options ["ai" "kimchi" "gitTokens"] (lib.types.attrsOf lib.types.str)) == ["ai.kimchi.gitTokens"])
      backends
      && mcpViolations == []
    );
  };
}

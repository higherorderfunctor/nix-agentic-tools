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
  literalAdmitting = options:
    options
    // {
      ai =
        options.ai
        // {
          environmentVariables = options.ai.environmentVariables // {type = lib.types.attrsOf lib.types.str;};
          kimchi =
            options.ai.kimchi
            // {
              gitTokens = options.ai.kimchi.gitTokens // {type = lib.types.attrsOf lib.types.str;};
            };
        };
    };
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
      lib.all (backend:
        audit backend.options == [] && audit (literalAdmitting backend.options) != [])
      backends
      && mcpViolations == []
    );
  };
}

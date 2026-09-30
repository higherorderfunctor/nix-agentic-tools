{
  lib,
  harness,
  ...
}: let
  rv = import ../../lib/runtime-values {inherit lib;};
  inherit (harness) mkTest;
  backends = [(harness.evalHm {}) (harness.evalDevenv {})];
  roots = [
    ["ai" "claude" "programs"]
    ["ai" "codex" "environmentVariables"]
    ["ai" "codex" "programs"]
    ["ai" "copilot" "environmentVariables"]
    ["ai" "copilot" "programs"]
    ["ai" "environmentVariables"]
    ["ai" "kimchi" "apiKey"]
    ["ai" "kimchi" "environmentVariables"]
    ["ai" "kimchi" "gitTokens"]
    ["ai" "kimchi" "programs"]
    ["ai" "kiro" "environmentVariables"]
    ["ai" "kiro" "programs"]
    ["ai" "mcpServers"]
    ["ai" "programs"]
    ["glab"]
  ];
  audit = options: rv.checkOptions {inherit options roots;};
  setOption = options: path: option:
    if path == []
    then option
    else options // {${lib.head path} = setOption options.${lib.head path} (lib.tail path) option;};
  withGitCredentialType = options: type: {
    ai.programs.git.credentials =
      (options.ai.programs.git.type.getSubOptions options.ai.programs.git.loc).credentials
      // {inherit type;};
  };
  withType = options: path: type:
    setOption options path ((lib.getAttrFromPath path options) // {inherit type;});
  expect = label: expected: actual:
    if actual == expected
    then true
    else builtins.trace "${label}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}" false;
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
        violations = audit options;
      in
        (
          if violations == []
          then true
          else builtins.trace "runtime-values declaration violations: ${builtins.toJSON violations}" false
        )
        && expect "environment map" ["ai.environmentVariables"] (audit (withType options ["ai" "environmentVariables"] (lib.types.attrsOf lib.types.str)))
        && expect "git token" ["ai.programs.git.credentials"] (audit (withGitCredentialType options (lib.types.nullOr lib.types.str)))
        && expect "kimchi token map" ["ai.kimchi.gitTokens"] (audit (withType options ["ai" "kimchi" "gitTokens"] (lib.types.attrsOf lib.types.str))))
      backends
      && mcpViolations == []
    );
  };
}

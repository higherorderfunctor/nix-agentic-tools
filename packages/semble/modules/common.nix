{
  configureCodexCache,
  installPackage,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.semble;
  records = import ../lib/integrations.nix;
  runtimes = ["claude" "codex" "kiro"];

  featureEnabled = feature:
    if feature.enable != null
    then feature.enable
    else cfg.enable;
  featureRuntimes = feature:
    if feature.runtimes != null
    then feature.runtimes
    else cfg.runtimes;
  selected = runtime: feature:
    featureEnabled feature && lib.elem runtime (featureRuntimes feature);
  featureActive = feature:
    featureEnabled feature && featureRuntimes feature != [];
  codexSelected = lib.any (feature: selected "codex" feature) [
    cfg.instructions
    cfg.mcp
    cfg.subagent
  ];
  mkDefaultRecursive = lib.mapAttrsRecursive (_path: lib.mkDefault);

  mcpEntry = {
    args = lib.optionals (cfg.mcp.content != "code") ["--content" cfg.mcp.content];
    command = "${cfg.package}/bin/semble-mcp";
    type = "stdio";
  };

  runtimeConfig = runtime: let
    instruction =
      if runtime == "kiro"
      then records.kiroInstruction
      else records.instruction;
  in
    lib.mkMerge [
      (lib.mkIf (selected runtime cfg.instructions) {
        ai.${runtime}.instructions = [instruction];
      })
      (lib.mkIf (selected runtime cfg.mcp) {
        ai.${runtime}.mcpServers.semble = mkDefaultRecursive mcpEntry;
      })
      (lib.mkIf (selected runtime cfg.subagent) {
        ai.${runtime}.agents.semble-search =
          if runtime == "kiro"
          then lib.mkDefault records.kiroAgent
          else mkDefaultRecursive records.semanticAgent;
      })
    ];
in {
  imports = [(import ./options.nix {inherit lib pkgs;})];

  config = lib.mkMerge (
    [
      (lib.mkIf (
          featureActive cfg.instructions
          || featureActive cfg.mcp
          || featureActive cfg.subagent
        )
        (installPackage cfg.package))
      (lib.mkIf codexSelected
        (configureCodexCache {inherit config lib;}))
    ]
    ++ map runtimeConfig runtimes
  );
}

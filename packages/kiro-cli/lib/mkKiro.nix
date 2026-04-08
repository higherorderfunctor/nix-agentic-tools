# Kiro-specific factory-of-factory.
#
# Imported at flake-eval time into lib.ai.apps.mkKiro via the
# packages/kiro-cli/default.nix barrel and flake.nix's barrel walker.
# Callers (the HM module in ../modules/homeManager/default.nix) invoke
# it once to produce a full NixOS module function.
#
# Note: the mkAiApp config callback receives {cfg, mergedServers,
# mergedInstructions, mergedSkills} — it does NOT receive lib or pkgs.
# Those are closed over from the outer function arguments here.
{
  lib,
  pkgs,
  ...
}:
lib.ai.app.mkAiApp {
  name = "kiro";
  transformers.markdown = lib.ai.transformers.kiro;
  defaults = {
    package = pkgs.ai.kiro-cli;
    outputPath = ".config/kiro/steering/";
  };
  options = {
    # Kiro-specific freeform settings. Full typed surface (editor
    # integration, model selection, steering files, skills, mcpServers
    # fanout, hooks, agents) is tracked in docs/plan.md "Ideal
    # architecture gate → Absorption backlog" under the kiro-cli
    # absorption item. Source material: modules/kiro-cli/default.nix.
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Freeform settings passed to Kiro's config file (rendering tracked in docs/plan.md absorption backlog).";
    };
  };
  # Empty config callback — the factory currently only fans out
  # instructions via the mkAiApp baseline render. Full fanout
  # (steering file writing, skills routing, mcp.json generation,
  # hooks/agents) is tracked in docs/plan.md absorption backlog.
  config = _: {};
}

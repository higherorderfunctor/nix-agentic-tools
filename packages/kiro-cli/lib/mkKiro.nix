# Kiro-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Kiro AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# For now this is a minimal shape preserving the current behavior.
# Full fanout (steering file writing, skills routing, mcp.json
# generation, hooks/agents) is absorbed in Task 5 (A4).
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
  hm = {
    options = {};
    config = _: {};
  };
  devenv = {
    options = {};
    config = _: {};
  };
}

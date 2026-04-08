# Copilot-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Copilot AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# For now this is a minimal shape preserving the current behavior.
# Full fanout (settings.json writing, skills routing, mcp.json
# generation, lsp config) is absorbed in Task 4 (A3).
{
  lib,
  pkgs,
  ...
}:
lib.ai.app.mkAiApp {
  name = "copilot";
  transformers.markdown = lib.ai.transformers.copilot;
  defaults = {
    package = pkgs.ai.copilot-cli;
    outputPath = ".config/github-copilot/copilot-instructions.md";
  };
  options = {
    # Copilot-specific freeform settings. Full typed surface (editor
    # integration, telemetry, model selection, lspServers, skills,
    # mcpServers fanout) is tracked in docs/plan.md "Ideal
    # architecture gate → Absorption backlog" under the copilot-cli
    # absorption item. Source material: modules/copilot-cli/default.nix.
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Freeform settings passed to Copilot's config file (rendering tracked in docs/plan.md absorption backlog).";
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

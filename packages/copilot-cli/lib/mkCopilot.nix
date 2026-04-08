# Copilot-specific factory-of-factory.
#
# Imported at flake-eval time into lib.ai.apps.mkCopilot via the
# packages/copilot-cli/default.nix barrel and flake.nix's barrel walker.
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
  # Empty config callback — the factory currently only fans out
  # instructions via the mkAiApp baseline render. Full fanout
  # (settings.json writing, skills routing, mcp.json generation,
  # lsp config) is tracked in docs/plan.md absorption backlog.
  config = _: {};
}

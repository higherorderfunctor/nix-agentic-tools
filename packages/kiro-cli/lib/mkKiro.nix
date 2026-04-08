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
    # Kiro-specific freeform settings passthrough. Full option
    # typing (editor integration, model selection, etc.)
    # deferred to a later milestone when consumer needs emerge.
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Freeform settings passed to Kiro's config file (rendering deferred).";
    };
  };
  config = _: {};
}

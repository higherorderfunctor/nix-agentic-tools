# Codex-specific factory-of-factory.
#
# CX-003 intentionally exposes only the enable/package vertical. Native Codex
# configuration surfaces are added by later roadmap slices.
{
  lib,
  pkgs,
  ...
}:
lib.ai.app.mkAiApp {
  name = "codex";
  transformers.markdown = lib.ai.transformers.agentsmd;
  defaults.package = pkgs.ai.chatgpt-codex;

  hm.config = {cfg, ...}: {
    home.packages = [cfg.package];
  };

  devenv.config = {cfg, ...}: {
    packages = [cfg.package];
  };
}

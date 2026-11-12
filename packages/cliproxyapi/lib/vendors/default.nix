# Explicit vendor index for providers.nix; each vendor owns its facts and defaults.
{lib}: let
  # Share Go's placement function between production defaults and synthetic checks.
  opencodeGo = import ./opencode-go.nix {inherit lib;};
in {
  # Preserve the callable used by checks/ai-inference/module-eval.nix.
  inherit (opencodeGo) opencodeGo;
  # Credential vendor names select these defaults in providers.nix.
  vendors = {
    opencode-go = opencodeGo.defaults;
    z-ai = import ./z-ai.nix {inherit lib;};
  };
}

{
  lib,
  claudeUsageScript,
  codexUsageScript,
}: {
  families = import ./families.nix;
  models = {
    claude = [
      {
        vendors = ["anthropic"];
      }
    ];
    codex = [
      {
        vendors = ["openai"];
      }
    ];
    kimchi = [];
    kiro = [];
  };
  inherit (import ./entries.nix {inherit lib;}) routing workflows;
  techniques = import ./techniques.nix {inherit claudeUsageScript codexUsageScript;};
}

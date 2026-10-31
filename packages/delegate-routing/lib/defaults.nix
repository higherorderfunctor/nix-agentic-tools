{
  lib,
  claudeUsageScript,
  codexUsageScript,
}: {
  families = import ./families.nix // {opencode-go = (import ./opencode-go.nix {inherit lib;}).families;};
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

{
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
    kiro = [];
  };
  procedure = {
    enable = true;
    text = builtins.readFile ./procedure.md;
  };
  rules = {
    enable = true;
    text = builtins.readFile ./rules.md;
  };
  techniques = import ./techniques.nix {inherit claudeUsageScript codexUsageScript;};
}

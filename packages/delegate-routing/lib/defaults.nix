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
    kimchi = [];
    kiro = [];
  };
  procedure = builtins.readFile ./procedure.md;
  rules = builtins.readFile ./rules.md;
  techniques = import ./techniques.nix {inherit claudeUsageScript codexUsageScript;};
}

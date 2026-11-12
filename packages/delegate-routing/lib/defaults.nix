{
  lib,
  claudeUsageScript,
  codexUsageScript,
}: let
  picker = {
    claude.entries = [
      {
        effort = "low";
        # Names the family; routing-view takes the model from its resolved id.
        family = "sonnet";
        technique = "claude -p";
      }
    ];
    codex.entries = [
      {
        effort = "low";
        model = "gpt-6.1-sol";
        technique = "codex exec";
      }
    ];
    kimchi.entries = [];
    kiro.entries = [];
  };
in {
  inherit picker;
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
  inherit (import ./entries.nix {inherit lib;}) routing skill workflows;
  techniques = import ./techniques.nix {inherit claudeUsageScript codexUsageScript;};
}

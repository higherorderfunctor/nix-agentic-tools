{
  lib,
  claudeUsageScript,
  codexUsageScript,
}: {
  classifiers = [
    {
      effort = "medium";
      family = "luna";
    }
    {
      effort = "medium";
      family = "sonnet";
    }
  ];
  # Only these package-owned groups are keyed by their model maker. Custom
  # families remain unknown unless their consumer declares maker explicitly.
  families =
    lib.mapAttrs (maker:
      lib.mapAttrs (_: family:
        family
        // {
          inherit maker;
          trial = false;
        })) (import ./families.nix)
    // {opencode-go = (import ./opencode-go.nix {inherit lib;}).families;};
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

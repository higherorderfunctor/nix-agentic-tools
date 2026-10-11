# Drift check — the host's fresh extraction must match the single committed
# Linux raw. Settings, model and hook consumers must retain their required facts.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks = (extractedLib {inherit pkgs;}).mkOwnerCheck {
    dir = ../extracted;
    name = "claude-code";
    needs = [
      {
        contains = "high";
        key = "effortLevels";
      }
      {
        contains = "PreToolUse";
        key = "hookEvents";
      }
      {
        contains = "hooks";
        key = "settings.publicKeys";
      }
      {
        contains = "model";
        key = "settings.publicKeys";
      }
    ];
    package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.claude-code;
  };
}

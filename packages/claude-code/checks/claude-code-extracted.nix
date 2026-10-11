# Drift check — the host's fresh extraction must match the single committed
# Linux raw. Settings, model and hook consumers must retain their required facts.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (extractedLib {inherit pkgs;}) expect load mkDriftCheck;
    claudeFacts = load {dir = ../extracted;};
  in
    mkDriftCheck {
      committed = ../extracted;
      extracted.${system} = self.ciPackages.${system}.claude-code.passthru.extracted;
      name = "claude-code";
      results = {
        consumers = expect {
          inherit (claudeFacts) aggregate;
          consumer = "claude-code";
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
        };
        facts = claudeFacts;
      };
      sidecar = "packages/claude-code/extracted";
    };
}

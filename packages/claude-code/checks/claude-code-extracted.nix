# Drift check — both platform raws in packages/claude-code/extracted/ must
# match fresh static extraction from their release tarballs on this host.
# Declared facts must agree across platforms, and the settings, model and
# hook consumers must retain the values they depend on.
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
      extracted = self.ciPackages.${system}.claude-code.passthru.extractedFor;
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
            {key = "launchEffortPins";}
            {
              contains = "claude-opus-5";
              key = "models";
            }
            {key = "settings.paths";}
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

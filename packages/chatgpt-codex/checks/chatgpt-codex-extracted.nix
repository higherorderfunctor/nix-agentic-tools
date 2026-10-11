# Drift, cross-system facts, consumer needs and launcher flags are one gate.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (extractedLib {inherit pkgs;}) expect load mkDriftCheck;
    codexFacts = load {dir = ../extracted;};
    package = self.ciPackages.${system}.chatgpt-codex;
  in
    mkDriftCheck {
      committed = ../extracted;
      extracted.${system} = package.passthru.extracted;
      name = "chatgpt-codex";
      results =
        {
          consumers = expect {
            inherit (codexFacts) aggregate;
            consumer = "chatgpt-codex";
            needs = [
              {key = "cli.commands.codex.flags";}
              {key = "cli.globalFlags";}
              {key = "features";}
              {key = "models";}
            ];
          };
          facts = codexFacts;
        }
        // package.passthru.extractedRules.results;
      sidecar = "packages/chatgpt-codex/extracted";
    };
}

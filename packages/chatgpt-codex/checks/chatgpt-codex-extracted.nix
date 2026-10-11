# Drift, cross-system facts and launcher flags are one gate.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (extractedLib {inherit pkgs;}) load mkDriftCheck;
    codexFacts = load {dir = ../extracted;};
    package = self.ciPackages.${system}.chatgpt-codex;
  in
    mkDriftCheck {
      committed = ../extracted;
      extracted.${system} = package.passthru.extracted;
      name = "chatgpt-codex";
      results =
        {
          facts = codexFacts;
        }
        // package.passthru.extractedRules.results;
      sidecar = "packages/chatgpt-codex/extracted";
    };
}

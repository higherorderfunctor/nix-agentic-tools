# Drift check — the committed Codex sidecar must match the deterministic CLI
# help, feature list, and bundled model catalog exposed by the packaged binary.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (extractedLib {inherit pkgs;}) mkDriftCheck;
    package = self.ciPackages.${system}.chatgpt-codex;
    inherit (package.passthru) extracted;
    committed = ../extracted.json;
  in
    mkDriftCheck {
      inherit committed extracted;
      name = "chatgpt-codex";
      results = package.passthru.extractedRules.results;
      rows = {
        path = "packages/chatgpt-codex/extract/annotations.json";
        value = package.passthru.extractedRules.file;
      };
      sidecar = "packages/chatgpt-codex/extracted.json";
    };
}

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
    extracted = self.ciPackages.${system}.chatgpt-codex.passthru.extracted;
    committed = ../extracted.json;
  in
    mkDriftCheck {
      inherit committed extracted;
      name = "chatgpt-codex";
      sidecar = "packages/chatgpt-codex/extracted.json";
    };
}

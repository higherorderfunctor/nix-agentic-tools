# Drift check — the committed packages/kiro-cli/extracted.json must match what
# the packaged kiro binary and the committed public model-table snapshot contain.
# Blocking (a typed trigger vanishing, or a documented-absent one becoming
# present, is a correctness signal the typed surface must react to). Mirrors
# packages/claude-code/checks/claude-code-extracted.nix; the build of passthru.extracted also enforces
# the fail-loud (>=1 present) guard baked into vu.mkKiroExtract.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (extractedLib {inherit pkgs;}) mkDriftCheck;
    extracted = self.ciPackages.${system}.kiro-cli.passthru.extracted;
    committed = ../extracted.json;
  in
    {
      kiro-models-fixtures = pkgs.runCommand "kiro-models-fixtures" {} ''
        ${pkgs.python3}/bin/python3 ${./kiro-models.py} \
          ${../extract/models.py} ${../model-catalog.json}
        touch "$out"
      '';
    }
    // mkDriftCheck {
      inherit committed extracted;
      results.rollout = (import ../extract/rollout-coverage.nix).check {
        inherit (pkgs) lib;
        extracted = builtins.fromJSON (builtins.readFile committed);
        rows = builtins.fromJSON (builtins.readFile ../extract/rollout-features.json);
      };
      name = "kiro-cli";
      sidecar = "packages/kiro-cli/extracted.json";
    };
}

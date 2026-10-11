# Drift check — the committed packages/kiro-cli/extracted/<host>.json must
# match what the packaged kiro binary and the committed public model-table
# snapshot contain, the facts must merge across systems, and the facts the
# Kiro modules were written against must still hold. Blocking (a typed trigger
# vanishing is a correctness signal the typed surface must react to). The build
# of passthru.extracted also enforces the shape assertions baked into
# vu.mkKiroExtract's locators.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (extractedLib {inherit pkgs;}) expect load mkDriftCheck;
    kiroFacts = load {dir = ../extracted;};
  in
    {
      kiro-models-fixtures = pkgs.runCommand "kiro-models-fixtures" {} ''
        ${pkgs.python3}/bin/python3 ${./kiro-models.py} \
          ${../extract/models.py} ${../model-catalog.json}
        touch "$out"
      '';
    }
    // mkDriftCheck {
      committed = ../extracted;
      # The host's extraction only: settingKeys and workspaceOverridableSettings
      # are host-run, and the other system's package set does not evaluate here.
      extracted.${system} = self.ciPackages.${system}.kiro-cli.passthru.extracted;
      name = "kiro-cli";
      results = {
        consumers = expect {
          inherit (kiroFacts) aggregate;
          consumer = "kiro-cli";
          # mkKiro.nix's option enums and flatten boundary, and the
          # module-eval fixtures that rest on them.
          needs = [
            {
              contains = "SessionStart";
              key = "hookTriggers";
            }
            {
              contains = "workflows";
              key = "rolloutFeatures";
            }
            {
              contains = "chat.enableWorkflows";
              key = "settingKeys";
            }
            {
              contains = "chat.modelDefaults";
              key = "settingKeys";
            }
            {
              contains = "chat.defaultModel";
              key = "workspaceOverridableSettings";
            }
            {
              contains = "chat.enableTangentMode";
              key = "workspaceOverridableSettings";
            }
          ];
        };
        facts = kiroFacts;
      };
      sidecar = "packages/kiro-cli/extracted";
    };
}

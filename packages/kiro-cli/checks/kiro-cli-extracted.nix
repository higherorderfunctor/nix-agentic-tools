# Drift check — the committed packages/kiro-cli/extracted/<host>.json must
# match what the packaged kiro binary contains, the facts must merge across systems, and the facts the
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
    inherit (import ../lib/friendly-features.nix) featureSettingImplications friendlyRolloutFeatures;
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (extractedLib {inherit pkgs;}) mkOwnerCheck;
  in
    {
      # The trigger-map locator on synthetic bundles: a quoted key is the same
      # key; an absent map and a non-literal entry each fail by name.
      kiro-hook-triggers-fixtures = let
        bundle = key: value: "var M=Object.freeze({${key}:${value},SessionEnd:\"SessionEnd\",Stop:\"Stop\",PreToolUse:\"PreToolUse\",PostToolUse:\"PostToolUse\",PreTaskExec:\"PreTaskExec\",PostTaskExec:\"PostTaskExec\",UserPromptSubmit:\"UserPromptSubmit\",PostFileCreate:\"PostFileCreate\",PostFileSave:\"PostFileSave\",PostFileDelete:\"PostFileDelete\",Manual:\"Manual\",agentSpawn:\"SessionStart\"});";
        extract = (import ../lib/packaging.nix).kiroHookTriggersExtractScript pkgs;
      in
        pkgs.runCommand "kiro-hook-triggers-fixtures" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          jq=${pkgs.jq}/bin/jq
          printf '%s' ${pkgs.lib.escapeShellArg (bundle "\"SessionStart\"" "\"SessionStart\"")} > quoted.js
          printf '%s' 'var M=Object.freeze({});' > absent.js
          printf '%s' ${pkgs.lib.escapeShellArg (bundle "SessionStart" "\"Session\"+\"Start\"")} > computed.js
          ${extract} quoted.js > quoted.json
          [ "$("$jq" '.hookTriggers | length' quoted.json)" = 12 ]
          [ "$("$jq" -r '.hookTriggerAliases.agentSpawn' quoted.json)" = SessionStart ]
          for case in absent:"hook trigger map is absent" computed:"non-literal entry"; do
            status=0
            ${extract} "''${case%%:*}.js" > /dev/null 2> err.txt || status=$?
            # Two statements: the left side of `&&` is exempt from errexit, so
            # an extractor that unexpectedly exits 0 would not fail the fixture.
            [ "$status" = 1 ]
            ${pkgs.gnugrep}/bin/grep -qF "''${case#*:}" err.txt
          done
          touch "$out"
        '';
    }
    // mkOwnerCheck {
      dir = ../extracted;
      name = "kiro-cli";
      needs =
        [
          {
            contains = "SessionStart";
            key = "hookTriggers";
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
        ]
        ++ map (feature: {
          contains = feature;
          key = "rolloutFeatures";
        }) (builtins.attrValues friendlyRolloutFeatures)
        ++ map (setting: {
          contains = "chat.${setting}";
          key = "settingKeys";
        }) (builtins.attrValues featureSettingImplications);
      package = self.ciPackages.${system}.kiro-cli;
    };
}

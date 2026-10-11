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
            {key = "hookTriggerAliases";}
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

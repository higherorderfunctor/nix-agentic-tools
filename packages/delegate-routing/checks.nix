{
  harness,
  lib,
  pkgs,
  ...
}: let
  cases = import ./eval/cases.nix {inherit harness lib pkgs;};
  fixtures = pkgs.writeText "delegate-routing-cases.json" (builtins.toJSON cases);
  reminder = import ./lib/reminder.nix {inherit lib pkgs;};
  reminderHooks = lib.mapAttrs (_: hooks: hooks reminder.defaultText) reminder.hooks;
in {
  checks = {
    # Validates every case and renders its fixture and launch plan with no
    # harness on PATH and no login: the suite's --dry-run, nothing launched.
    delegate-routing-eval-structure =
      pkgs.runCommand "delegate-routing-eval-structure" {
        nativeBuildInputs = [pkgs.diffutils pkgs.git pkgs.python3];
        passthru = {inherit cases;};
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR/home"
        python ${./eval}/test_suite.py
        # Templated Kiro probe configs must stay byte-identical to their committed paths.
        python ${./probes/delegates/kiro}/rules.py --check > "$TMPDIR/kiro-rules.log"
        python ${./eval}/suite.py --dry-run --fixtures ${fixtures} --out "$TMPDIR/suite" > "$TMPDIR/dry-run.log"
        touch "$out"
      '';
    # Run each runtime's reminder hook and check what it prints.
    delegate-routing-reminder-hooks =
      pkgs.runCommand "delegate-routing-reminder-hooks" {
        nativeBuildInputs = [pkgs.jq];
        expected = reminder.defaultText;
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${lib.concatMapStringsSep "\n" (runtime: let
          inherit (builtins.head (builtins.head reminderHooks.${runtime}.hooks.UserPromptSubmit).hooks) command;
        in ''
          echo '{"session_id":"probe"}' | ${command} > ${runtime}.json
          jq -e --arg expected "$expected" '.hookSpecificOutput == {hookEventName: "UserPromptSubmit", additionalContext: $expected}' ${runtime}.json
        '') (lib.attrNames (removeAttrs reminderHooks ["kiro"]))}
        echo '{"session_id":"probe"}' | ${reminderHooks.kiro.hooks.delegate-routing-reminder.action.command} > kiro.txt
        [ "$(cat kiro.txt)" = "$expected" ]
        touch "$out"
      '';
  };
  imports = [./checks/module-eval.nix];
  testing.moduleProbes = [
    {
      ai = {
        # The provenance helpers enable every runtime, and delegate-routing
        # asserts each enabled one selects a family. These selections only
        # keep the probe config valid.
        programs.delegate-routing = {
          enable = true;
          runtimes = {
            kimchi.models = [{vendors = ["anthropic"];}];
            kiro.models = [{vendors = ["anthropic"];}];
          };
        };
      };
    }
  ];
}

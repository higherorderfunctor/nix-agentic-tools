# Real repository delivery, with only the named experimental switches changed.
{
  harness,
  lib,
  pkgs,
}: let
  mkCase = {
    codexHeadroom ? false,
    id,
    runtime,
    task,
    switches,
    expected,
  }: let
    evaluated = harness.evalDevenvModules [
      (import ../../../dev/ai.nix {isCI = false;})
      {config = switches;}
    ];
    failures = map (item: item.message) (lib.filter (item: !item.assertion) evaluated.config.assertions);
    program = evaluated.config.ai.programs.delegate-routing;
    reminderEnabled = let
      local = program.runtimes.${runtime}.reminder.enable;
    in
      if local == null
      then program.reminder.enable
      else local;
    selected = lib.filterAttrs (path: _:
      path
      == "AGENTS.md"
      || path == "CLAUDE.md"
      || (runtime == "claude" && (lib.hasPrefix ".claude/" path || path == ".mcp.json"))
      || (runtime == "kiro" && lib.hasPrefix ".kiro/" path))
    (harness.deliveredFiles evaluated.config);
    # Export source references, retaining their derivation context. The check
    # realizes them as dependencies; the runner captures their exact bytes.
    files = lib.mapAttrsToList (path: file:
      if file ? text
      then {
        inherit path;
        inherit (file) text;
      }
      else if file ? source
      then {
        inherit path;
        sourcePath = toString file.source;
      }
      else if (evaluated.config.ai.${runtime}.files.${path}.content.run or null) != null
      then {
        inherit path;
        renderCommand = evaluated.config.ai.${runtime}.files.${path}.content.run;
        renderShell = lib.getExe pkgs.bash;
      }
      else throw "vendor eval: cannot capture delivered file ${path}")
    selected;
  in
    assert lib.assertMsg (failures == []) (lib.concatStringsSep "\n" failures); {
      inherit expected files id runtime task;
      configSwitches = switches;
      configurationSource = "dev/ai.nix";
      hiddenContext =
        if runtime == "claude"
        then ["vendor system prompt including heron_brook; presence and text UNKNOWN"]
        else ["vendor system prompt including workflows_default; activation and text UNKNOWN"];
      hookContext =
        {
          reminder = {
            enabled = reminderEnabled;
            inherit (program.reminder) text;
          };
        }
        // lib.optionalAttrs (runtime == "claude") {
          inherit (evaluated.config.ai.claude) ultracodeOnLaunch;
        };
      # Always-on entries reach the runtime's system prompt, not a file.
      systemPrompt = (evaluated.config.ai.${runtime}.extraSystemPrompt.delegate-routing or {text = null;}).text;
      usage = {
        claude = {
          remainingPercent =
            if codexHeadroom
            then 10
            else 90;
          windowSeconds = 18000;
        };
        codex = {
          remainingPercent =
            if codexHeadroom
            then 90
            else 10;
          windowSeconds = 18000;
        };
        evidence = "Synthetic comparable usage supplied in the user prompt; no live account query.";
      };
    };
  variants = [false true];
  label = value:
    if value
    then "on"
    else "off";
  single = "Fictional task: implement a pure function that returns the sorted unique words of the supplied string 'pear apple pear'.";
  dependent = "Fictional task: derive a normalization specification from the supplied examples 'Pear' -> 'pear' and 'APPLE' -> 'apple'; then implement that specification; then validate the implementation against those examples. Each step consumes the preceding result.";
in
  map (on:
    mkCase {
      expected = "delegate";
      id = "claude-reminder-${label on}";
      runtime = "claude";
      switches.ai.programs.delegate-routing.runtimes.claude.reminder.enable = lib.mkForce on;
      task = single;
    })
  variants
  ++ map (on:
    mkCase {
      codexHeadroom = true;
      expected =
        if on
        then "codex-lane"
        else "observe";
      id = "claude-ultracode-drain-${label on}";
      runtime = "claude";
      switches.ai = {
        claude.ultracodeOnLaunch = lib.mkForce true;
        programs.delegate-routing.runtimes.claude.routing."Pool drain".enable = lib.mkForce on;
      };
      task = dependent;
    })
  variants
  ++ lib.concatMap (dependentTask:
    map (on:
      mkCase {
        expected =
          if dependentTask
          then "workflow"
          else "one-delegate";
        id = "kiro-${
          if dependentTask
          then "dependent"
          else "single"
        }-reminder-${label on}";
        runtime = "kiro";
        switches.ai.programs.delegate-routing.runtimes.kiro.reminder.enable = lib.mkForce on;
        task =
          if dependentTask
          then dependent
          else single;
      })
    variants) [false true]

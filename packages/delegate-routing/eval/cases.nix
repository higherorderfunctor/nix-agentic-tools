# Acceptance cases: the repository's real delivery (dev/ai.nix), with only the
# named switches and task shape selected. suite.py renders each case into a
# fixture repository and runs one real session in it. `expect` names an assertion in suite.py's
# ASSERTIONS table; the prompt never carries it.
{
  harness,
  lib,
  pkgs,
}: let
  inherit (import ../lib/vocabulary.nix) delegateKinds;
  mkCase = {
    expect,
    id,
    runtime,
    switches ? {},
    task,
  }: let
    evaluated = harness.evalDevenvModules [
      (import ../../../dev/ai.nix {isCI = false;})
      {config = switches;}
    ];
    inherit (evaluated) config;
    failures = map (item: item.message) (lib.filter (item: !item.assertion) config.assertions);
    # Export source references, retaining their derivation context. The check
    # realizes them as dependencies; the runner copies their exact bytes.
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
      else let
        owner = lib.findFirst (name: (config.ai.${name}.files.${path}.content.run or null) != null) null harness.harnessNames;
      in
        if owner == null
        then throw "acceptance case ${id}: cannot capture delivered file ${path}"
        else {
          inherit path;
          renderCommand = config.ai.${owner}.files.${path}.content.run;
          renderShell = lib.getExe pkgs.bash;
        })
    (harness.deliveredFiles config);
    # The delegate techniques the delivered skill offers, by runtime. The
    # runner classifies logged tool calls and shell commands by these names.
    techniques = lib.mapAttrs (_: nodes:
      lib.mapAttrs (_: technique: technique.kind)
      (lib.filterAttrs (_: technique: technique.enable && builtins.elem technique.kind delegateKinds) nodes))
    ((import ../lib/select-families.nix {inherit lib;}).effectiveTechniques config);
  in
    assert lib.assertMsg (failures == []) (lib.concatStringsSep "\n" failures); {
      inherit expect files id runtime task techniques;
      usage = {
        claude = {
          remainingPercent = 90;
          windowSeconds = 18000;
        };
        codex = {
          remainingPercent = 10;
          windowSeconds = 18000;
        };
      };
    };
  single = "Implement a pure Python function `unique_words(text)` in `words.py` that returns the sorted unique words of a string; `unique_words('pear apple pear')` must return `['apple', 'pear']`.";
  dependent = "Derive a normalization specification from the examples 'Pear' -> 'pear' and 'APPLE' -> 'apple' and write it to `SPEC.md`; then implement that specification as `normalize(word)` in `normalize.py`; then validate the implementation against those examples. Each step consumes the preceding result.";
  reminderPairs = lib.concatMap (runtime:
    map (on:
      mkCase {
        inherit runtime;
        expect = "delegate";
        id = "${runtime}-reminder-${
          if on
          then "on"
          else "off"
        }";
        switches.ai.programs.delegate-routing.reminder.enable = lib.mkForce on;
        task = single;
      }) [true false]) ["claude" "kiro"];
  # Task shape: a single task wants one delegate, a dependent chain a workflow.
  shapes = lib.concatMap (runtime: [
    (mkCase {
      inherit runtime;
      expect = "one-delegate";
      id = "${runtime}-single";
      task = single;
    })
    (mkCase {
      inherit runtime;
      expect = "workflow";
      id = "${runtime}-dependent";
      task = dependent;
    })
  ]) ["codex" "kimchi" "kiro"];
in
  reminderPairs ++ shapes

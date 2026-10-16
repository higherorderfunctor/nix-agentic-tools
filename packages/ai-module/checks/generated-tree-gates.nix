# A runtime's generated tree gates the delivery of every staged entry, a
# recursive source and a value included, though neither points into it: each
# file a backend delivers carries the tree in its string context, so building
# the delivery builds the tree, and a failing `ai.checks` entry fails it.
# Claude with only skills (recursive), and a synthetic runtime whose only
# staged entry is a value, each on both backends.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  ai = import ../../../lib/ai {inherit lib;};
  record = ai.app.mkRuntime {
    inherit pkgs;
    name = "probe";
    contentTargets = _: {context = "doc.md";};
    contextFilename = "doc.md";
    defaults.package = pkgs.hello;
    surfaceSupport.context.backends = ["devenv" "hm"];
    config = _: {
      ai.probe._generatedFiles."settings.json" = {
        content.value.probe = true;
        format = "json";
        surface = "settings";
      };
    };
  };
  cases = {
    skills = {
      config.ai = {
        checks.skills = "exit 7";
        claude = {
          enable = true;
          # The devenv settings copy is old-path delivery, built from the tree.
          files.".claude/settings.json".content.enable = false;
          skills.probe = ./fixtures/probe-skill;
        };
      };
      delivered = [".claude/skills/probe/SKILL.md" ".claude/skills/probe/references/nested.md" ".claude/skills/probe/scripts/executable-probe"];
      evaluate = {
        devenv = harness.evalDevenv;
        hm = harness.evalHm;
      };
      runtime = "claude";
      surface = "skills";
    };
    value = {
      config.ai = {
        checks.settings = "exit 7";
        probe.enable = true;
      };
      delivered = ["settings.json"];
      evaluate = {
        devenv = config: harness.evalDevenvModules [(ai.app.devenvTransform record) {inherit config;}];
        hm = config: harness.evalHmModules [(ai.app.hmTransform record) {inherit config;}];
      };
      runtime = "probe";
      surface = "settings";
    };
  };
  probes = lib.concatMap (name:
    map (backend: let
      case = cases.${name};
      inherit (case.evaluate.${backend} case.config) config;
      tree = config.ai.${case.runtime}._generatedTree;
      files = harness.deliveredFiles config;
      gated = path: builtins.getContext (toString files.${path}.source) ? ${builtins.unsafeDiscardStringContext tree.drvPath};
    in {
      inherit backend case name tree;
      failures =
        lib.optional (builtins.attrNames files != case.delivered) "delivers only ${toString case.delivered}"
        ++ lib.optional (!lib.all gated case.delivered) "every delivered file carries the tree in its context";
    }) ["devenv" "hm"]) (builtins.attrNames cases);
  failures = lib.concatMap (probe: map (failure: "${probe.name} on ${probe.backend}: ${failure}") probe.failures) probes;
in {
  checks.ai-module-generated-tree-gates = assert lib.assertMsg (failures == []) "generated tree gates: ${lib.concatStringsSep "; " failures}";
    pkgs.runCommandLocal "ai-module-generated-tree-gates" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${lib.concatMapStrings (probe: ''
          ${pkgs.gnugrep}/bin/grep -qF ${lib.escapeShellArg "Generated-file check failed for surface ${probe.case.surface} in runtime ${probe.case.runtime}"} ${pkgs.testers.testBuildFailure probe.tree}/testBuildFailure.log
        '')
        probes}
      printf 'PASS: a failing check fails the tree every delivered staged file depends on\n' > "$out"
    '';
}

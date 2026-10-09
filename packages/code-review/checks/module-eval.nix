{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  evaluate = evaluator: extra:
    evaluator (lib.recursiveUpdate {
        ai = {
          kimchi.enable = true;
          kiro.enable = true;
          programs.code-review.enable = true;
        };
      }
      extra);
  overridden = map (evaluator:
    evaluate evaluator {
      ai.programs.code-review.runtimes.kiro.profile = ./fixtures/kiro-profile.json;
    }) [evalHm evalDevenv];
  selectedAgents = lib.mapAttrs (_: agent: {
    inherit (agent) model;
    effortLevel = agent.effortLevel or "default";
  }) (lib.filterAttrs (name: _: lib.hasPrefix "code-review-" name) (builtins.head overridden).config.ai.kiro.native.agents);
  results = map (evaluator: evaluate evaluator {}) [evalHm evalDevenv];
in {
  checks = {
    code-review-installed-profile =
      pkgs.runCommand "code-review-installed-profile" {
        nativeBuildInputs = [pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export CODE_REVIEW_AGENTS=${pkgs.writeText "code-review-agents.json" (builtins.toJSON selectedAgents)}
        export CODE_REVIEW_PAYLOAD=${pkgs.ai.code-review}/share/code-review
        export CODE_REVIEW_SKILLS=${lib.escapeShellArg (builtins.toJSON (map (result: toString result.config.ai.kiro.skills.code-review) overridden))}
        python ${./test_delivery.py}
        touch "$out"
      '';
    module-code-review-conflicting-gate = mkTest "code-review-conflicting-gate" (lib.all (evaluator: let
      result = evaluate evaluator {ai.kiro.cli.v3 = false;};
    in
      lib.any (assertion: !assertion.assertion && lib.hasInfix "ai.programs.code-review on Kiro" assertion.message) result.config.assertions) [evalHm evalDevenv]);
    module-code-review-delivery = mkTest "code-review-delivery" (lib.all (result:
      lib.all (path: lib.hasInfix "\"name\":\"code-review-" (harness.deliveredMarkdown result path)) (lib.filter (lib.hasPrefix ".kiro/agents/code-review-") (builtins.attrNames result.config.ai.kiro.files))
      && result.config.ai.kimchi.skills ? code-review
      && result.config.ai.kiro.skills ? code-review
      && builtins.length (lib.filter (lib.hasPrefix "code-review-") (builtins.attrNames result.config.ai.kiro.native.agents)) == 11
      && result.config.ai.kiro.cli.v3
      && result.config.ai.kiro.cli.workflows.enable
      && result.config.ai.kimchi.extensions ? workflows)
    results);
    module-code-review-disabled = mkTest "code-review-disabled" (lib.all (evaluator: let
      result = evaluator {};
    in
      !(result.config.ai.kimchi.skills ? code-review)
      && !(result.config.ai.kiro.skills ? code-review)) [evalHm evalDevenv]);
    module-code-review-runtime-override = mkTest "code-review-runtime-override" (lib.all (evaluator: let
      result = evaluate evaluator {ai.programs.code-review.runtimes.kiro.enable = false;};
    in
      result.config.ai.kimchi.skills ? code-review
      && !(result.config.ai.kiro.skills ? code-review)
      && lib.filter (lib.hasPrefix "code-review-") (builtins.attrNames result.config.ai.kiro.native.agents) == []) [evalHm evalDevenv]);
    module-code-review-selective-import = mkTest "code-review-selective-import" (let
      result = lib.evalModules {
        modules = [../modules/common.nix {ai.programs.code-review.enable = true;}];
        specialArgs = {inherit pkgs;};
      };
    in
      !(result.config.ai ? kimchi) && !(result.config.ai ? kiro));
  };
  testing.moduleProbes = [
    {
      ai.programs.code-review.enable = true;
    }
  ];
}

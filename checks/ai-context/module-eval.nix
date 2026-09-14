# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  inherit (import ../../packages/kiro-cli/checks/helpers.nix {inherit lib pkgs harness;}) kiroSteeringFiles;
in {
  checks = {
    module-context-content-record-rejects-two-sources = mkTest "context-content-record-rejects-two-sources" (!(builtins.tryEval (let
      result = evalHm {
        ai.context = {
          source = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
          text = "two sources";
        };
      };
    in
      builtins.deepSeq result.config.ai.context true)).success);

    module-runtime-context-record-rejects-two-sources = mkTest "runtime-context-record-rejects-two-sources" (!(builtins.tryEval (let
      result = evalHm {
        ai.codex.context = {
          source = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
          text = "two sources";
        };
      };
    in
      builtins.deepSeq result.config.ai.codex.context true)).success);

    module-content-record-competing-writers-conflict = mkTest "content-record-competing-writers-conflict" (
      let
        aiCommon = import ../../lib/ai/ai-common.nix {inherit lib;};
        contextAttempt = builtins.tryEval (let
          result = lib.evalModules {
            modules = [
              {
                options.context = lib.mkOption {
                  type = aiCommon.optionalContentModule;
                  default = {};
                  apply = aiCommon.validateOptionalContent;
                };
              }
              {context.text = "first writer";}
              {context.text = "second writer";}
            ];
          };
        in
          builtins.deepSeq result.config.context true);
        ruleAttempt = builtins.tryEval (let
          result = lib.evalModules {
            modules = [
              {
                options.rules = lib.mkOption {
                  type = lib.types.attrsOf aiCommon.ruleModule;
                  default = {};
                  apply = aiCommon.validateRules;
                };
              }
              {rules.same.text = "first writer";}
              {rules.same.text = "second writer";}
            ];
          };
        in
          builtins.deepSeq result.config.rules true);
      in
        !contextAttempt.success && !ruleAttempt.success
    );

    module-single-context-source-does-not-trigger-ifd = mkTest "single-context-source-does-not-trigger-ifd" (
      let
        source = pkgs.runCommand "context-source-must-not-build" {} ''
          exit 1
        '';
        result = evalDevenv {
          ai.copilot = {
            context = {inherit source;};
            enable = true;
          };
        };
        entry = result.config.files.".github/copilot-instructions.md";
      in
        entry.source == source && !(entry ? text)
    );

    module-rule-rejects-empty-matcher = mkTest "rule-rejects-empty-matcher" (!(builtins.tryEval (let
      result = evalHm {
        ai.rules.empty-matcher = {
          matcher = [];
          text = "ambiguous";
        };
      };
    in
      builtins.deepSeq result.config.ai.rules.empty-matcher true)).success);

    module-shared-agentsmd-dedupes-identical-units = mkTest "shared-agentsmd-dedupes-identical-units" (
      let
        result = evalDevenv {
          ai = {
            codex.enable = true;
            context.text = "Shared context.";
            kimchi.enable = true;
            kiro.enable = true;
            rules.shared.text = "Shared rule.";
          };
        };
        agents = result.config.files."AGENTS.md".text;
      in
        agents
        == "Shared context.\n\n<!-- rule: shared -->\nShared rule."
        && !(lib.hasInfix "---" agents)
    );

    module-shared-agentsmd-rejects-divergent-units = mkTest "shared-agentsmd-rejects-divergent-units" (
      lib.all (runtime:
        !(builtins.tryEval (let
          result = evalDevenv {
            ai = {
              codex = {
                enable = true;
                rules.shared.text = "Codex view.";
              };
              ${runtime} = {
                enable = true;
                rules.shared.text = "Other view.";
              };
            };
          };
        in
          builtins.deepSeq result.config.files."AGENTS.md" true)).success)
      ["kimchi" "kiro"]
    );

    module-shared-agentsmd-omits-absent-runtime-context = mkTest "shared-agentsmd-omits-absent-runtime-context" (
      let
        result = evalDevenv {
          ai = {
            codex = {
              context.text = "Codex-only context.";
              enable = true;
            };
            kimchi = {
              enable = true;
              rules.kimchi-only.text = "Kimchi rule.";
            };
            kiro = {
              enable = true;
              rules.kiro-only.text = "Kiro rule.";
            };
          };
        };
        agents = result.config.files."AGENTS.md".text;
      in
        lib.hasInfix "Codex-only context." agents
        && lib.hasInfix "Kimchi rule." agents
        && lib.hasInfix "Kiro rule." agents
    );

    # Top-level `ai.rulesDir` fans out to every enabled CLI via the
    # sharedOptions L1→L2 expansion.
    module-top-level-rulesdir-fans-out-to-kiro = mkTest "top-level-rulesdir-fans-out-to-kiro" (
      let
        result = evalHm {
          ai = {
            kiro.enable = true;
            rulesDir = ../../packages/kiro-cli/checks/fixtures/kiro-steering;
          };
        };
      in
        (kiroSteeringFiles result) ? "alpha.md"
    );

    # Top-level `ai.skillsDir` fans out to every enabled CLI.
    module-top-level-skillsdir-fans-out-to-claude = mkTest "top-level-skillsdir-fans-out-to-claude" (
      let
        result = evalHm {
          ai = {
            claude.enable = true;
            skillsDir = ../../packages/claude-code/checks/fixtures/claude-skills;
          };
        };
        upstream = result.config.programs.claude-code.skills or {};
      in
        upstream ? skill-a && upstream ? skill-b
    );

    module-ai-rules-accepted-for-claude = mkTest "ai-rules-accepted-for-claude" (
      let
        probe =
          builtins.tryEval
          (evalHm {
            ai.claude = {
              enable = true;
              rules.test.text = "test";
            };
          })
      .config.home.packages;
      in
        probe.success
    );

    module-ai-rules-dir-accepted-for-claude = mkTest "ai-rules-dir-accepted-for-claude" (
      let
        probe =
          builtins.tryEval
          (evalHm {
            ai.claude = {
              enable = true;
              rulesDir = ../../packages/kiro-cli/checks/fixtures/kiro-steering;
            };
          })
      .config.home.packages;
      in
        probe.success
    );

    module-ai-rules-dir-accepted-for-kimchi = mkTest "ai-rules-dir-accepted-for-kimchi" (
      let
        result = evalHm {
          ai.kimchi = {
            enable = true;
            rulesDir = ../../packages/kiro-cli/checks/fixtures/kiro-steering;
          };
        };
      in
        result.config.home.file ? ".config/kimchi/harness/AGENTS.md"
    );

    # Top-level `ai.agentsDir` fans out to every enabled agent-
    # consumer (Claude, Copilot, Kimchi — NOT Kiro).
    module-top-level-agentsdir-fans-out-to-claude = mkTest "top-level-agentsdir-fans-out-to-claude" (
      let
        result = evalHm {
          ai = {
            claude.enable = true;
            agentsDir = ../../packages/claude-code/checks/fixtures/claude-agents;
          };
        };
        upstream = result.config.programs.claude-code.agents or {};
      in
        upstream ? agent-one && upstream ? agent-two
    );
  };
}

# Module evaluation tests for home-manager modules.
# Verifies that modules evaluate without errors for representative configs.
{
  lib,
  pkgs,
  self,
}: let
  # Minimal home-manager evaluation harness.
  # Stubs enough of the HM interface for module options to evaluate.
  evalModule = modules:
    lib.evalModules {
      modules =
        modules
        ++ [
          {
            config._module.args = {
              inherit pkgs;
              osConfig = {};
            };
          }
          ({lib, ...}: {
            options = {
              assertions = lib.mkOption {
                type = lib.types.listOf lib.types.anything;
                default = [];
              };
              home = {
                activation = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = {};
                };
                file = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = {};
                };
                packages = lib.mkOption {
                  type = lib.types.listOf lib.types.package;
                  default = [];
                };
              };
              programs = {
                git.settings = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = {};
                };
                mcp = {
                  enable = lib.mkEnableOption "mcp";
                  servers = lib.mkOption {
                    type = lib.types.attrsOf lib.types.anything;
                    default = {};
                  };
                };
              };
              # Stub programs.claude-code (upstream HM module, not in this repo)
              programs.claude-code = {
                enable = lib.mkEnableOption "claude-code";
                package = lib.mkOption {
                  type = lib.types.package;
                  default = pkgs.claude-code or pkgs.hello;
                };
                settings = lib.mkOption {
                  type = lib.types.submodule {
                    freeformType = (pkgs.formats.json {}).type;
                    options.model = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                    };
                  };
                  default = {};
                };
                skills = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = {};
                };
              };
              # Stub systemd (needed by mcp-servers module for services).
              # The real Darwin guard is in modules/mcp-servers/default.nix
              # (lib.mkIf pkgs.stdenv.isLinux); this stub satisfies evaluation.
              systemd.user.services = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = {};
              };
            };
          })
        ];
    };

  # Test: copilot-cli module evaluates with enable = false (no-op)
  copilotDisabled = evalModule [
    self.homeManagerModules.copilot-cli
    {config.programs.copilot-cli.enable = false;}
  ];

  # Test: kiro-cli module evaluates with enable = false (no-op)
  kiroDisabled = evalModule [
    self.homeManagerModules.kiro-cli
    {config.programs.kiro-cli.enable = false;}
  ];

  # Test: MCP server module evaluates with all servers disabled
  mcpDisabled = evalModule [
    self.homeManagerModules.mcp-servers
  ];

  # Test: stacked-workflows module evaluates with enable = false (no-op)
  swsDisabled = evalModule [
    self.homeManagerModules.stacked-workflows
    {config.stacked-workflows.enable = false;}
  ];

  # Test: ai module evaluates as no-op when nothing is enabled
  # (there is no master ai.enable anymore — each ai.{claude,copilot,kiro}.enable
  # is the sole gate and flips its corresponding programs.*.enable).
  # Must import full module set since ai references programs.copilot-cli, etc.
  aiDisabled = evalModule [
    self.homeManagerModules.default
  ];

  # Test: ai module evaluates with copilot + kiro enabled
  aiWithClis = evalModule [
    self.homeManagerModules.default
    {
      config = {
        ai = {
          copilot.enable = true;
          kiro.enable = true;
          skills = {};
          instructions.test-rule = {
            text = "Test instruction";
            description = "Test";
          };
        };
      };
    }
  ];

  # Test: ai module evaluates with buddy configured (new attrTag userId)
  aiBuddy = evalModule [
    self.homeManagerModules.default
    {
      config = {
        ai.claude = {
          enable = true;
          buddy = {
            userId.text = "test-00000000-0000-0000-0000-000000000000";
            species = "duck";
            rarity = "common";
          };
        };
      };
    }
  ];

  # Test: ai module settings fanout to all three ecosystems
  aiWithSettings = evalModule [
    self.homeManagerModules.default
    {
      config = {
        ai = {
          claude.enable = true;
          copilot.enable = true;
          kiro.enable = true;
          settings = {
            model = "claude-sonnet-4";
            telemetry = false;
          };
        };
      };
    }
  ];

  # Test: ai.skills fans out to programs.claude-code.skills (not home.file).
  # Guards the Claude branch against regressing to direct home.file writes,
  # which produce Layout A (single dir symlink) instead of the upstream
  # Layout B (real dir with per-file symlinks via recursive = true).
  aiSkillsFanout = evalModule [
    self.homeManagerModules.default
    {
      config = {
        ai = {
          claude.enable = true;
          skills.stack-fix = /tmp/test-skill;
        };
      };
    }
  ];

  # Test: homeManagerModules.ai is self-contained — importing
  # only the ai module (not the full default bundle) should
  # still declare the programs.{copilot-cli,kiro-cli}.* and
  # programs.claude-code.buddy option paths that ai.nix
  # references unconditionally inside its mkIf blocks.
  aiSelfContained = evalModule [
    self.homeManagerModules.ai
    {
      config = {
        ai = {
          claude = {
            enable = true;
            buddy = {
              userId.text = "test-00000000-0000-0000-0000-000000000000";
              species = "duck";
              rarity = "common";
            };
          };
          copilot.enable = true;
          kiro.enable = true;
        };
      };
    }
  ];

  # ═══════════════════════════════════════════════════════════════
  # Phase 2a safety-net fixtures: assertion-based tests for the
  # current inline ai module fanout. These tests run against the
  # EXISTING inline mkIf blocks in modules/ai/default.nix before
  # Phase 2a's adapter refactor, and MUST continue passing after
  # each of Commits 4-6 replaces one ecosystem's inline block with
  # a mkAiEcosystemHmModule call. If any assertion fails during a
  # replacement commit, the adapter has drifted from the legacy
  # behavior — rollback and debug before re-attempting.
  # ═══════════════════════════════════════════════════════════════

  # Rich Claude fixture exercising all Claude-relevant options.
  phase2aClaudeFixture = evalModule [
    self.homeManagerModules.ai
    {
      config = {
        ai = {
          claude = {
            enable = true;
            buddy = {
              userId.text = "test-00000000-0000-0000-0000-000000000000";
              species = "duck";
              rarity = "common";
            };
          };
          skills.stack-fix = /tmp/test-stack-fix-skill;
          instructions.test-rule = {
            text = "Always use strict mode";
            paths = ["src/**"];
            description = "Test rule for Phase 2a safety net";
          };
          lspServers.nixd = {
            package = pkgs.hello; # stub package; real nixd not needed for eval
            extensions = ["nix"];
          };
          settings.model = "claude-sonnet-4-test";
        };
      };
    }
  ];

  # Rich Copilot fixture.
  phase2aCopilotFixture = evalModule [
    self.homeManagerModules.ai
    {
      config = {
        ai = {
          copilot.enable = true;
          skills.stack-fix = /tmp/test-stack-fix-skill;
          instructions.test-rule = {
            text = "Use fp patterns";
            paths = ["lib/**"];
            description = "Test rule";
          };
          lspServers.marksman = {
            package = pkgs.hello;
            extensions = ["md"];
          };
          environmentVariables.AI_TEST_MODE = "1";
          settings.model = "gpt-4-test";
        };
      };
    }
  ];

  # Rich Kiro fixture.
  phase2aKiroFixture = evalModule [
    self.homeManagerModules.ai
    {
      config = {
        ai = {
          kiro.enable = true;
          skills.stack-fix = /tmp/test-stack-fix-skill;
          instructions.test-rule = {
            text = "No shortcuts";
            paths = ["tests/**"];
            description = "Test steering rule";
          };
          lspServers.nixd = {
            package = pkgs.hello;
            extensions = ["nix"];
          };
          environmentVariables.KIRO_TEST_MODE = "1";
          settings = {
            model = "claude-sonnet-4-test";
            telemetry = false;
          };
        };
      };
    }
  ];
in {
  copilot-cli-eval = pkgs.runCommand "copilot-cli-eval" {} ''
    echo "copilot-cli module evaluation: ${
      if copilotDisabled.config.programs.copilot-cli.enable
      then "enabled"
      else "disabled (no-op)"
    }" > $out
  '';

  kiro-cli-eval = pkgs.runCommand "kiro-cli-eval" {} ''
    echo "kiro-cli module evaluation: ${
      if kiroDisabled.config.programs.kiro-cli.enable
      then "enabled"
      else "disabled (no-op)"
    }" > $out
  '';

  mcp-servers-eval = pkgs.runCommand "mcp-servers-eval" {} ''
    echo "mcp-servers module evaluation: ${
      if mcpDisabled.config.services.mcp-servers.enable or false
      then "enabled"
      else "disabled (no-op)"
    }" > $out
  '';

  stacked-workflows-eval = pkgs.runCommand "stacked-workflows-eval" {} ''
    echo "stacked-workflows module evaluation: ${
      if swsDisabled.config.stacked-workflows.enable
      then "enabled"
      else "disabled (no-op)"
    }" > $out
  '';

  ai-eval = pkgs.runCommand "ai-eval" {} ''
    echo "ai module evaluation: ${
      if
        aiDisabled.config.programs.claude-code.enable
        || aiDisabled.config.programs.copilot-cli.enable
        || aiDisabled.config.programs.kiro-cli.enable
      then "enabled"
      else "disabled (no-op)"
    }" > $out
  '';

  ai-with-clis-eval = pkgs.runCommand "ai-with-clis-eval" {} ''
    echo "ai with copilot+kiro: ${
      if
        aiWithClis.config.programs.copilot-cli.enable
        && aiWithClis.config.programs.kiro-cli.enable
      then "enabled"
      else "disabled"
    }" > $out
  '';

  ai-buddy-eval = pkgs.runCommand "ai-buddy-eval" {} ''
    echo "ai buddy evaluation: ${
      if aiBuddy.config.ai.claude.buddy != null
      then "buddy configured"
      else "buddy missing"
    }" > $out
  '';

  ai-with-settings-eval = pkgs.runCommand "ai-with-settings-eval" {} ''
    echo "ai settings fanout: ${
      if aiWithSettings.config.programs.copilot-cli.settings.model == "claude-sonnet-4"
      then "model propagated"
      else "model missing"
    }" > $out
  '';

  ai-skills-fanout-eval = pkgs.runCommand "ai-skills-fanout-eval" {} ''
    ${
      if aiSkillsFanout.config.programs.claude-code.skills ? stack-fix
      then "echo ok > $out"
      else "echo 'FAIL: ai.skills not routed via programs.claude-code.skills' >&2; exit 1"
    }
  '';

  ai-self-contained-eval = pkgs.runCommand "ai-self-contained-eval" {} ''
    ${
      if
        aiSelfContained.config.programs.copilot-cli.enable
        && aiSelfContained.config.programs.kiro-cli.enable
        && aiSelfContained.config.programs.claude-code.buddy != null
      then "echo ok > $out"
      else "echo 'FAIL: ai module not self-contained — importing homeManagerModules.ai alone did not bring in copilot-cli/kiro-cli/claude-code-buddy modules' >&2; exit 1"
    }
  '';

  # ── Phase 2a safety-net assertions: Claude ─────────────────────
  phase2a-claude-enable = pkgs.runCommand "phase2a-claude-enable" {} ''
    ${
      if phase2aClaudeFixture.config.programs.claude-code.enable
      then "echo ok > $out"
      else "echo 'FAIL: ai.claude.enable did not propagate to programs.claude-code.enable' >&2; exit 1"
    }
  '';

  phase2a-claude-skills-fanout = pkgs.runCommand "phase2a-claude-skills-fanout" {} ''
    ${
      if phase2aClaudeFixture.config.programs.claude-code.skills ? stack-fix
      then "echo ok > $out"
      else "echo 'FAIL: ai.skills.stack-fix did not reach programs.claude-code.skills' >&2; exit 1"
    }
  '';

  phase2a-claude-instruction-fanout = pkgs.runCommand "phase2a-claude-instruction-fanout" {} ''
    ${
      if phase2aClaudeFixture.config.home.file ? ".claude/rules/test-rule.md"
      then "echo ok > $out"
      else "echo 'FAIL: ai.instructions.test-rule did not write .claude/rules/test-rule.md' >&2; exit 1"
    }
  '';

  phase2a-claude-instruction-content = pkgs.runCommand "phase2a-claude-instruction-content" {} ''
    ${
      let
        inherit (phase2aClaudeFixture.config.home.file.".claude/rules/test-rule.md") text;
        hasFrontmatter = lib.hasInfix "---" text;
        hasDescription = lib.hasInfix "Test rule for Phase 2a safety net" text;
        hasPaths = lib.hasInfix "src/**" text;
        hasBody = lib.hasInfix "Always use strict mode" text;
      in
        if hasFrontmatter && hasDescription && hasPaths && hasBody
        then "echo ok > $out"
        else "echo 'FAIL: claude rule file content missing frontmatter (${toString hasFrontmatter}), description (${toString hasDescription}), paths (${toString hasPaths}), or body (${toString hasBody})' >&2; exit 1"
    }
  '';

  phase2a-claude-settings-model = pkgs.runCommand "phase2a-claude-settings-model" {} ''
    ${
      if phase2aClaudeFixture.config.programs.claude-code.settings.model == "claude-sonnet-4-test"
      then "echo ok > $out"
      else "echo 'FAIL: ai.settings.model did not propagate to programs.claude-code.settings.model' >&2; exit 1"
    }
  '';

  phase2a-claude-lsp-auto-enable = pkgs.runCommand "phase2a-claude-lsp-auto-enable" {} ''
    ${
      if (phase2aClaudeFixture.config.programs.claude-code.settings.env.ENABLE_LSP_TOOL or null) == "1"
      then "echo ok > $out"
      else "echo 'FAIL: ai.lspServers did not auto-enable ENABLE_LSP_TOOL=1' >&2; exit 1"
    }
  '';

  phase2a-claude-buddy-fanout = pkgs.runCommand "phase2a-claude-buddy-fanout" {} ''
    ${
      if phase2aClaudeFixture.config.programs.claude-code.buddy != null
        && phase2aClaudeFixture.config.programs.claude-code.buddy.species == "duck"
      then "echo ok > $out"
      else "echo 'FAIL: ai.claude.buddy did not propagate to programs.claude-code.buddy with species=duck' >&2; exit 1"
    }
  '';

  # ── Phase 2a safety-net assertions: Copilot ────────────────────
  phase2a-copilot-enable = pkgs.runCommand "phase2a-copilot-enable" {} ''
    ${
      if phase2aCopilotFixture.config.programs.copilot-cli.enable
      then "echo ok > $out"
      else "echo 'FAIL: ai.copilot.enable did not propagate to programs.copilot-cli.enable' >&2; exit 1"
    }
  '';

  phase2a-copilot-skills-fanout = pkgs.runCommand "phase2a-copilot-skills-fanout" {} ''
    ${
      if phase2aCopilotFixture.config.programs.copilot-cli.skills ? stack-fix
      then "echo ok > $out"
      else "echo 'FAIL: ai.skills.stack-fix did not reach programs.copilot-cli.skills' >&2; exit 1"
    }
  '';

  phase2a-copilot-instruction-fanout = pkgs.runCommand "phase2a-copilot-instruction-fanout" {} ''
    ${
      if phase2aCopilotFixture.config.programs.copilot-cli.instructions ? test-rule
      then "echo ok > $out"
      else "echo 'FAIL: ai.instructions.test-rule did not reach programs.copilot-cli.instructions' >&2; exit 1"
    }
  '';

  phase2a-copilot-instruction-has-apply-to = pkgs.runCommand "phase2a-copilot-instruction-has-apply-to" {} ''
    ${
      let
        text = phase2aCopilotFixture.config.programs.copilot-cli.instructions.test-rule;
        hasApplyTo = lib.hasInfix "applyTo" text;
        hasPattern = lib.hasInfix "lib/**" text;
      in
        if hasApplyTo && hasPattern
        then "echo ok > $out"
        else "echo 'FAIL: copilot instruction content missing applyTo (${toString hasApplyTo}) or lib/** pattern (${toString hasPattern})' >&2; exit 1"
    }
  '';

  phase2a-copilot-env-vars = pkgs.runCommand "phase2a-copilot-env-vars" {} ''
    ${
      if (phase2aCopilotFixture.config.programs.copilot-cli.environmentVariables.AI_TEST_MODE or null) == "1"
      then "echo ok > $out"
      else "echo 'FAIL: ai.environmentVariables.AI_TEST_MODE did not reach programs.copilot-cli.environmentVariables' >&2; exit 1"
    }
  '';

  phase2a-copilot-settings-model = pkgs.runCommand "phase2a-copilot-settings-model" {} ''
    ${
      if phase2aCopilotFixture.config.programs.copilot-cli.settings.model == "gpt-4-test"
      then "echo ok > $out"
      else "echo 'FAIL: ai.settings.model did not reach programs.copilot-cli.settings.model' >&2; exit 1"
    }
  '';

  phase2a-copilot-lsp-fanout = pkgs.runCommand "phase2a-copilot-lsp-fanout" {} ''
    ${
      if phase2aCopilotFixture.config.programs.copilot-cli.lspServers ? marksman
      then "echo ok > $out"
      else "echo 'FAIL: ai.lspServers.marksman did not reach programs.copilot-cli.lspServers' >&2; exit 1"
    }
  '';

  # ── Phase 2a safety-net assertions: Kiro ───────────────────────
  phase2a-kiro-enable = pkgs.runCommand "phase2a-kiro-enable" {} ''
    ${
      if phase2aKiroFixture.config.programs.kiro-cli.enable
      then "echo ok > $out"
      else "echo 'FAIL: ai.kiro.enable did not propagate to programs.kiro-cli.enable' >&2; exit 1"
    }
  '';

  phase2a-kiro-skills-fanout = pkgs.runCommand "phase2a-kiro-skills-fanout" {} ''
    ${
      if phase2aKiroFixture.config.programs.kiro-cli.skills ? stack-fix
      then "echo ok > $out"
      else "echo 'FAIL: ai.skills.stack-fix did not reach programs.kiro-cli.skills' >&2; exit 1"
    }
  '';

  phase2a-kiro-steering-fanout = pkgs.runCommand "phase2a-kiro-steering-fanout" {} ''
    ${
      if phase2aKiroFixture.config.programs.kiro-cli.steering ? test-rule
      then "echo ok > $out"
      else "echo 'FAIL: ai.instructions.test-rule did not reach programs.kiro-cli.steering' >&2; exit 1"
    }
  '';

  phase2a-kiro-steering-has-inclusion = pkgs.runCommand "phase2a-kiro-steering-has-inclusion" {} ''
    ${
      let
        text = phase2aKiroFixture.config.programs.kiro-cli.steering.test-rule;
        hasInclusion = lib.hasInfix "inclusion: fileMatch" text;
        hasPattern = lib.hasInfix "tests/**" text;
      in
        if hasInclusion && hasPattern
        then "echo ok > $out"
        else "echo 'FAIL: kiro steering content missing inclusion: fileMatch (${toString hasInclusion}) or tests/** pattern (${toString hasPattern})' >&2; exit 1"
    }
  '';

  phase2a-kiro-env-vars = pkgs.runCommand "phase2a-kiro-env-vars" {} ''
    ${
      if (phase2aKiroFixture.config.programs.kiro-cli.environmentVariables.KIRO_TEST_MODE or null) == "1"
      then "echo ok > $out"
      else "echo 'FAIL: ai.environmentVariables.KIRO_TEST_MODE did not reach programs.kiro-cli.environmentVariables' >&2; exit 1"
    }
  '';

  phase2a-kiro-settings-model-remap = pkgs.runCommand "phase2a-kiro-settings-model-remap" {} ''
    ${
      if phase2aKiroFixture.config.programs.kiro-cli.settings.chat.defaultModel == "claude-sonnet-4-test"
      then "echo ok > $out"
      else "echo 'FAIL: ai.settings.model did not remap to programs.kiro-cli.settings.chat.defaultModel (key remap is the critical kiro test)' >&2; exit 1"
    }
  '';

  phase2a-kiro-settings-telemetry = pkgs.runCommand "phase2a-kiro-settings-telemetry" {} ''
    ${
      if !phase2aKiroFixture.config.programs.kiro-cli.settings.telemetry.enabled
      then "echo ok > $out"
      else "echo 'FAIL: ai.settings.telemetry did not remap to programs.kiro-cli.settings.telemetry.enabled' >&2; exit 1"
    }
  '';

  phase2a-kiro-lsp-fanout = pkgs.runCommand "phase2a-kiro-lsp-fanout" {} ''
    ${
      if phase2aKiroFixture.config.programs.kiro-cli.lspServers ? nixd
      then "echo ok > $out"
      else "echo 'FAIL: ai.lspServers.nixd did not reach programs.kiro-cli.lspServers' >&2; exit 1"
    }
  '';
}

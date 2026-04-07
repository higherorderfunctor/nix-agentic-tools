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
          copilot.enable = true;
          kiro.enable = true;
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
      then "echo ok > $out"
      else "echo 'FAIL: ai module not self-contained — importing homeManagerModules.ai alone did not bring in copilot-cli/kiro-cli modules' >&2; exit 1"
    }
  '';
}

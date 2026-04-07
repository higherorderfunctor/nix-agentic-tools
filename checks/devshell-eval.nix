# DevShell module evaluation tests.
# Verifies mkAgenticShell produces valid shells for representative configs,
# and that the devenv ai.* fanout modules evaluate to the expected on-disk
# layout (Layout B per-file entries, not Layout A single dir symlinks).
{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (self.lib) mkAgenticShell;

  # Test: minimal shell (no options)
  minimalShell = mkAgenticShell pkgs {
    name = "test-minimal";
  };

  # Test: shell with MCP servers
  mcpShell = mkAgenticShell pkgs {
    name = "test-mcp";
    mcpServers.test-server = {
      enable = true;
      command = "echo";
      args = ["hello"];
    };
  };

  # Test: shell with skills
  skillsShell = mkAgenticShell pkgs {
    name = "test-skills";
    skills.stacked-workflows.enable = true;
  };

  # Test: ai.skills devenv fanout produces Layout B (per-file entries).
  # Imports the devenv ai module + the claude-code-skills extension and
  # stubs the rest of the devenv interface (files, env, claude.code.*)
  # so the fanout can evaluate without pulling in upstream devenv. Then
  # asserts that a per-file path key (.claude/skills/<name>/SKILL.md)
  # is present on `config.files` — the signature of the walker-driven
  # Layout B output. A regression that re-introduced direct
  # `files.".claude/skills/<name>".source = <dir>` writes would produce
  # a single dir-shaped key instead and trip the assertion.
  aiSkillsLayout = lib.evalModules {
    modules = [
      self.devenvModules.ai
      self.devenvModules.claude-code-skills
      self.devenvModules.copilot
      self.devenvModules.kiro
      ({lib, ...}: {
        # Stub the slice of the devenv module interface our modules
        # touch. `files` and `env` are devenv-native; `claude.code.*`
        # is the upstream devenv claude module (not imported here).
        options = {
          env = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
          };
          files = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = {};
          };
          claude.code = {
            enable = lib.mkEnableOption "claude.code (stub)";
            env = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
            };
            model = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
          };
        };
      })
      {
        config._module.args = {inherit pkgs;};
        config.ai = {
          claude.enable = true;
          skills.test-skill = ../packages/stacked-workflows/skills/stack-fix;
        };
      }
    ];
  };
in {
  devshell-minimal = pkgs.runCommand "devshell-minimal" {} ''
    echo "minimal shell: ${minimalShell.name}" > $out
  '';

  devshell-mcp = pkgs.runCommand "devshell-mcp" {} ''
    echo "mcp shell: ${mcpShell.name}" > $out
  '';

  devshell-skills = pkgs.runCommand "devshell-skills" {} ''
    echo "skills shell: ${skillsShell.name}" > $out
  '';

  devenv-skills-layout-eval = pkgs.runCommand "devenv-skills-layout-eval" {} ''
    ${
      if aiSkillsLayout.config.files ? ".claude/skills/test-skill/SKILL.md"
      then "echo ok > $out"
      else "echo 'FAIL: ai.skills devenv fanout did not produce Layout B entries' >&2; exit 1"
    }
  '';
}

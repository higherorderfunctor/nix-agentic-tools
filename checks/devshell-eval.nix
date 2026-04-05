# DevShell module evaluation tests.
# Verifies mkAgenticShell produces valid shells for representative configs.
{
  lib,
  pkgs,
  self,
}: let
  mkAgenticShell = self.lib.mkAgenticShell;

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
}

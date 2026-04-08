# Copilot CLI ecosystem record.
#
# Phase 1 scope: only markdownTransformer is consumed via the
# back-compat shim. Other fields scaffolded for Phase 2.
{lib}: let
  fragments = import ../fragments.nix {inherit lib;};
  base = import ../transformers/base.nix {inherit lib;};
  inherit (fragments) mkFrontmatter;

  copilotFrontmatter = {paths ? null, ...}: let
    applyTo =
      if paths == null
      then ''"**"''
      else if builtins.isList paths
      then ''"${lib.concatStringsSep "," paths}"''
      else paths;
  in
    mkFrontmatter {inherit applyTo;} + "\n";
in {
  name = "copilot";

  markdownTransformer = lib.recursiveUpdate base {
    name = "copilot";
    handlers =
      base.handlers
      // {
        link = _ctx: node: "[${node.label or node.target}](${node.target})";
        include = ctx: node: ctx.render {text = builtins.readFile node.path;};
      };
    frontmatter = copilotFrontmatter;
  };

  package = null; # adapter supplies pkgs.github-copilot-cli default
  configDir = ".github";

  translators = {
    # Identity-style translators (see claude.nix for the rationale
    # — every category dispatches through a translator so divergent
    # shapes have a home).
    skills = _name: path: path;
    instructions = _name: instr: instr;

    settings = sharedSettings:
      lib.optionalAttrs (sharedSettings.model != null) {
        inherit (sharedSettings) model;
      };
    lspServer = _name: server: {
      inherit (server) name extensions;
      command = "${server.package}/bin/${server.binary or server.name}";
    };
    envVar = name: value: {${name} = value;};
    mcpServer = _name: server:
      (removeAttrs server ["disabled" "enable"])
      // (lib.optionalAttrs (server ? url) {type = "http";})
      // (lib.optionalAttrs (server ? command) {type = "stdio";});
  };

  layout = {
    instructionPath = name: ".github/instructions/${name}.instructions.md";
    skillPath = name: ".github/skills/${name}";
    settingsPath = ".copilot/settings.json";
    lspConfigPath = ".copilot/lsp.json";
    mcpConfigPath = ".copilot/mcp.json";
  };

  upstream = {
    hm = {
      enableOption = "programs.copilot-cli.enable";
      skillsOption = "programs.copilot-cli.skills";
      mcpServersOption = null;
      lspServersOption = "programs.copilot-cli.lspServers";
      settingsOption = "programs.copilot-cli.settings";
    };
    devenv = {
      enableOption = "copilot.enable";
      skillsOption = "copilot.skills";
      mcpServersOption = null;
      lspServersOption = "copilot.lspServers";
      settingsOption = "copilot.settings";
    };
  };

  extraOptions = _: {};
}

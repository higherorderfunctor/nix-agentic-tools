# Kiro CLI ecosystem record.
#
# Phase 1 scope: only markdownTransformer is consumed via the
# back-compat shim. Other fields scaffolded for Phase 2.
{lib}: let
  fragments = import ../fragments.nix {inherit lib;};
  base = import ../transformers/base.nix {inherit lib;};
  inherit (fragments) mkFrontmatter;

  # Kiro frontmatter — preserves all the inclusion / fileMatchPattern
  # / description-resolution logic from
  # packages/fragments-ai/default.nix transforms.kiro.
  kiroFrontmatter = {
    description ? null,
    paths ? null,
    name,
    ...
  }: let
    inclusion =
      if paths != null
      then "fileMatch"
      else "always";
    patternStr =
      if paths == null
      then null
      else if builtins.isList paths
      then
        if builtins.length paths == 1
        then ''"${builtins.head paths}"''
        else "[" + lib.concatMapStringsSep ", " (p: ''"${p}"'') paths + "]"
      else paths;
    descStr =
      if description != null && description != ""
      then description
      else if description == null
      then
        if paths == null
        then "Shared coding standards and conventions"
        else "Instructions for the ${name} package"
      else null;
    fm =
      {
        inherit inclusion name;
      }
      // lib.optionalAttrs (descStr != null) {description = descStr;}
      // lib.optionalAttrs (patternStr != null) {fileMatchPattern = patternStr;};
  in
    mkFrontmatter fm + "\n";
in {
  name = "kiro";

  markdownTransformer = lib.recursiveUpdate base {
    name = "kiro";
    handlers =
      base.handlers
      // {
        link = _ctx: node: "#[[file:${node.target}]]";
        include = ctx: node: ctx.render {text = builtins.readFile node.path;};
      };
    frontmatter = kiroFrontmatter;
  };

  package = null; # adapter supplies pkgs.kiro-cli default
  configDir = ".kiro";

  translators = {
    # Identity-style translators (see claude.nix for the rationale
    # — every category dispatches through a translator so divergent
    # shapes have a home).
    skills = _name: path: path;
    instructions = _name: instr: instr;

    settings = sharedSettings:
      lib.mkMerge [
        (lib.optionalAttrs (sharedSettings.model != null) {
          chat.defaultModel = sharedSettings.model;
        })
        (lib.optionalAttrs (sharedSettings.telemetry != null) {
          telemetry.enabled = sharedSettings.telemetry;
        })
      ];
    lspServer = _name: server: {
      inherit (server) name;
      command = "${server.package}/bin/${server.binary or server.name}";
      filetypes = server.extensions;
    };
    envVar = name: value: {${name} = value;};
    mcpServer = _name: server:
      (removeAttrs server ["disabled" "enable"])
      // (lib.optionalAttrs (server ? url) {type = "http";})
      // (lib.optionalAttrs (server ? command) {type = "stdio";});
  };

  layout = {
    instructionPath = name: ".kiro/steering/${name}.md";
    skillPath = name: ".kiro/skills/${name}";
    settingsPath = ".kiro/settings/cli.json";
    lspConfigPath = ".kiro/lsp.json";
    mcpConfigPath = ".kiro/mcp.json";
  };

  upstream = {
    hm = {
      enableOption = "programs.kiro-cli.enable";
      skillsOption = "programs.kiro-cli.skills";
      mcpServersOption = null;
      lspServersOption = "programs.kiro-cli.lspServers";
      settingsOption = "programs.kiro-cli.settings";
    };
    devenv = {
      enableOption = "kiro.enable";
      skillsOption = "kiro.skills";
      mcpServersOption = null;
      lspServersOption = "kiro.lspServers";
      settingsOption = "kiro.settings";
    };
  };

  extraOptions = _: {};
}

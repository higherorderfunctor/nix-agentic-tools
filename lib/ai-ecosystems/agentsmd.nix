# AGENTS.md ecosystem record.
#
# Trivial passthrough — no frontmatter, no link/include rewriting.
# AGENTS.md is the cross-tool standard format with no scoping
# primitives. Phase 2's adapter will use this record for the
# AGENTS.md output target.
{lib}: let
  base = import ../transformers/base.nix {inherit lib;};
in {
  name = "agentsmd";

  markdownTransformer = lib.recursiveUpdate base {
    name = "agentsmd";
    handlers =
      base.handlers
      // {
        link = _ctx: node: "[${node.label or node.target}](${node.target})";
        include = ctx: node: ctx.render {text = builtins.readFile node.path;};
      };
    # frontmatter inherits base (empty string)
  };

  package = null;
  configDir = "."; # AGENTS.md lives at repo root

  translators = {
    # AGENTS.md is a single flat file with no skills/settings/etc.
    # All translators are no-ops, but the slots exist so the
    # adapter dispatches uniformly without special-casing AGENTS.md.
    skills = _name: _path: {};
    instructions = _name: instr: instr;
    settings = _: {};
    lspServer = _: _: {};
    envVar = null;
    mcpServer = _: _: {};
  };

  layout = {
    instructionPath = _name: "AGENTS.md";
    skillPath = _: null;
    settingsPath = null;
    lspConfigPath = null;
    mcpConfigPath = null;
  };

  upstream = {
    hm = {
      enableOption = null;
      skillsOption = null;
      mcpServersOption = null;
      lspServersOption = null;
      settingsOption = null;
    };
    devenv = {
      enableOption = null;
      skillsOption = null;
      mcpServersOption = null;
      lspServersOption = null;
      settingsOption = null;
    };
  };

  extraOptions = _: {};
}

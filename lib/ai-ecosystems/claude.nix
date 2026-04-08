# Claude ecosystem record.
#
# Phase 1 scope: only the markdownTransformer field is consumed
# (via the back-compat shim in packages/fragments-ai/default.nix).
# Other fields (translators, layout, upstream, extraOptions) are
# scaffolded for Phase 2's backend adapters. Filling them in here
# now means Phase 2 doesn't need to re-shape the record.
#
# Byte-identity contract: markdownTransformer must produce output
# byte-identical to the current packages/fragments-ai/default.nix
# transforms.claude function. Verified by the snapshot diff in the
# commit 3 verification step.
{lib}: let
  base = import ../transformers/base.nix {inherit lib;};

  # Claude frontmatter — preserves the resolution rules from
  # packages/fragments-ai/default.nix transforms.claude:
  #   - description: non-empty explicit > "Instructions for the X
  #     package" if paths set > omit if paths null and desc null
  #   - paths: list -> YAML list, string -> bare string, null -> omit
  claudeFrontmatter = {
    description ? null,
    paths ? null,
    package,
    ...
  }: let
    hasPaths = paths != null;
    desc =
      if description != null && description != ""
      then description
      else if hasPaths && description == null
      then "Instructions for the ${package} package"
      else null;
    descYaml =
      if desc != null
      then "description: ${desc}\n"
      else "";
    pathsYaml =
      if paths == null
      then ""
      else if builtins.isList paths
      then "paths:\n" + lib.concatMapStringsSep "\n" (p: "  - \"${p}\"") paths + "\n"
      else "paths: ${paths}\n";
  in
    if descYaml == "" && pathsYaml == ""
    then ""
    else "---\n" + descYaml + pathsYaml + "---\n\n";
in {
  name = "claude";

  # Phase 1: only markdownTransformer is consumed.
  markdownTransformer = lib.recursiveUpdate base {
    name = "claude";
    handlers =
      base.handlers
      // {
        # Phase 1: link/include handlers exist for completeness
        # but the back-compat shim path that uses this transformer
        # passes whole rendered text through, so these handlers
        # only fire for fragments authored as node lists. Existing
        # flat-string fragments don't trigger them.
        link = _ctx: node: "@${node.target}";
        include = ctx: node: ctx.render {text = builtins.readFile node.path;};
      };
    frontmatter = claudeFrontmatter;
  };

  # ── Phase 2 scaffolding ──────────────────────────────────────────
  # The fields below are placeholders that Phase 2's backend
  # adapters will consume. They're filled in now so the record
  # shape is complete.

  package = null; # adapter supplies pkgs.claude-code default
  configDir = ".claude";

  translators = {
    # Skills: identity-style translation. Abstract type (path)
    # maps 1:1 to the ecosystem's expected shape today, but the
    # translator slot exists so divergent ecosystems (e.g., a
    # future programs.copilot.skills.<name>.recursive flag) can
    # override without forcing the adapter to special-case
    # skills passthrough.
    skills = _name: path: path;

    # Instructions: identity-style translation of the abstract
    # submodule shape. Markdown body rendering happens separately
    # via markdownTransformer; this translator only handles
    # option-shape translation, not content rendering.
    instructions = _name: instr: instr;

    # Translates ai.settings.{model, telemetry} to claude shape.
    settings = sharedSettings:
      lib.optionalAttrs (sharedSettings.model != null) {
        inherit (sharedSettings) model;
      };
    # Translates ai.lspServers.<name> to claude LSP entry shape.
    lspServer = _name: server: {
      inherit (server) name;
      command = "${server.package}/bin/${server.binary or server.name}";
      filetypes = server.extensions;
    };
    # Translates ai.environmentVariables — claude doesn't expose
    # env vars through programs.claude-code, so the translator
    # returns null to signal "skip this category for this ecosystem".
    envVar = null;
    # Translates ai.mcpServers.<name> to claude MCP entry shape.
    mcpServer = _name: server:
      (removeAttrs server ["disabled" "enable"])
      // (lib.optionalAttrs (server ? url) {type = "http";})
      // (lib.optionalAttrs (server ? command) {type = "stdio";});
  };

  layout = {
    instructionPath = name: ".claude/rules/${name}.md";
    skillPath = name: ".claude/skills/${name}";
    settingsPath = ".claude/settings.json";
    lspConfigPath = ".claude/lsp.json";
    mcpConfigPath = ".claude/mcp.json";
  };

  upstream = {
    hm = {
      enableOption = "programs.claude-code.enable";
      skillsOption = "programs.claude-code.skills";
      mcpServersOption = "programs.claude-code.mcpServers";
      lspServersOption = null;
      settingsOption = "programs.claude-code.settings";
    };
    devenv = {
      enableOption = "claude.code.enable";
      skillsOption = "claude.code.skills";
      mcpServersOption = "claude.code.mcpServers";
      lspServersOption = null;
      settingsOption = null;
    };
  };

  # Phase 2's mkAiEcosystemHmModule will merge these into the
  # per-ecosystem submodule type. Phase 1 doesn't use them.
  extraOptions = {lib, ...}: {
    buddy = lib.mkOption {
      type = lib.types.nullOr (import ../buddy-types.nix {inherit lib;}).buddySubmodule;
      default = null;
      description = ''
        Buddy companion customization. Consumed by Phase 2's
        adapter; in Phase 1 this option is declared but the fanout
        still happens via modules/ai/default.nix's existing
        mkIf cfg.claude.buddy != null branch.
      '';
    };
  };
}

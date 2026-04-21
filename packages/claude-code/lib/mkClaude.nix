# Claude-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Claude AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Fanout (skills, mcpServers, instructions files) absorbed in
# Task 3 (A2).
{
  lib,
  pkgs,
  ...
}:
lib.ai.app.mkAiApp {
  name = "claude";
  transformers.markdown = lib.ai.transformers.claude;
  defaults = {
    package = pkgs.ai.claude-code;
    outputPath = ".claude/CLAUDE.md";
  };
  # Shared options (present in both backends)
  options = {
    context = lib.mkOption {
      type = lib.types.either lib.types.lines lib.types.path;
      default = "";
      description = ''
        Global Claude context. Inline string or path to a file.
        Passed through to programs.claude-code.context (which writes
        to ~/.claude/CLAUDE.md). Replaces the deprecated upstream
        `memory.text` option.
      '';
      example = lib.literalExpression "./claude-memory.md";
    };
    plugins = lib.mkOption {
      type = with lib.types; listOf (either package path);
      default = [];
      description = ''
        Claude plugin directories or packages. Each entry is either
        a path to a plugin directory or a package derivation. Passed
        through to programs.claude-code.plugins; each produces a
        --plugin-dir argument in the claude wrapper.
      '';
    };
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = ''
        Freeform settings merged into programs.claude-code.settings
        (written to ~/.claude/settings.json by upstream).
      '';
    };
  };
  # HM-specific projection
  hm = {
    options = {};
    config = {
      cfg,
      mergedServers,
      mergedInstructions,
      mergedSkills,
      mergedRules,
      topContext,
    }: let
      # Resolve effective context: per-CLI wins when set (non-empty);
      # else top-level `ai.context`; else empty (upstream default).
      effectiveContext =
        if cfg.context != ""
        then cfg.context
        else if topContext != null
        then topContext
        else "";

      # Resolve rule body: path → readFile; string → passthrough.
      resolveRuleText = rule:
        if builtins.isPath rule.text
        then builtins.readFile rule.text
        else rule.text;
    in
      lib.mkMerge [
        # Delegate to upstream programs.claude-code.* where upstream
        # provides the capability. mkDefault lets consumers override.
        {
          programs.claude-code = {
            enable = lib.mkDefault true;
            package = lib.mkDefault cfg.package;
            skills = lib.mapAttrs (_: lib.mkDefault) mergedSkills;
            context = lib.mkDefault effectiveContext;
            plugins = lib.mkDefault cfg.plugins;
            inherit (cfg) settings;
            # Render typed ai.mcpServers / ai.claude.mcpServers entries
            # into the freeform shape upstream's HM module expects.
            mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
          };
        }
        # Per-instruction rule files — write .claude/rules/<name>.md
        # for each instruction entry that carries a `name` field. This
        # is a gap in upstream programs.claude-code (no per-rule file
        # option), so we write home.file directly. Entries without a
        # `name` field flow only into the baseline aggregated render
        # at .claude/CLAUDE.md (handled by hmTransform's baseline).
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
          named = builtins.filter (i: i ? name) mergedInstructions;
        in {
          home.file = lib.listToAttrs (map (instr: {
              name = ".claude/rules/${instr.name}.md";
              value.text = fragmentsLib.mkRenderer claudeTransformer {package = instr.name;} instr;
            })
            named);
        })
        # Attrs-shape ai.rules / ai.claude.rules → .claude/rules/<name>.md.
        # Each entry becomes one file, translated through claudeTransformer
        # (paths: frontmatter). Parallel emission to the legacy instructions
        # path above; name collisions between the two would raise a
        # home.file conflict at eval time (intentional — user fix).
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
        in {
          home.file = lib.mapAttrs' (name: rule:
            lib.nameValuePair ".claude/rules/${name}.md" {
              text = fragmentsLib.mkRenderer claudeTransformer {package = name;} (rule
                // {
                  text = resolveRuleText rule;
                });
            })
          mergedRules;
        })
        # Auto-set ENABLE_LSP_TOOL=1 when MCP servers are present.
        # Mirrors the legacy modules/ai/default.nix behavior where
        # any populated server pool implied LSP-tool wiring.
        (lib.mkIf (mergedServers != {}) {
          programs.claude-code.settings.env.ENABLE_LSP_TOOL = lib.mkDefault "1";
        })
      ];
  };
  # Devenv-specific projection
  devenv = {
    options = {};
    # `...` absorbs extra args passed by devenvTransform that this
    # backend doesn't need (e.g. topContext — Claude delegates context
    # writing to upstream claude.code, no gap-write here).
    config = {
      cfg,
      mergedServers,
      mergedInstructions,
      mergedSkills,
      mergedRules,
      ...
    }: let
      resolveRuleText = rule:
        if builtins.isPath rule.text
        then builtins.readFile rule.text
        else rule.text;
    in
      lib.mkMerge [
        # Delegate to upstream devenv claude.code.* where upstream
        # provides the capability.
        {
          claude.code = {
            enable = lib.mkDefault true;
            mcpServers = mergedServers;
            env = cfg.settings.env or {};
          };
        }
        # Gap writes — per-instruction rule files. devenv has no
        # per-rule option, so we write files.* directly. Entries
        # without a `name` field flow into the baseline aggregate
        # render at .claude/CLAUDE.md (handled by devenvTransform).
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
          named = builtins.filter (i: i ? name) mergedInstructions;
        in {
          files = lib.listToAttrs (map (instr: {
              name = ".claude/rules/${instr.name}.md";
              value.text = fragmentsLib.mkRenderer claudeTransformer {package = instr.name;} instr;
            })
            named);
        })
        # Attrs-shape ai.rules / ai.claude.rules → .claude/rules/<name>.md.
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
        in {
          files = lib.mapAttrs' (name: rule:
            lib.nameValuePair ".claude/rules/${name}.md" {
              text = fragmentsLib.mkRenderer claudeTransformer {package = name;} (rule
                // {
                  text = resolveRuleText rule;
                });
            })
          mergedRules;
        })
        # Skills — devenv has no upstream skills option on
        # claude.code (cachix/devenv#2441), so we write per-leaf
        # files.* entries via the mkDevenvSkillEntries walker. The
        # walker mirrors HM `recursive = true` in user space because
        # devenv `files.*.source` cannot recurse a directory itself.
        (let
          helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
        in {
          files = helpers.mkDevenvSkillEntries ".claude" mergedSkills;
        })
      ];
  };
}

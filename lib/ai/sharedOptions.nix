# Declares cross-app options (ai.context, ai.mcpServers, ai.instructions,
# ai.rules, ai.skills).
#
# Imported by every mkAiApp module so per-app overrides
# (ai.<name>.mcpServers, etc.) can merge on top of these top-level
# pools. Per-app values win on key conflicts; lists are concatenated.
{
  config,
  lib,
  ...
}: let
  aiCommon = import ./ai-common.nix {inherit lib;};
  dirHelpers = import ./dir-helpers.nix {inherit lib;};
in {
  options.ai = {
    context = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.lines lib.types.path);
      default = null;
      description = ''
        Cross-app global context (single always-on file) fanned out to every
        enabled AI app. Each ecosystem emits it at its native location:
        Claude → ~/.claude/CLAUDE.md, Kiro → ~/.kiro/steering/<contextFilename>
        (default AGENTS.md). Per-app overrides (ai.<name>.context) win when set.
      '';
      example = lib.literalExpression "./ai-context.md";
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submoduleWith {
        modules = [(import ./mcpServer/commonSchema.nix)];
      });
      default = {};
      description = ''
        MCP servers fanned out to every enabled AI app. Per-app overrides
        (ai.<name>.mcpServers) merge on top and win on conflict.
      '';
    };

    instructions = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = "Cross-app instructions fanned out to every enabled AI app.";
    };

    rules = lib.mkOption {
      type = lib.types.attrsOf aiCommon.ruleModule;
      default = {};
      description = ''
        Cross-app modular rule files fanned out to every enabled AI app.
        Each attribute becomes one file in the ecosystem's native rules
        directory (Claude: `.claude/rules/<name>.md`, Kiro:
        `.kiro/steering/<name>.md`, Copilot:
        `.github/instructions/<name>.instructions.md`). Per-app overrides
        (ai.<name>.rules) merge on top; collisions are a failure.
      '';
      example = lib.literalExpression ''
        {
          code-style = { text = "Use consistent formatting."; };
          testing = {
            text = ./rules/testing.md;
            paths = [ "**/*.test.*" ];
            description = "Testing conventions";
          };
        }
      '';
    };

    rulesDir = lib.mkOption {
      type = lib.types.nullOr aiCommon.dirOptionType;
      default = null;
      description = ''
        Directory of `.md` rule files fanned out to every enabled AI app.
        Each file becomes one entry in `ai.rules` keyed by the basename
        minus `.md`. Collisions with explicit `ai.rules.<name>` entries
        (or with `ai.<cli>.rules`) fail via the shared collision check.
        Accepts either a Nix path literal or `{ path, filter? }` where
        `filter : name → bool` (default: keep `.md` files). The source
        directory is NOT taken over wholesale — other derivations can
        still contribute to the same ecosystem rules dir via
        `home.file.*` / `files.*` without conflict.
      '';
      example = lib.literalExpression ''
        ./rules                                  # keep defaults
        # or
        {
          path = ./rules;
          filter = name: !(lib.hasSuffix ".bk" name);
        }
      '';
    };

    lspServers = lib.mkOption {
      type = lib.types.attrsOf aiCommon.lspServerModule;
      default = {};
      description = ''
        Typed LSP server declarations fanned out to every enabled AI app.
        Each per-ecosystem translator renders the native JSON shape on
        emission (Kiro: command/args; Copilot: + fileExtensions;
        Claude: + extensionToLanguage). Per-app overrides
        (ai.<name>.lspServers) merge on top and win on conflict.
      '';
    };

    agents = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = {};
      description = ''
        Markdown+frontmatter agent definitions fanned out to Claude
        and Copilot. Each entry becomes a file:
        - Claude  → ~/.claude/agents/<name>.md
        - Copilot → .github/agents/<name>.agent.md (devenv) or
                    ~/.copilot/agents/<name>.agent.md (HM)
        Kiro intentionally excluded — Kiro's agent format is JSON
        with different semantic fields; use `ai.kiro.agents`
        directly for that ecosystem. Per-app overrides
        (ai.<cli>.agents) merge on top and win on conflict.
      '';
    };

    environmentVariables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Environment variables fanned out to every enabled AI app that
        supports a wrapper/env surface (Kiro, Copilot). Per-app overrides
        (ai.<name>.environmentVariables) merge on top and win on conflict.
        Claude does NOT currently consume this pool — Claude env vars
        should be set via `ai.claude.settings.env` instead (upstream
        writes them into `~/.claude/settings.json`).
      '';
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      description = "Cross-app skills fanned out to every enabled AI app.";
    };
  };

  # L1 → L2 fanout: expand `ai.rulesDir` into per-file entries
  # on `ai.rules`. mkDefault priority lets explicit `ai.rules.<name>`
  # contributions override (this is the L1→L2 fanout specifically,
  # not a collision; collisions are handled at the L2↔L3 boundary
  # by the factory's mergeWithCollisionCheck helper).
  #
  # Emission logic lives at L4 inside each per-CLI factory. This
  # layer only reshapes the L1 Dir option into L2 per-file entries.
  config.ai.rules = lib.mkIf (config.ai.rulesDir != null) (
    lib.mapAttrs (_: lib.mkDefault) (dirHelpers.rulesFromDir config.ai.rulesDir)
  );
}

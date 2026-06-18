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
}: let
  # Eval-pure reads of COMMITTED source JSON (no IFD). See overlays.md
  # § IFD Patterns and memory project_claude_effort_pin_state.
  extracted =
    builtins.fromJSON (builtins.readFile ../../../overlays/claude-code-extracted.json);
  knownClaudeModels =
    builtins.fromJSON (builtins.readFile ../models.json);
in
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
        type = lib.types.submodule {
          freeformType = (pkgs.formats.json {}).type;
          options = {
            effortLevel = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum extracted.effortLevels);
              default = null;
              description = ''
                Persisted Claude effort level. The valid set
                (low/medium/high/xhigh) is extracted from the packaged binary
                into overlays/claude-code-extracted.json. 'max' is session-only
                via /effort and cannot be persisted.
              '';
            };
            model = lib.mkOption {
              type =
                lib.types.nullOr
                (lib.types.either (lib.types.enum knownClaudeModels) lib.types.str);
              default = null;
              description = ''
                Claude model id. Known ids (packages/claude-code/models.json)
                autocomplete; any string is accepted (non-enforcing soft enum) —
                the binary's runtime model set is not a safe closed enum.
              '';
            };
          };
        };
        default = {};
        description = ''
          Typed Claude settings (effortLevel, model) plus freeform passthrough,
          written to ~/.claude/settings.json by upstream. Null typed keys are
          filtered out before reaching upstream.
        '';
      };
      unpinLaunchEffort = lib.mkOption {
        type = lib.types.attrsOf lib.types.bool;
        default = lib.genAttrs extracted.launchEffortPins (_: true);
        defaultText =
          lib.literalExpression
          "lib.genAttrs extracted.launchEffortPins (_: true)";
        description = ''
          Per-model "acknowledge launch-default effort" flags merged into
          ~/.claude.json (HM only) so settings.effortLevel is honored instead of
          a newly-shipped model's launch-default effort pin. Keys are
          auto-derived from the packaged binary
          (overlays/claude-code-extracted.json). Set a key false to deliberately
          leave that model pinned.
        '';
      };
      lspServers = lib.mkOption {
        type = lib.types.attrsOf (import ../../../lib/ai/ai-common.nix {inherit lib;}).lspServerModule;
        default = {};
        description = ''
          Typed Claude-specific LSP server declarations. Merged with
          top-level `ai.lspServers`; per-CLI wins on name conflict.
          Translated via `mkClaudeLspConfig` to
          `programs.claude-code.lspServers`, which upstream writes into
          `~/.claude/settings.json`. Extensions list becomes
          `extensionToLanguage` mapping. Upstream devenv `claude.code`
          has no LSP surface — devenv ignores this option.
        '';
      };
      marketplaces = lib.mkOption {
        type = with lib.types; attrsOf (either package path);
        default = {};
        description = ''
          Claude plugin marketplaces. Each entry is either a path to a
          marketplace directory or a package derivation. Routed to
          programs.claude-code.marketplaces; upstream writes them into
          ~/.claude/settings.json under extraKnownMarketplaces.
        '';
        example = lib.literalExpression ''
          {
            my-marketplace = ./my-marketplace;
          }
        '';
      };
      outputStyles = lib.mkOption {
        type = with lib.types; attrsOf (either lines path);
        default = {};
        description = ''
          Claude custom output styles. Attribute name becomes the style
          filename stem; value is inline markdown or a path to a .md
          file. Routed to programs.claude-code.outputStyles; upstream
          writes them under ~/.claude/output-styles/<name>.md.
        '';
        example = lib.literalExpression ''
          {
            concise = "Keep answers under 3 sentences.";
            tutorial = ./styles/tutorial.md;
          }
        '';
      };
      agents = lib.mkOption {
        type = with lib.types; attrsOf (either lines path);
        default = {};
        description = ''
          Claude-specific agent markdown (merged with top-level
          `ai.agents`; collisions fail). Routed to
          `programs.claude-code.agents`; upstream writes them under
          `~/.claude/agents/<name>.md`. HM only — upstream devenv
          `claude.code` has no agents surface.
        '';
      };
      agentsDir = lib.mkOption {
        type = lib.types.nullOr (import ../../../lib/ai/ai-common.nix {inherit lib;}).dirOptionType;
        default = null;
        description = ''
          Claude-specific directory of `.md` agent files. Each file
          becomes one entry in `ai.claude.agents` keyed by basename
          minus `.md`. Accepts a path literal or
          `{ path, filter? }` (filter: name → bool, default keeps
          `.md`).
        '';
      };
      commands = lib.mkOption {
        type = with lib.types; attrsOf (either lines path);
        default = {};
        description = ''
          Claude custom slash-commands. Attribute name becomes the
          command filename stem; value is inline markdown or a path
          to a .md file. Routed to `programs.claude-code.commands`;
          upstream writes them under `~/.claude/commands/<name>.md`.
          Claude-only — Kiro and Copilot have no analogous command
          concept, so no top-level `ai.commands` fanout.
        '';
        example = lib.literalExpression ''
          {
            fix-issue = ./commands/fix-issue.md;
          }
        '';
      };
      hooks = lib.mkOption {
        type = lib.types.attrsOf lib.types.lines;
        default = {};
        description = ''
          Claude hook shell scripts. Attribute name becomes the hook
          filename; value is the script body. Routed to
          `programs.claude-code.hooks` (HM) and merged into
          `claude.code.hooks` (devenv, where existing
          `settings.hooks` continues to work for backward compat but
          this option is the authoritative route going forward).
          Claude-only — Kiro's `ai.kiro.hooks` takes JSON-shaped hook
          definitions (different file format, different semantics),
          so no top-level `ai.hooks` fanout.
        '';
        example = lib.literalExpression ''
          { pre-edit = "#!/usr/bin/env bash\nexec :\n"; }
        '';
      };
      hooksDir = lib.mkOption {
        type = lib.types.nullOr (import ../../../lib/ai/ai-common.nix {inherit lib;}).dirOptionType;
        default = null;
        description = ''
          Claude-specific directory of hook scripts. Each regular
          file becomes one entry in `ai.claude.hooks` keyed by the
          filename (no extension strip — Claude hooks are typically
          extensionless shell scripts). Accepts a path literal or
          `{ path, filter? }` (filter: name → bool, default
          accepts every regular file). Claude-only — no top-level
          `ai.hooksDir` fanout since hooks are Claude-specific.
        '';
        example = lib.literalExpression ''./hooks'';
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
        mergedLspServers,
        mergedClaudeCopilotAgents,
        topContext,
        ...
      }: let
        aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
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
        dirHelpers = import ../../../lib/ai/dir-helpers.nix {inherit lib;};
        helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
      in
        lib.mkMerge [
          # L2b → L3: expand `ai.claude.agentsDir` into per-CLI
          # `ai.claude.agents`. mkDefault lets explicit
          # `ai.claude.agents.<name>` entries win within this layer;
          # collisions with `ai.agents.<name>` still go through the
          # shared collision check in the transform.
          (lib.mkIf (cfg.agentsDir != null) {
            ai.claude.agents = lib.mapAttrs (_: lib.mkDefault) (
              dirHelpers.agentsFromDir cfg.agentsDir
            );
          })
          # L2b → L3: expand `ai.claude.hooksDir` into
          # `ai.claude.hooks`. Content is `readFile`'d into
          # `lib.types.lines` via hooksFromDir.
          (lib.mkIf (cfg.hooksDir != null) {
            ai.claude.hooks = lib.mapAttrs (_: lib.mkDefault) (
              dirHelpers.hooksFromDir cfg.hooksDir
            );
          })
          # Delegate to upstream programs.claude-code.* where upstream
          # provides the capability. mkDefault lets consumers override.
          {
            programs.claude-code = {
              enable = lib.mkDefault true;
              package = lib.mkDefault cfg.package;
              skills = lib.mapAttrs (_: lib.mkDefault) mergedSkills;
              context = lib.mkDefault effectiveContext;
              plugins = lib.mkDefault cfg.plugins;
              inherit (cfg) marketplaces outputStyles commands hooks;
              lspServers = lib.mapAttrs aiCommon.mkClaudeLspConfig mergedLspServers;
              agents = mergedClaudeCopilotAgents;
              # Typed settings (effortLevel, model) plus freeform
              # passthrough. Null-filter the typed keys so upstream never
              # receives `effortLevel = null` / `model = null`; arbitrary
              # non-typed keys (permissions, env, outputStyle, …) pass
              # through the submodule's freeform JSON type unchanged.
              settings = aiCommon.filterNulls cfg.settings;
              # Render typed ai.mcpServers / ai.claude.mcpServers entries
              # into the freeform shape upstream's HM module expects.
              mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
            };
          }
          # Reconcile per-model launch-effort unpin flags into ~/.claude.json
          # so settings.effortLevel is honored instead of a newly-shipped
          # model's launch-default pin. HM-only — devenv never touches $HOME
          # (documented category exception). The log line is unconditional so
          # an emptied flag map is visible ("reconciling 0 …"); the merge body
          # is included only when there are flags. Never `exit` here — the
          # block inlines into HM's set -eu activation script. See memory
          # project_claude_effort_pin_state + feedback_hm_activation_exit.
          (let
            n = builtins.length (builtins.attrNames cfg.unpinLaunchEffort);
          in {
            home.activation.claudeUnpinLaunchEffort = lib.hm.dag.entryAfter ["writeBoundary"] (
              ''
                echo "ai.claude: reconciling ${toString n} launch-effort unpin flag(s) into ~/.claude.json"
              ''
              + lib.optionalString (n > 0) (helpers.mkSettingsActivationScript {
                configFile = ".claude.json";
                settingsJson = builtins.toJSON cfg.unpinLaunchEffort;
                jq = "${pkgs.jq}/bin/jq";
                inherit (pkgs) coreutils;
              })
            );
          })
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
        aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
        dirHelpers = import ../../../lib/ai/dir-helpers.nix {inherit lib;};
        resolveRuleText = rule:
          if builtins.isPath rule.text
          then builtins.readFile rule.text
          else rule.text;

        # Translate cfg.settings → backend surfaces.
        #
        # - `hooks` routes to upstream `claude.code.hooks` since upstream
        #   already writes them into settings.json.
        # - `mcpServers` belongs in `.mcp.json`, not settings.json;
        #   filtered out defensively in case a user mis-assigns it
        #   (the authoritative path is the top-level ai.mcpServers pool).
        # - Everything else (effortLevel, permissions, env, outputStyle,
        #   …) is gap-written directly to `.claude/settings.json`.
        #
        # Pin settingsPath so our relative-key gap write and upstream's
        # own write hit the same `files.*` attr and the module system
        # deep-merges them into one settings.json. Upstream's default is
        # `${devenv.root}/.claude/settings.json` (absolute) which would
        # otherwise produce a separate files.* entry.
        upstreamOwnedSettingsKeys = ["hooks" "mcpServers"];
        gapSettings =
          aiCommon.filterNulls
          (removeAttrs cfg.settings upstreamOwnedSettingsKeys);
        hasGapSettings = gapSettings != {};
      in
        lib.mkMerge [
          # L2b → L3: expand `ai.claude.hooksDir` into
          # `ai.claude.hooks` (parity with HM side). The devenv
          # factory merges `cfg.hooks` into `claude.code.hooks`
          # below, so this expansion flows through.
          (lib.mkIf (cfg.hooksDir != null) {
            ai.claude.hooks = lib.mapAttrs (_: lib.mkDefault) (
              dirHelpers.hooksFromDir cfg.hooksDir
            );
          })
          # Translate upstream-owned keys + pin the settings file path.
          {
            claude.code = {
              enable = lib.mkDefault true;
              mcpServers = mergedServers;
              # Merge cfg.hooks (authoritative) with legacy cfg.settings.hooks
              # (backward-compat). ai.claude.hooks wins on collision.
              hooks = (cfg.settings.hooks or {}) // cfg.hooks;
              settingsPath = lib.mkDefault ".claude/settings.json";
            };
          }
          # Gap write — everything in cfg.settings that upstream doesn't
          # already handle. Uses `.json` format so module-system merges
          # our attrs with upstream's hook-only write into a single
          # settings.json on disk.
          (lib.mkIf hasGapSettings {
            files.".claude/settings.json".json = gapSettings;
          })
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

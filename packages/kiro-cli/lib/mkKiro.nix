# Kiro-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Kiro AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Fanout absorbed in Task 5 (A4): settings/cli.json activation merge,
# settings/mcp.json static write, settings/lsp.json write,
# per-instruction steering files under `.kiro/steering/`, skills
# routing to `.kiro/skills/`, agents + agentsDir writing under
# `.kiro/agents/`, hooks + hooksDir writing under `.kiro/hooks/`,
# environmentVariables fed into the HM symlinkJoin wrapper (export)
# and the devenv `env` blob.
#
# Source material: modules/kiro-cli/default.nix (291 lines, legacy
# HM module) + modules/devenv/kiro.nix (153 lines, legacy devenv).
{
  lib,
  pkgs,
  ...
}:
lib.ai.app.mkAiApp {
  name = "kiro";
  transformers.markdown = lib.ai.transformers.kiro;
  defaults = {
    package = pkgs.ai.kiro-cli;
    outputPath = ".config/kiro/steering/";
  };
  options = {
    # Config directory (HOME-relative for HM, project-relative for
    # devenv). All file writes use this as root prefix. Exposed as an
    # option so consumers can override without forking the factory.
    configDir = lib.mkOption {
      type = lib.types.str;
      default = ".kiro";
      description = "Config directory relative to HOME / devenv root.";
    };
    # Kiro-scope global context (single always-on steering file). Kiro is
    # directory-native (no single-file convention), but reads AGENTS.md
    # inside `~/.kiro/steering/` as always-included content per
    # https://kiro.dev/blog/stop-repeating-yourself/. When set, this
    # option takes precedence over the top-level `ai.context`. Written
    # without frontmatter (flat always-on).
    context = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.lines lib.types.path);
      default = null;
      description = ''
        Kiro-scope global context. Inline string or path to a file.
        Written to `<configDir>/steering/<contextFilename>` with no frontmatter.
        When null, falls back to top-level `ai.context`.
      '';
      example = lib.literalExpression "./kiro-context.md";
    };
    # Filename under `<configDir>/steering/` for the context file. Defaults
    # to AGENTS.md since Kiro reads it natively and it's the cross-ecosystem
    # convention (shared with Codex and Copilot). Override if you want a
    # Kiro-specific filename.
    contextFilename = lib.mkOption {
      type = lib.types.str;
      default = "AGENTS.md";
      description = "Filename for the context file inside `<configDir>/steering/`.";
    };
    # Kiro-specific freeform settings with typed subkeys for known
    # knobs. Consumed by the settings/cli.json activation merge in
    # `hm.config` (runtime-merge via `jq -s '.[0] * .[1]'` to
    # preserve user runtime settings across rebuilds) and by the
    # static write in `devenv.config`.
    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = (pkgs.formats.json {}).type;
        options = {
          chat = lib.mkOption {
            type = lib.types.submodule {
              freeformType = (pkgs.formats.json {}).type;
              options = {
                defaultModel = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Default chat model.";
                };
                enableThinking = lib.mkOption {
                  type = lib.types.nullOr lib.types.bool;
                  default = null;
                  description = "Enable thinking/reasoning mode.";
                };
              };
            };
            default = {};
            description = "Chat-related settings.";
          };
          telemetry = lib.mkOption {
            type = lib.types.submodule {
              freeformType = (pkgs.formats.json {}).type;
              options = {
                enabled = lib.mkOption {
                  type = lib.types.nullOr lib.types.bool;
                  default = null;
                  description = "Enable telemetry reporting.";
                };
              };
            };
            default = {};
            description = "Telemetry settings.";
          };
        };
      };
      default = {};
      description = ''
        JSON settings merged into ~/.kiro/settings/cli.json on activation (HM)
        or written statically (devenv). Runtime-mutated keys are preserved in HM.
        Known keys are typed; unknown keys are accepted via freeformType.
      '';
    };
    # Typed LSP server definitions for settings/lsp.json. Freeform
    # attrs-of-anything matching the legacy `attrsOf jsonFormat.type`.
    lspServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = {};
      description = "LSP server definitions written to settings/lsp.json.";
    };
    # Env vars exported when launching kiro. In HM they're baked into
    # the symlinkJoin wrapper; in devenv they populate the native
    # `env` attrset. `attrsOf str` — matching the legacy surface.
    environmentVariables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Environment variables exported when launching kiro (HM: via wrapper; devenv: via native env).";
    };
    # Enable TUI mode — appends `--tui` to `kiro-cli`.
    tui = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Append --tui flag to the kiro-cli wrapper (HM only — devenv doesn't wrap the binary).";
    };
    # MCP tools to auto-approve — appends `--trust-tools='<csv>'`
    # to `kiro-cli-chat`. Eliminates the need for a bespoke
    # symlinkJoin wrapper in the consumer.
    trustedMcpTools = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "List of MCP tool patterns to auto-approve via --trust-tools on kiro-cli-chat (HM only).";
      example = ["@context7-mcp" "@git-mcp/git_diff" "subagent"];
    };
    # Inline agent JSON content. Written under
    # `<configDir>/agents/<name>.json` in both backends.
    agents = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = {};
      description = "Agent JSON definitions (written to <configDir>/agents/<name>.json).";
    };
    # External agents directory. Symlinked at `<configDir>/agents`
    # when set; walked recursively in devenv because devenv's
    # `files.*.source` can't recurse.
    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "External directory of agent JSON files (symlinked into <configDir>/agents).";
    };
    # Inline hook JSON content. Written under
    # `<configDir>/hooks/<name>.json` in both backends.
    hooks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = {};
      description = "Hook JSON definitions (written to <configDir>/hooks/<name>.json).";
    };
    # External hooks directory. Symlinked at `<configDir>/hooks`
    # when set; walked recursively in devenv.
    hooksDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "External directory of hook JSON files (symlinked into <configDir>/hooks).";
    };
  };
  hm = {
    options = {};
    config = {
      cfg,
      mergedServers,
      mergedInstructions,
      mergedSkills,
      topContext,
    }: let
      helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
      aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};

      # Resolve effective context: per-CLI wins when set, else top-level.
      effectiveContext =
        if cfg.context != null
        then cfg.context
        else topContext;
      hasContext = effectiveContext != null && effectiveContext != "";

      filteredSettings = aiCommon.filterNulls cfg.settings;
      # Kiro cli.json uses flat dot-notation keys ("chat.enableTangentMode")
      # not nested JSON. Flatten so consumers can write clean Nix:
      #   settings.chat.enableTangentMode = true;
      flatSettings = aiCommon.flattenDotKeys filteredSettings;

      # symlinkJoin wrapper for environmentVariables, --tui, and
      # --trust-tools. Conditional: raw package when nothing to wrap.
      hasEnv = cfg.environmentVariables != {};
      hasTui = cfg.tui;
      hasTrust = cfg.trustedMcpTools != [];
      needsWrapper = hasEnv || hasTui || hasTrust;
      setEnvArgs =
        lib.concatStringsSep " "
        (lib.mapAttrsToList
          (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}")
          cfg.environmentVariables);
      trustToolsCsv = lib.concatStringsSep "," cfg.trustedMcpTools;
      wrappedPackage = pkgs.symlinkJoin {
        name = "kiro-cli-wrapped";
        paths = [cfg.package];
        nativeBuildInputs = [pkgs.makeWrapper];
        postBuild = ''
          ${lib.optionalString (hasEnv || hasTui) ''
            wrapProgram $out/bin/kiro-cli \
              ${setEnvArgs} \
              ${lib.optionalString hasTui ''--append-flags "--tui"''}
          ''}
          ${lib.optionalString (hasEnv || hasTrust) ''
            wrapProgram $out/bin/kiro-cli-chat \
              ${setEnvArgs} \
              ${lib.optionalString hasTrust ''--append-flags "--trust-tools='${trustToolsCsv}'"''}
          ''}
        '';
      };
      kiroPackage =
        if needsWrapper
        then wrappedPackage
        else cfg.package;

      # JSON entry generation for agents and hooks (legacy mkJsonEntries).
      mkJsonEntries = subdir: attrs:
        lib.mapAttrs' (name: content:
          lib.nameValuePair "${cfg.configDir}/${subdir}/${name}.json"
          (helpers.mkSourceEntry content))
        attrs;
    in
      lib.mkMerge [
        # Package installation — wrapped with symlinkJoin when env
        # vars are configured. Matches the legacy wrapper shape.
        {home.packages = [kiroPackage];}
        # Assertions: mutually exclusive inline/dir pairs for agents,
        # hooks, skills (steering handled by the factory's baseline
        # render + per-instruction file writes below).
        {
          assertions = [
            {
              assertion = !(cfg.agents != {} && cfg.agentsDir != null);
              message = "ai.kiro: cannot set both `agents` and `agentsDir` — choose one.";
            }
            {
              assertion = !(cfg.hooks != {} && cfg.hooksDir != null);
              message = "ai.kiro: cannot set both `hooks` and `hooksDir` — choose one.";
            }
          ];
        }
        # settings/lsp.json — typed LSP server definitions.
        (lib.mkIf (cfg.lspServers != {}) {
          home.file."${cfg.configDir}/settings/lsp.json".text =
            builtins.toJSON cfg.lspServers;
        })
        # settings/mcp.json — merged MCP server pool. Kiro reads this
        # natively from its config dir. Render typed entries into the
        # freeform shape Kiro expects in mcp.json.
        (lib.mkIf (mergedServers != {}) {
          home.file."${cfg.configDir}/settings/mcp.json".text = builtins.toJSON {
            mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
          };
        })
        # Inline agent JSON files.
        (lib.mkIf (cfg.agents != {}) {
          home.file = mkJsonEntries "agents" cfg.agents;
        })
        # External agents directory — symlinked wholesale via
        # `recursive = true` (Layout B).
        (lib.mkIf (cfg.agentsDir != null) {
          home.file."${cfg.configDir}/agents" = {
            source = cfg.agentsDir;
            recursive = true;
          };
        })
        # Inline hook JSON files.
        (lib.mkIf (cfg.hooks != {}) {
          home.file = mkJsonEntries "hooks" cfg.hooks;
        })
        # External hooks directory — symlinked wholesale via
        # `recursive = true` (Layout B).
        (lib.mkIf (cfg.hooksDir != null) {
          home.file."${cfg.configDir}/hooks" = {
            source = cfg.hooksDir;
            recursive = true;
          };
        })
        # Per-instruction steering files — write
        # `.kiro/steering/<name>.md` for each instruction entry that
        # carries a `name` field. The kiro transformer emits
        # `inclusion:` / `fileMatchPattern:` YAML frontmatter. CRITICAL:
        # fileMatchPattern MUST be emitted as a YAML array for
        # multi-element paths — a comma-joined string silently matches
        # nothing. The kiro transformer handles this correctly.
        # Nameless entries fall through to the baseline aggregate
        # render at `defaults.outputPath` which is handled by
        # mkAiApp's hmTransform.
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/kiro.nix {inherit lib;}) kiroTransformer;
          named = builtins.filter (i: i ? name) mergedInstructions;
        in {
          home.file = lib.listToAttrs (map (instr: {
              name = "${cfg.configDir}/steering/${instr.name}.md";
              value.text = fragmentsLib.mkRenderer kiroTransformer {inherit (instr) name;} instr;
            })
            named);
        })
        # Global context → `<configDir>/steering/<contextFilename>`. Kiro
        # reads AGENTS.md (default) natively as always-included content.
        # Written without frontmatter; precedence is per-CLI > top-level.
        (lib.mkIf hasContext {
          home.file."${cfg.configDir}/steering/${cfg.contextFilename}" =
            if builtins.isPath effectiveContext
            then {source = effectiveContext;}
            else {text = effectiveContext;};
        })
        # Skills fanout via mkSkillEntries, which uses
        # `recursive = true` to produce Layout B (a real directory with
        # per-file symlinks) and is path-type-agnostic.
        {
          home.file = helpers.mkSkillEntries cfg.configDir mergedSkills;
        }
        # settings/cli.json activation merge. Preserves user-added
        # runtime keys (e.g. model selection, toggles) by merging
        # Nix-declared values on top of the existing file via
        # `jq -s '.[0] * .[1]'`. On first activation (no existing
        # file) the Nix-rendered JSON is written as-is. Ported from
        # legacy modules/kiro-cli/default.nix.
        #
        # HM-only: gated on non-empty settings so consumers who enable
        # ai.kiro just for MCP fanout don't clobber an externally-
        # managed cli.json. Matches upstream Claude HM behavior
        # (settings.json only written when cfg.settings != {}).
        # Devenv-side is unconditional (project-local, harmless).
        (lib.mkIf (filteredSettings != {}) (let
          settingsJsonText = builtins.toJSON flatSettings;
        in {
          home.activation.kiroSettingsMerge = lib.hm.dag.entryAfter ["writeBoundary"] ''
            set -eu
            SETTINGS_DIR="$HOME/${cfg.configDir}/settings"
            ${pkgs.coreutils}/bin/mkdir -p "$SETTINGS_DIR"
            NIX_SETTINGS=$(${pkgs.coreutils}/bin/mktemp)
            ${pkgs.coreutils}/bin/cat > "$NIX_SETTINGS" <<'KIRO_SETTINGS_EOF'
            ${settingsJsonText}
            KIRO_SETTINGS_EOF
            if [ ! -f "$SETTINGS_DIR/cli.json" ]; then
              ${pkgs.coreutils}/bin/cp "$NIX_SETTINGS" "$SETTINGS_DIR/cli.json"
            else
              # Merge Nix-declared settings on top of user runtime settings;
              # Nix values override on conflict, user additions pass through.
              TMP=$(${pkgs.coreutils}/bin/mktemp)
              ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$SETTINGS_DIR/cli.json" "$NIX_SETTINGS" > "$TMP"
              ${pkgs.coreutils}/bin/mv "$TMP" "$SETTINGS_DIR/cli.json"
            fi
            ${pkgs.coreutils}/bin/rm -f "$NIX_SETTINGS"
            ${pkgs.coreutils}/bin/chmod 644 "$SETTINGS_DIR/cli.json"
          '';
        }))
      ];
  };
  devenv = {
    options = {};
    config = {
      cfg,
      mergedServers,
      mergedInstructions,
      mergedSkills,
      topContext,
    }: let
      helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
      aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};

      effectiveContext =
        if cfg.context != null
        then cfg.context
        else topContext;
      hasContext = effectiveContext != null && effectiveContext != "";

      filteredSettings = aiCommon.filterNulls cfg.settings;
      flatSettings = aiCommon.flattenDotKeys filteredSettings;
    in
      lib.mkMerge [
        # Package installation — devenv projects are shell-scoped, so
        # env exports go in the devenv `env` attrset directly rather
        # than an HM-style symlinkJoin wrapper.
        {packages = [cfg.package];}
        # Assertions: mutually exclusive inline/dir pairs.
        {
          assertions = [
            {
              assertion = !(cfg.agents != {} && cfg.agentsDir != null);
              message = "ai.kiro: cannot set both `agents` and `agentsDir` — choose one.";
            }
            {
              assertion = !(cfg.hooks != {} && cfg.hooksDir != null);
              message = "ai.kiro: cannot set both `hooks` and `hooksDir` — choose one.";
            }
          ];
        }
        # Environment variables — devenv has a native `env` attrset
        # so no wrapper is required.
        (lib.mkIf (cfg.environmentVariables != {}) {
          env = lib.mapAttrs (_: lib.mkDefault) cfg.environmentVariables;
        })
        # settings/lsp.json — typed LSP server definitions.
        (lib.mkIf (cfg.lspServers != {}) {
          files."${cfg.configDir}/settings/lsp.json".text =
            builtins.toJSON cfg.lspServers;
        })
        # settings/mcp.json — merged MCP server pool. Render typed
        # entries into the freeform shape Kiro expects.
        (lib.mkIf (mergedServers != {}) {
          files."${cfg.configDir}/settings/mcp.json".text = builtins.toJSON {
            mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
          };
        })
        # Inline agent JSON files.
        (lib.mkIf (cfg.agents != {}) {
          files =
            lib.concatMapAttrs (name: content: {
              "${cfg.configDir}/agents/${name}.json".text = content;
            })
            cfg.agents;
        })
        # External agents directory — devenv's `files.*.source`
        # can't recurse, so we walk the directory at eval time.
        (lib.mkIf (cfg.agentsDir != null) (let
          walkDir = prefix: dir:
            lib.concatMapAttrs (
              name: kind:
                if kind == "directory"
                then walkDir "${prefix}/${name}" (dir + "/${name}")
                else if kind == "regular" || kind == "symlink"
                then {"${prefix}/${name}".source = dir + "/${name}";}
                else {}
            )
            (builtins.readDir dir);
        in {
          files = walkDir "${cfg.configDir}/agents" cfg.agentsDir;
        }))
        # Inline hook JSON files.
        (lib.mkIf (cfg.hooks != {}) {
          files =
            lib.concatMapAttrs (name: content: {
              "${cfg.configDir}/hooks/${name}.json".text = content;
            })
            cfg.hooks;
        })
        # External hooks directory — walked at eval time.
        (lib.mkIf (cfg.hooksDir != null) (let
          walkDir = prefix: dir:
            lib.concatMapAttrs (
              name: kind:
                if kind == "directory"
                then walkDir "${prefix}/${name}" (dir + "/${name}")
                else if kind == "regular" || kind == "symlink"
                then {"${prefix}/${name}".source = dir + "/${name}";}
                else {}
            )
            (builtins.readDir dir);
        in {
          files = walkDir "${cfg.configDir}/hooks" cfg.hooksDir;
        }))
        # Per-instruction steering files under `.kiro/steering/`.
        # Same transformer as HM, same filter-by-name pattern.
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/kiro.nix {inherit lib;}) kiroTransformer;
          named = builtins.filter (i: i ? name) mergedInstructions;
        in {
          files = lib.listToAttrs (map (instr: {
              name = "${cfg.configDir}/steering/${instr.name}.md";
              value.text = fragmentsLib.mkRenderer kiroTransformer {inherit (instr) name;} instr;
            })
            named);
        })
        # Global context → `<configDir>/steering/<contextFilename>`.
        # Mirrors HM side; no frontmatter, per-CLI wins over top-level.
        (lib.mkIf hasContext {
          files."${cfg.configDir}/steering/${cfg.contextFilename}" =
            if builtins.isPath effectiveContext
            then {source = effectiveContext;}
            else {text = effectiveContext;};
        })
        # Skills via the user-space walker. devenv's `files.*.source`
        # cannot walk a directory recursively, so we enumerate leaves
        # at eval time via `mkDevenvSkillEntries`.
        {
          files = helpers.mkDevenvSkillEntries cfg.configDir mergedSkills;
        }
        # settings/cli.json — devenv does NOT support HM-style
        # activation scripts. Devenv projects are project-local, so
        # there's no runtime-mutation preservation concern. Static
        # JSON write is sufficient.
        (lib.mkIf (filteredSettings != {}) {
          files."${cfg.configDir}/settings/cli.json".text =
            builtins.toJSON flatSettings;
        })
      ];
  };
}

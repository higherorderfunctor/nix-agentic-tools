# Copilot-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Copilot AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Fanout absorbed in Task 4 (A3): settings.json activation merge,
# mcp-config.json static write, per-instruction rule files under
# `.github/instructions/`, skills routing to `.config/github-copilot/skills/`.
#
# Fanout absorbed in Task 4b (A3 gap-fill): lspServers typed LSP
# config write, environmentVariables fed into the HM symlinkJoin
# wrapper (export) and the devenv `env` blob, agents + agentsDir
# option pair writing under `${configDir}/agents/`, and the HM
# symlinkJoin wrapper that injects `--additional-mcp-config` so the
# rendered mcp-config.json actually gets loaded by the copilot
# binary at runtime.
{
  lib,
  pkgs,
  ...
}:
lib.ai.app.mkAiApp {
  name = "copilot";
  transformers.markdown = lib.ai.transformers.copilot;
  defaults = {
    package = pkgs.ai.copilot-cli;
    outputPath = ".config/github-copilot/copilot-instructions.md";
  };
  options = {
    # Config directory (HOME-relative). Used by both backends as the
    # root for mcp-config.json / lsp-config.json / settings.json /
    # agents/. The legacy HM module defaulted to `.copilot`; Task 4
    # standardized on `.config/github-copilot` for all writes and the
    # wrapper arg targets the same path. Exposed as an option so
    # consumers who need the legacy layout (or a custom XDG setup)
    # can override without forking the factory.
    configDir = lib.mkOption {
      type = lib.types.str;
      default = ".config/github-copilot";
      description = "Config directory relative to HOME / devenv root.";
    };
    # Copilot-specific freeform settings. Consumed by the settings.json
    # activation merge in `hm.config` (runtime-merge via `jq -s '.[0] * .[1]'`
    # to preserve user-added `trusted_folders` across rebuilds) and by
    # the static write in `devenv.config`. Full typed surface (editor
    # integration, telemetry, typed model selection) is tracked in
    # docs/plan.md "Ideal architecture gate → Absorption backlog" under
    # the copilot-cli absorption item.
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Freeform settings merged into ~/.config/github-copilot/settings.json (HM: via activation script; devenv: via static write).";
    };
    # Typed LSP server definitions for lsp-config.json. Freeform
    # attrs-of-anything (matching the legacy `attrsOf jsonFormat.type`)
    # — consumers pass the JSON shape copilot expects. A richer typed
    # schema shared with kiro lives in `lib/ai-common.nix`
    # (`lspServerModule` + `mkCopilotLspConfig`) and is a pattern
    # expansion deferred until the cross-ecosystem `ai.lspServers`
    # surface lands; per-app options are fine for now.
    lspServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = {};
      description = "LSP server definitions written to lsp-config.json.";
    };
    # Env vars exported when launching copilot. In HM they're baked
    # into the symlinkJoin wrapper's `export FOO=bar` lines; in
    # devenv they populate the native `env` attrset. `attrsOf str` —
    # matching the legacy surface exactly.
    environmentVariables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Environment variables exported when launching copilot (HM: via wrapper; devenv: via native env).";
    };
    # Inline agent markdown content. Written under
    # `<configDir>/agents/<name>.md` in both backends. Mutually
    # exclusive with `agentsDir` (enforced by assertion below).
    agents = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = "Inline agent markdown (written to <configDir>/agents/<name>.md).";
    };
    # External agents directory. Symlinked at `<configDir>/agents`
    # when set; walked recursively in devenv (via the same walker as
    # skills) because devenv's `files.*.source` can't recurse.
    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "External directory of agent markdown files (symlinked into <configDir>/agents).";
    };
  };
  hm = {
    options = {};
    config = {
      cfg,
      mergedServers,
      mergedInstructions,
      mergedSkills,
    }: let
      # symlinkJoin + makeWrapper wrapper that exports
      # `environmentVariables` and prepends `--additional-mcp-config
      # <path>` to every copilot invocation. Without this, the
      # `mcp-config.json` written below would sit on disk and never
      # be read — copilot only loads additional MCP config via the
      # explicit CLI flag. Conditional on there being something to
      # wrap; the raw `cfg.package` is used otherwise so consumers
      # with no env vars / no MCP servers don't pay for a rebuild.
      #
      # We use `wrapProgram` (from `makeWrapper`) rather than the
      # legacy inline bash heredoc. The legacy wrote `$out` into
      # the generated wrapper via a quoted `<< 'WRAPPER'` heredoc
      # and relied on `$out` being set at runtime, which it isn't
      # outside the nix build sandbox — that was a latent bug.
      # `wrapProgram` resolves the target path at wrap time
      # (substituting the real store path), which is the
      # conventional correct shape and matches the rest of the
      # ai-clis overlay.
      hasMcp = mergedServers != {};
      hasEnv = cfg.environmentVariables != {};
      needsWrapper = hasMcp || hasEnv;
      # `--add-flags` takes a single string; `makeWrapper` splices
      # it verbatim into the generated wrapper so shell variables
      # (`$HOME`) are expanded by bash at runtime. The mcp-config
      # path therefore refers to whatever `$HOME/${configDir}`
      # resolves to when copilot is launched, matching the
      # on-disk write above.
      mcpConfigPath = "$HOME/${cfg.configDir}/mcp-config.json";
      addFlagsArg =
        lib.optionalString hasMcp
        ''--add-flags "--additional-mcp-config ${mcpConfigPath}"'';
      setEnvArgs =
        lib.concatStringsSep " "
        (lib.mapAttrsToList
          (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}")
          cfg.environmentVariables);
      wrappedPackage = pkgs.symlinkJoin {
        name = "copilot-cli-wrapped";
        paths = [cfg.package];
        nativeBuildInputs = [pkgs.makeWrapper];
        postBuild = ''
          wrapProgram $out/bin/copilot \
            ${addFlagsArg} \
            ${setEnvArgs}
        '';
      };
      copilotPackage =
        if needsWrapper
        then wrappedPackage
        else cfg.package;
    in
      lib.mkMerge [
        # Package installation — wrapped with symlinkJoin when env
        # vars or MCP servers are configured so the binary picks up
        # `--additional-mcp-config` and the requested env. Matches
        # the legacy modules/copilot-cli/default.nix wrapper shape.
        {home.packages = [copilotPackage];}
        # Assertions: agents and agentsDir are mutually exclusive
        # (matches legacy `mkExclusiveAssertion`).
        {
          assertions = [
            {
              assertion = !(cfg.agents != {} && cfg.agentsDir != null);
              message = "ai.copilot: cannot set both `agents` and `agentsDir` — choose one.";
            }
          ];
        }
        # lsp-config.json — typed LSP server definitions for the
        # copilot CLI. Inlined via `text` so module-eval can assert
        # on content and we don't pay for a store build per eval.
        (lib.mkIf (cfg.lspServers != {}) {
          home.file."${cfg.configDir}/lsp-config.json".text =
            builtins.toJSON cfg.lspServers;
        })
        # Inline agent .md files. Mirrors the legacy
        # `mkMarkdownEntries` shape — one entry per agent, written
        # under `${configDir}/agents/<name>.md`.
        (lib.mkIf (cfg.agents != {}) {
          home.file = lib.mapAttrs' (name: content:
            lib.nameValuePair "${cfg.configDir}/agents/${name}.md" {
              text = content;
            })
          cfg.agents;
        })
        # External agents directory — symlinked wholesale via
        # `recursive = true` so each file inside gets its own
        # store symlink (Layout B).
        (lib.mkIf (cfg.agentsDir != null) {
          home.file."${cfg.configDir}/agents" = {
            source = cfg.agentsDir;
            recursive = true;
          };
        })
        # mcp-config.json — static write of the merged MCP server
        # pool. The symlinkJoin wrapper above points
        # `--additional-mcp-config` at this exact path so copilot
        # loads these servers at runtime. Inlined as `text` so
        # module-eval can assert on content without a store build.
        (lib.mkIf (mergedServers != {}) {
          home.file."${cfg.configDir}/mcp-config.json".text = builtins.toJSON {
            mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
          };
        })
        # Per-instruction files — write
        # `.github/instructions/<name>.instructions.md` for each
        # instruction entry that carries a `name` field. The copilot
        # transformer emits `applyTo:` YAML frontmatter per scope.
        # Nameless entries fall through to the baseline aggregate
        # render at `defaults.outputPath` which is handled by
        # mkAiApp's hmTransform.
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/copilot.nix {inherit lib;}) copilotTransformer;
          named = builtins.filter (i: i ? name) mergedInstructions;
        in {
          home.file = lib.listToAttrs (map (instr: {
              name = ".github/instructions/${instr.name}.instructions.md";
              value.text = fragmentsLib.mkRenderer copilotTransformer {} instr;
            })
            named);
        })
        # Skills fanout — copilot has no upstream HM skills option, so
        # we write `home.file."${configDir}/skills/<name>"` entries
        # directly via `mkSkillEntries`, which uses `recursive = true`
        # to produce Layout B (a real directory with per-file
        # symlinks) and is path-type-agnostic (accepts both Nix path
        # literals and absolute string paths).
        (let
          helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
        in {
          home.file = helpers.mkSkillEntries cfg.configDir mergedSkills;
        })
        # Settings.json activation merge. Preserves user-added runtime
        # keys (e.g. `trusted_folders`) by merging Nix-declared values
        # on top of the existing file via `jq -s '.[0] * .[1]'`. On
        # first activation (no existing file) the Nix-rendered JSON is
        # written as-is. Ported from legacy
        # modules/copilot-cli/default.nix; the devenv side uses a plain
        # static write instead since devenv lifecycles are project-local.
        #
        # The settings JSON is inlined into the activation script via
        # `builtins.toJSON` so the rendered values (e.g. `model`,
        # `theme`) appear literally in the script text. This keeps the
        # activation atomic — no separate store-path read required at
        # runtime — and lets module-eval tests assert on the content.
        #
        # HM-only: gated on non-empty settings so consumers who enable
        # ai.copilot just for MCP/skills fanout don't clobber an
        # externally-managed settings.json. Matches upstream Claude HM
        # behavior. Devenv-side is unconditional (project-local).
        (lib.mkIf (cfg.settings != {}) (let
          settingsJsonText = builtins.toJSON cfg.settings;
        in {
          home.activation.copilotSettingsMerge = lib.hm.dag.entryAfter ["writeBoundary"] ''
            set -eu
            SETTINGS_DIR="$HOME/${cfg.configDir}"
            ${pkgs.coreutils}/bin/mkdir -p "$SETTINGS_DIR"
            NIX_SETTINGS=$(${pkgs.coreutils}/bin/mktemp)
            ${pkgs.coreutils}/bin/cat > "$NIX_SETTINGS" <<'COPILOT_SETTINGS_EOF'
            ${settingsJsonText}
            COPILOT_SETTINGS_EOF
            if [ ! -f "$SETTINGS_DIR/settings.json" ]; then
              ${pkgs.coreutils}/bin/cp "$NIX_SETTINGS" "$SETTINGS_DIR/settings.json"
            else
              # Merge Nix-declared settings on top of user runtime settings;
              # Nix values override on conflict, user additions pass through.
              TMP=$(${pkgs.coreutils}/bin/mktemp)
              ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$SETTINGS_DIR/settings.json" "$NIX_SETTINGS" > "$TMP"
              ${pkgs.coreutils}/bin/mv "$TMP" "$SETTINGS_DIR/settings.json"
            fi
            ${pkgs.coreutils}/bin/rm -f "$NIX_SETTINGS"
            ${pkgs.coreutils}/bin/chmod 644 "$SETTINGS_DIR/settings.json"
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
    }:
      lib.mkMerge [
        # Package installation — devenv projects are shell-scoped, so
        # env exports go in the devenv `env` attrset directly rather
        # than an HM-style symlinkJoin wrapper. The binary is enough
        # here; env wiring is handled by the `env = ...` merge below.
        {packages = [cfg.package];}
        # Assertions: agents and agentsDir are mutually exclusive.
        {
          assertions = [
            {
              assertion = !(cfg.agents != {} && cfg.agentsDir != null);
              message = "ai.copilot: cannot set both `agents` and `agentsDir` — choose one.";
            }
          ];
        }
        # Environment variables — devenv has a native `env` attrset
        # so no wrapper is required. `mkDefault` lets consumers
        # override per-project via explicit `env.FOO = ...`.
        (lib.mkIf (cfg.environmentVariables != {}) {
          env = lib.mapAttrs (_: lib.mkDefault) cfg.environmentVariables;
        })
        # lsp-config.json — typed LSP server definitions. Inlined
        # as `text` for parity with the HM side.
        (lib.mkIf (cfg.lspServers != {}) {
          files."${cfg.configDir}/lsp-config.json".text =
            builtins.toJSON cfg.lspServers;
        })
        # Inline agent .md files — one devenv `files.*` entry per
        # agent under `${configDir}/agents/<name>.md`.
        (lib.mkIf (cfg.agents != {}) {
          files = lib.mapAttrs' (name: content:
            lib.nameValuePair "${cfg.configDir}/agents/${name}.md" {
              text = content;
            })
          cfg.agents;
        })
        # External agents directory — devenv's `files.*.source`
        # can't recurse, so we reuse `mkDevenvSkillEntries`' walker
        # to produce one `files.*` entry per leaf file under the
        # agents tree. The walker is generic over subdirectory
        # names (it just writes into `<prefix>/skills/<name>` by
        # convention); we adapt here by re-walking manually to keep
        # the path shape at `${configDir}/agents/...`.
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
        # Skills via the user-space walker. devenv's `files.*.source`
        # cannot walk a directory recursively (see the devenv files
        # internals fragment), so we enumerate leaves at eval time
        # via `mkDevenvSkillEntries`. Produces one `files.<path>`
        # entry per leaf file under the skill dir.
        (let
          helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
        in {
          files = helpers.mkDevenvSkillEntries cfg.configDir mergedSkills;
        })
        # mcp-config.json — static write of the merged MCP server
        # pool. Inlined as `text` for consistency with the HM side.
        (lib.mkIf (mergedServers != {}) {
          files."${cfg.configDir}/mcp-config.json".text = builtins.toJSON {
            mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
          };
        })
        # Per-instruction files under `.github/instructions/`. Same
        # transformer as HM, same filter-by-name pattern — nameless
        # entries flow into the baseline aggregate render at
        # `defaults.outputPath` via mkAiApp's devenvTransform.
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/copilot.nix {inherit lib;}) copilotTransformer;
          named = builtins.filter (i: i ? name) mergedInstructions;
        in {
          files = lib.listToAttrs (map (instr: {
              name = ".github/instructions/${instr.name}.instructions.md";
              value.text = fragmentsLib.mkRenderer copilotTransformer {} instr;
            })
            named);
        })
        # settings.json — devenv does NOT support HM-style activation
        # scripts, so the runtime-merge story is different. Devenv
        # projects are project-local (not a shared home dir), so
        # there's no `trusted_folders` preservation problem to solve
        # here. Static JSON write is sufficient.
        {
          files."${cfg.configDir}/settings.json".text =
            builtins.toJSON cfg.settings;
        }
      ];
  };
}

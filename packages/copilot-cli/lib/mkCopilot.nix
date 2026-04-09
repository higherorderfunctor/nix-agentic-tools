# Copilot-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Copilot AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Fanout absorbed in Task 4 (A3): settings.json activation merge,
# mcp-config.json static write, per-instruction rule files under
# `.github/instructions/`, skills routing to `.config/github-copilot/skills/`.
# Still tracked under the absorption backlog: LSP config, symlinkJoin
# wrapper with env exports + --additional-mcp-config flag injection,
# typed settings schema, agents directory.
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
  };
  hm = {
    options = {};
    config = {
      cfg,
      mergedServers,
      mergedInstructions,
      mergedSkills,
    }:
      lib.mkMerge [
        # Package installation (no wrapper yet — wrapper pattern from
        # legacy modules/copilot-cli/default.nix is tracked under
        # docs/plan.md "Ideal architecture gate → Absorption backlog".
        # The minimum here installs the binary; env/wrapper-args
        # fanout lands when `ai.copilot.environmentVariables` and the
        # shared MCP-config CLI-arg surface come in).
        {home.packages = [cfg.package];}
        # mcp-config.json — static write of the merged MCP server
        # pool. Copilot's CLI reads this via its
        # --additional-mcp-config flag (wiring tracked in the wrapper
        # absorption backlog item). Inlined as `text` so module-eval
        # can assert on content without a store build.
        (lib.mkIf (mergedServers != {}) {
          home.file.".config/github-copilot/mcp-config.json".text =
            builtins.toJSON {mcpServers = mergedServers;};
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
        # we write `home.file.".config/github-copilot/skills/<name>"`
        # entries directly via `mkSkillEntries`, which uses
        # `recursive = true` to produce Layout B (a real directory with
        # per-file symlinks) and is path-type-agnostic (accepts both
        # Nix path literals and absolute string paths).
        (let
          helpers = import ../../../lib/hm-helpers.nix {inherit lib;};
        in {
          home.file = helpers.mkSkillEntries ".config/github-copilot" mergedSkills;
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
        (let
          settingsJsonText = builtins.toJSON cfg.settings;
        in {
          home.activation.copilotSettingsMerge = lib.hm.dag.entryAfter ["writeBoundary"] ''
            set -eu
            SETTINGS_DIR="$HOME/.config/github-copilot"
            mkdir -p "$SETTINGS_DIR"
            NIX_SETTINGS=$(mktemp)
            cat > "$NIX_SETTINGS" <<'COPILOT_SETTINGS_EOF'
            ${settingsJsonText}
            COPILOT_SETTINGS_EOF
            if [ ! -f "$SETTINGS_DIR/settings.json" ]; then
              cp "$NIX_SETTINGS" "$SETTINGS_DIR/settings.json"
            else
              # Merge Nix-declared settings on top of user runtime settings;
              # Nix values override on conflict, user additions pass through.
              TMP=$(mktemp)
              ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$SETTINGS_DIR/settings.json" "$NIX_SETTINGS" > "$TMP"
              mv "$TMP" "$SETTINGS_DIR/settings.json"
            fi
            rm -f "$NIX_SETTINGS"
            chmod 644 "$SETTINGS_DIR/settings.json"
          '';
        })
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
        # env exports + wrapper args go in the devenv env blob rather
        # than an HM-style symlinkJoin wrapper. The binary is enough
        # here; env wiring lands with the environmentVariables fanout.
        {packages = [cfg.package];}
        # Skills via the user-space walker. devenv's `files.*.source`
        # cannot walk a directory recursively (see the devenv files
        # internals fragment), so we enumerate leaves at eval time
        # via `mkDevenvSkillEntries`. Produces one `files.<path>`
        # entry per leaf file under the skill dir.
        (let
          helpers = import ../../../lib/hm-helpers.nix {inherit lib;};
        in {
          files = helpers.mkDevenvSkillEntries ".config/github-copilot" mergedSkills;
        })
        # mcp-config.json — static write of the merged MCP server
        # pool. Inlined as `text` for consistency with the HM side.
        (lib.mkIf (mergedServers != {}) {
          files.".config/github-copilot/mcp-config.json".text =
            builtins.toJSON {mcpServers = mergedServers;};
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
          files.".config/github-copilot/settings.json".text =
            builtins.toJSON cfg.settings;
        }
      ];
  };
}

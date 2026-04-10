# Claude-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Claude AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Fanout (skills, mcpServers, instructions files) absorbed in
# Task 3 (A2). Buddy activation absorbed in Task 6 (A1).
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
    memory = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file used as Claude's memory.";
    };
    # NOTE: `settings` is declared here but NOT yet rendered to disk.
    # Writing settings JSON to ~/.claude/settings.json requires a
    # backend-specific write (home.file for HM, files.* for devenv)
    # which is tracked by the `mkAiApp backend dispatch` backlog item
    # in docs/plan.md. Values assigned to ai.claude.settings are
    # accepted without error but silently ignored until that lands.
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Freeform settings passed to Claude's config file (rendering tracked in docs/plan.md absorption backlog).";
    };
  };
  # HM-specific projection
  hm = {
    # HM-only options
    options = {
      buddy = lib.mkOption {
        type = lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "Claude buddy activation script";

            dump = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum [
                "CHAOS"
                "DEBUGGING"
                "PATIENCE"
                "SNARK"
                "WISDOM"
              ]);
              default = null;
              description = ''
                Preferred lowest stat. Must differ from peak when both are
                set. null = accept whatever the salt produces.
              '';
            };

            eyes = lib.mkOption {
              type = lib.types.enum [
                "·"
                "✦"
                "×"
                "◉"
                "@"
                "°"
              ];
              default = "·";
              description = "Eye character.";
            };

            hat = lib.mkOption {
              type = lib.types.enum [
                "beanie"
                "crown"
                "halo"
                "none"
                "propeller"
                "tinyduck"
                "tophat"
                "wizard"
              ];
              default = "none";
              description = ''
                Hat accessory. Must be "none" for common rarity (assertion
                enforced at module evaluation).
              '';
            };

            outputLogs = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Write buddy activation logs to a file.";
            };

            peak = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum [
                "CHAOS"
                "DEBUGGING"
                "PATIENCE"
                "SNARK"
                "WISDOM"
              ]);
              default = null;
              description = ''
                Preferred highest stat. null = accept whatever the salt
                produces. Increases search time ~5x.
              '';
            };

            rarity = lib.mkOption {
              type = lib.types.enum [
                "common"
                "epic"
                "legendary"
                "rare"
                "uncommon"
              ];
              default = "common";
              description = ''
                Rarity tier. Higher rarities take longer to compute at
                activation time:
                - common: instant (~180 attempts)
                - uncommon/rare: <1s
                - epic: ~1s
                - legendary: ~1s (or ~30s shiny, minutes shiny+stats)

                The salt search is cached by a fingerprint of buddy options
                + claude-code version + userId — only re-runs when something
                changes.
              '';
            };

            shiny = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Rainbow shimmer variant. Significantly increases salt search
                time (~100x more attempts).
              '';
            };

            species = lib.mkOption {
              type = lib.types.enum [
                "axolotl"
                "blob"
                "cactus"
                "capybara"
                "cat"
                "chonk"
                "dragon"
                "duck"
                "ghost"
                "goose"
                "mushroom"
                "octopus"
                "owl"
                "penguin"
                "rabbit"
                "robot"
                "snail"
                "turtle"
              ];
              description = "Buddy species (one of 18).";
              example = "duck";
            };

            statePath = lib.mkOption {
              type = lib.types.str;
              default = ".local/state/claude-code-buddy";
              description = "Relative path under $HOME for buddy state.";
            };

            userId = lib.mkOption {
              type = lib.types.attrTag {
                text = lib.mkOption {
                  type = lib.types.str;
                  description = ''
                    Literal Claude account UUID string. Get it from
                    ~/.claude.json under oauthAccount.accountUuid.
                  '';
                  example = "ebd8b240-9b28-44b1-a4bf-da487d9f111f";
                };
                file = lib.mkOption {
                  type = lib.types.path;
                  description = ''
                    Path to a file containing the Claude account UUID.
                    Read at activation time, so sops-nix and agenix paths
                    work. Trailing whitespace is stripped.
                  '';
                  example = lib.literalExpression ''
                    config.sops.secrets."''${username}-claude-uuid".path
                  '';
                };
              };
              description = ''
                Claude account UUID source. Provide exactly one of `text`
                (literal string) or `file` (path to file read at activation).
              '';
            };
          };
        };
        default = {enable = false;};
        description = ''
          Buddy companion customization for claude-code. When enabled, an
          activation script patches a writable cli.js with a buddy salt
          computed from the configured options and Claude account UUID.

          State is stored in $XDG_STATE_HOME/claude-code-buddy/. The
          ~/.claude.json companion field is reset whenever buddy options
          change so the new buddy hatches on next claude run.
        '';
      };
    };
    config = {
      cfg,
      mergedServers,
      mergedInstructions,
      mergedSkills,
    }: let
      # ── Buddy activation helpers (lazy, only forced when buddy.enable) ──
      mkBuddyActivationScript = buddyCfg: let
        # Use the unwrapped baseClaudeCode if available (our overlay
        # exposes it as passthru.baseClaudeCode), so the cli.js path
        # points at the real claude-code package, not the wrapper.
        baseClaudeCode =
          cfg.package.passthru.baseClaudeCode
          or cfg.package;
        storeLib = "${baseClaudeCode}/lib/node_modules/@anthropic-ai/claude-code";
        workerScript = "${pkgs.ai.any-buddy}/src/finder/worker.ts";
        shinyArg =
          if buddyCfg.shiny
          then "true"
          else "";
        # Nix `or` only catches missing-attribute, not null values. Nullable
        # options (peak/dump) need explicit null checks, otherwise string
        # interpolation below throws "cannot coerce null to a string".
        peakArg =
          if buddyCfg.peak == null
          then ""
          else buddyCfg.peak;
        dumpArg =
          if buddyCfg.dump == null
          then ""
          else buddyCfg.dump;
        userIdText = buddyCfg.userId.text or "";
        userIdFile = buddyCfg.userId.file or "";
      in ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/claude-code-buddy"
        STORE_LIB="${storeLib}"
        WORKER="${workerScript}"

        # Resolve userId source
        USER_ID_TEXT="${userIdText}"
        USER_ID_FILE="${userIdFile}"
        if [ -n "$USER_ID_FILE" ]; then
          if [ ! -f "$USER_ID_FILE" ]; then
            echo "ERROR: claude-code buddy userId file not found: $USER_ID_FILE" >&2
            echo "Ensure sops-nix or your secret manager runs before home-manager activation." >&2
            exit 1
          fi
          USER_ID=$(${pkgs.coreutils}/bin/tr -d '\n\r' < "$USER_ID_FILE")
        elif [ -n "$USER_ID_TEXT" ]; then
          USER_ID="$USER_ID_TEXT"
        else
          echo "ERROR: claude-code buddy requires userId.text or userId.file" >&2
          exit 1
        fi

        # Compute fingerprint
        NEW_FP=$(${pkgs.coreutils}/bin/printf '%s\n' \
          "$STORE_LIB" \
          "$USER_ID" \
          "${buddyCfg.species}" \
          "${buddyCfg.rarity}" \
          "${buddyCfg.eyes}" \
          "${buddyCfg.hat}" \
          "${shinyArg}" \
          "${peakArg}" \
          "${dumpArg}" \
          | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -c1-16)

        OLD_FP=$(${pkgs.coreutils}/bin/cat "$STATE_DIR/fingerprint" 2>/dev/null || echo "")

        # Cache check: gate all the update work on a fingerprint miss.
        # NOTE: DO NOT use `exit 0` here — this script is inlined into
        # the outer home-manager activate script, so a bare `exit` would
        # terminate the entire activation and skip every subsequent hook
        # (including home.file writes for skills, plugin installs, etc).
        # Use structured control flow to short-circuit cleanly.
        if [ "$NEW_FP" != "$OLD_FP" ]; then
          echo "==> Updating claude-code buddy (${buddyCfg.species}, ${buddyCfg.rarity})"

          # Refresh writable lib tree (symlinks to store, except cli.js which is real)
          ${pkgs.coreutils}/bin/rm -rf "$STATE_DIR/lib"
          ${pkgs.coreutils}/bin/mkdir -p "$STATE_DIR/lib"
          ${pkgs.coreutils}/bin/cp -rs "$STORE_LIB"/* "$STATE_DIR/lib/"
          ${pkgs.coreutils}/bin/chmod -R u+w "$STATE_DIR/lib"

          # Replace cli.js symlink with a real writable copy
          ${pkgs.coreutils}/bin/rm "$STATE_DIR/lib/cli.js"
          ${pkgs.coreutils}/bin/cp -L "$STORE_LIB/cli.js" "$STATE_DIR/lib/cli.js"
          ${pkgs.coreutils}/bin/chmod u+w "$STATE_DIR/lib/cli.js"

          # Run salt search via Bun (wyhash, no --fnv1a needed since claude-code
          # also runs under Bun via our wrapper)
          SALT=$(${pkgs.bun}/bin/bun "$WORKER" \
            "$USER_ID" \
            "${buddyCfg.species}" \
            "${buddyCfg.rarity}" \
            "${buddyCfg.eyes}" \
            "${buddyCfg.hat}" \
            "${shinyArg}" \
            "${peakArg}" \
            "${dumpArg}" \
            | ${pkgs.jq}/bin/jq -r '.salt')

          if [[ ! "$SALT" =~ ^[a-zA-Z0-9_-]{15}$ ]]; then
            echo "ERROR: invalid salt format: '$SALT'" >&2
            exit 1
          fi

          # Patch cli.js
          ${pkgs.python3}/bin/python3 -c "
        import sys
        path = '$STATE_DIR/lib/cli.js'
        data = open(path, 'rb').read()
        old = b'friend-2026-401'
        new = b'$SALT'
        if old not in data:
            sys.exit('ERROR: salt marker not found in cli.js')
        open(path, 'wb').write(data.replace(old, new))
        "

          # Reset companion field in ~/.claude.json (if file exists)
          if [ -f "$HOME/.claude.json" ]; then
            tmp=$(${pkgs.coreutils}/bin/mktemp)
            ${pkgs.jq}/bin/jq 'del(.companion)' "$HOME/.claude.json" > "$tmp"
            ${pkgs.coreutils}/bin/mv "$tmp" "$HOME/.claude.json"
          fi

          # Save fingerprint
          ${pkgs.coreutils}/bin/mkdir -p "$STATE_DIR"
          echo -n "$NEW_FP" > "$STATE_DIR/fingerprint"

          echo "==> Buddy updated. Next claude run will hatch a new ${buddyCfg.species}."
        fi
      '';
    in
      lib.mkMerge [
        # Assertions — always evaluated, even when buddy is disabled.
        {
          assertions = lib.optionals cfg.buddy.enable [
            {
              assertion = cfg.buddy.peak != cfg.buddy.dump || cfg.buddy.peak == null;
              message = "ai.claude.buddy: peak and dump stats must differ";
            }
            {
              assertion = cfg.buddy.rarity == "common" -> cfg.buddy.hat == "none";
              message = "ai.claude.buddy: common rarity forces hat = \"none\"";
            }
          ];
        }
        # Delegate to upstream programs.claude-code.* where upstream
        # provides the capability. mkDefault lets consumers override.
        {
          programs.claude-code = {
            enable = lib.mkDefault true;
            package = lib.mkDefault cfg.package;
            skills = lib.mapAttrs (_: lib.mkDefault) mergedSkills;
            settings = lib.mkMerge [
              cfg.settings
              (lib.optionalAttrs (mergedServers != {}) {mcpServers = mergedServers;})
            ];
          };
        }
        (lib.mkIf cfg.buddy.enable {
          home.activation.claudeBuddy = lib.hm.dag.entryAfter ["writeBoundary"] (mkBuddyActivationScript cfg.buddy);
        })
        (lib.mkIf (cfg.memory != null) {
          home.file.".claude/memory".source = cfg.memory;
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
        # Auto-set ENABLE_LSP_TOOL=1 when MCP servers are present.
        # Mirrors the legacy modules/ai/default.nix behavior where
        # any populated server pool implied LSP-tool wiring.
        (lib.mkIf (mergedServers != {}) {
          programs.claude-code.settings.env.ENABLE_LSP_TOOL = lib.mkDefault "1";
        })
      ];
  };
  # Devenv-specific projection (no buddy; devenv doesn't do activation scripts the same way)
  devenv = {
    options = {};
    config = {
      cfg,
      mergedServers,
      mergedInstructions,
      mergedSkills,
    }:
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

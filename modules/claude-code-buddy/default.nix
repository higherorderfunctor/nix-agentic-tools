# programs.claude-code.buddy — activation-time buddy companion management.
#
# Extends the upstream nixpkgs programs.claude-code module by adding a
# `buddy` option. When set, an activation script:
#
# 1. Computes a fingerprint from buddy options + claude-code store
#    path + userId
# 2. Compares to a stored fingerprint at
#    $XDG_STATE_HOME/claude-code-buddy/fingerprint
# 3. If different: refreshes writable cli.js, runs the any-buddy
#    worker (Bun runtime → wyhash), patches cli.js with the new
#    salt, resets the `companion` field in ~/.claude.json, and
#    writes the new fingerprint
# 4. If same: exits cleanly (cached)
#
# The package wrapping happens at the OVERLAY level (see
# packages/ai-clis/claude-code.nix). pkgs.claude-code's bin/claude is
# always wrapped with a Bun-runtime wrapper that prefers
# $XDG_STATE_HOME/claude-code-buddy/lib/cli.js with fallback to the
# store cli.js. This means the wrapper is harmless when no buddy is
# configured — and the HM module only manages user state.
#
# This approach (vs the original build-time withBuddy):
# - Works with sops-nix (userId.file is read at activation time)
# - Per-user in multi-user systems (state in user's home dir)
# - Auto-resets the companion field on option changes
#
# The fanout from `ai.claude.buddy` lives in modules/ai/default.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) literalExpression mkIf mkOption;
  inherit (import ../../lib/buddy-types.nix {inherit lib;}) buddySubmodule;

  cfg = config.programs.claude-code.buddy or null;

  # Computed lazily inside config.mkIf to avoid forcing
  # programs.claude-code.package evaluation when buddy is null.
  mkActivationScript = buddyCfg: let
    # Use the unwrapped baseClaudeCode if available (our overlay
    # exposes it as passthru.baseClaudeCode), so the cli.js path
    # points at the real claude-code package, not the wrapper.
    baseClaudeCode =
      config.programs.claude-code.package.passthru.baseClaudeCode
      or config.programs.claude-code.package;
    storeLib = "${baseClaudeCode}/lib/node_modules/@anthropic-ai/claude-code";
    workerScript = "${pkgs.any-buddy-source}/src/finder/worker.ts";
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

    if [ "$NEW_FP" = "$OLD_FP" ]; then
      # Cached — nothing to do
      exit 0
    fi

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
  '';
in {
  options.programs.claude-code.buddy = mkOption {
    type = lib.types.nullOr buddySubmodule;
    default = null;
    description = ''
      Buddy companion customization for claude-code. When set, an
      activation script patches a writable cli.js with a buddy salt
      computed from the configured options and Claude account UUID.

      State is stored in $XDG_STATE_HOME/claude-code-buddy/. The
      `~/.claude.json` `companion` field is reset whenever buddy
      options change so the new buddy hatches on next claude run.
    '';
    example = literalExpression ''
      {
        userId.file = config.sops.secrets."''${username}-claude-uuid".path;
        species = "duck";
      }
    '';
  };

  config = mkIf (cfg != null) {
    assertions = [
      {
        assertion = cfg.peak != cfg.dump || cfg.peak == null;
        message = "programs.claude-code.buddy: peak and dump stats must differ";
      }
      {
        assertion = cfg.rarity == "common" -> cfg.hat == "none";
        message = "programs.claude-code.buddy: common rarity forces hat = \"none\"";
      }
    ];

    home.activation.claudeBuddy = lib.hm.dag.entryAfter ["writeBoundary"] (mkActivationScript cfg);
  };
}

# Bare-command lint — catches shell wrapper scripts that use bare
# command names instead of absolute Nix store paths.
#
# Claude Code's MCP `env` field replaces the process environment
# entirely (no PATH inheritance). Any wrapper script spawned with
# `env` set that uses a bare command like `cat` will fail with
# "command not found". This check catches these before they ship.
#
# Scope: only scans files under lib/ and packages/*/lib/ — the
# directories that produce writeShellScript wrappers and HM
# activation scripts. Overlays, dev/, and devshell/ are excluded
# because they primarily contain installPhase/buildPhase code
# that runs inside stdenv with full PATH.
{pkgs, ...}:
pkgs.runCommandLocal "bare-commands-check" {
  nativeBuildInputs = [pkgs.ripgrep];
  src = ../.;
} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    cd "$src"

    # Bare coreutils commands that must use absolute paths in wrappers
    BARE_CMDS="cat|chmod|chown|cp|cut|head|mkdir|mktemp|mv|readlink|rm|sha256sum|tail|tr|uname|wc"

    FAILURES=""

    # Only scan lib/ and packages/*/lib/ — these produce wrapper scripts
    # and activation scripts that may run without PATH.
    SCAN_DIRS=""
    for d in lib packages/*/lib; do
      if [ -d "$d" ]; then
        SCAN_DIRS="$SCAN_DIRS $d"
      fi
    done

    if [ -z "$SCAN_DIRS" ]; then
      echo "No directories to scan."
      ${pkgs.coreutils}/bin/mkdir -p "$out"
      ${pkgs.coreutils}/bin/touch "$out/ok"
      exit 0
    fi

    # Pattern 1: $(bare-cmd ...) — command substitution with bare command
    if rg --no-heading -n "\\\$\(($BARE_CMDS) " \
      --glob '*.nix' \
      $SCAN_DIRS 2>/dev/null \
      | grep -v '# bare-commands: ok' > /tmp/bare-cmd-hits 2>/dev/null; then
      FAILURES="$FAILURES
  $(${pkgs.coreutils}/bin/cat /tmp/bare-cmd-hits)"
    fi

    # Pattern 2: line-start bare commands in shell strings
    # Match: whitespace + bare-cmd + space (typical in heredoc shell blocks)
    # Exclude: lines containing /bin/ (already absolute), comments, nix expressions
    if rg --no-heading -n "^\s+($BARE_CMDS) " \
      --glob '*.nix' \
      $SCAN_DIRS 2>/dev/null \
      | grep -v '# bare-commands: ok' \
      | grep -v '/bin/' \
      | grep -v '^\s*#' \
      | grep -v 'description' \
      | grep -v 'type ' \
      | grep -v 'mkOption' > /tmp/bare-cmd-hits2 2>/dev/null; then
      FAILURES="$FAILURES
  $(${pkgs.coreutils}/bin/cat /tmp/bare-cmd-hits2)"
    fi

    # Trim leading whitespace
    FAILURES="$(echo "$FAILURES" | ${pkgs.coreutils}/bin/tr -s '\n' | sed '/^$/d')"

    if [ -n "$FAILURES" ]; then
      echo "ERROR: Bare commands found in lib/ or packages/*/lib/ .nix files."
      echo "These will fail when spawned without PATH (e.g., Claude Code MCP env)."
      echo "Use \''${pkgs.coreutils}/bin/<cmd> instead."
      echo ""
      echo "$FAILURES"
      echo ""
      echo "Suppress false positives with: # bare-commands: ok"
      exit 1
    fi

    echo "No bare commands found in wrapper script contexts."
    ${pkgs.coreutils}/bin/mkdir -p "$out"
    ${pkgs.coreutils}/bin/touch "$out/ok"
''

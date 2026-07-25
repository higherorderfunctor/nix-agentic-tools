# Bare-command lint — catches shell wrapper scripts that use bare
# command names instead of absolute Nix store paths.
#
# Claude Code's MCP `env` field replaces the process environment
# entirely (no PATH inheritance). Any wrapper script spawned with
# `env` set that uses a bare command like `cat` will fail with
# "command not found". This check catches these before they ship.
#
# Scope: scans lib/ and packages/*/lib/ — the directories that produce
# writeShellScript wrappers and HM activation scripts — plus the single
# FILE overlays/lib.nix. dev/ and devshell/ are excluded, and so is the
# rest of overlays/, because they primarily contain
# installPhase/buildPhase code that runs inside stdenv with full PATH.
#
# overlays/lib.nix is the exception that has to be named explicitly: it
# is the ONLY file under overlays/ that emits writeShellScript wrappers
# (mkUpdateScript, mkGitRevUpdateScript). Those run outside any builder
# — the update pipeline invokes an updateScript directly — so they are
# exactly the PATH-less case this check exists for, unlike the rest of
# overlays/. It is added as a FILE rather than by widening the glob to
# overlays/, which would false-positive on the legitimate bare
# mkdir/cp/chmod in eight other overlays' build phases.
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

    # Scan lib/ and packages/*/lib/ — these produce wrapper scripts and
    # activation scripts that may run without PATH.
    SCAN_PATHS=""
    for d in lib packages/*/lib; do
      if [ -d "$d" ]; then
        SCAN_PATHS="$SCAN_PATHS $d"
      fi
    done

    # Plus individually named FILES outside those trees that also emit
    # wrappers. Guarded with -f, not -d, so the directory loop above stays
    # a directory loop. See the header for why overlays/lib.nix is here
    # and the rest of overlays/ is not.
    for f in overlays/lib.nix; do
      if [ -f "$f" ]; then
        SCAN_PATHS="$SCAN_PATHS $f"
      fi
    done

    if [ -z "$SCAN_PATHS" ]; then
      echo "No paths to scan."
      ${pkgs.coreutils}/bin/mkdir -p "$out"
      ${pkgs.coreutils}/bin/touch "$out/ok"
      exit 0
    fi

    # Pattern 1: $(bare-cmd ...) — command substitution with bare command
    if rg --no-heading -n "\\\$\(($BARE_CMDS) " \
      --glob '*.nix' \
      $SCAN_PATHS 2>/dev/null \
      | grep -v '# bare-commands: ok' > /tmp/bare-cmd-hits 2>/dev/null; then
      FAILURES="$FAILURES
  $(${pkgs.coreutils}/bin/cat /tmp/bare-cmd-hits)"
    fi

    # Pattern 2: line-start bare commands in shell strings
    # Match: whitespace + bare-cmd + space (typical in heredoc shell blocks)
    # Exclude: lines containing /bin/ (already absolute), comments, nix expressions
    if rg --no-heading -n "^\s+($BARE_CMDS) " \
      --glob '*.nix' \
      $SCAN_PATHS 2>/dev/null \
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
      echo "ERROR: Bare commands found in a wrapper-producing .nix file."
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

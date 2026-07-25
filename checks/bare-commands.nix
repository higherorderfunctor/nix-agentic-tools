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
#
# overlays/lib.nix is nonetheless a MIXED file, and the check cannot tell
# the two halves apart because context is a property of the CALLER, not of
# the line:
#
#   - mkUpdateScript, mkGitRevUpdateScript emit `writeShellScript`
#     wrappers — invoked directly, possibly with a replaced (PATH-less)
#     environment. Absolute store paths REQUIRED.
#   - mkMcpSmokeTest, mkClaudeExtract, mkKiroExtract emit build-context
#     script bodies (installCheckPhase, runCommandLocal) that run inside
#     stdenv with a full PATH from build inputs. Bare commands are
#     CORRECT there.
#
# So a bare command in one of the build-context helpers is a false
# positive and gets a `# bare-commands: ok` marker on its own line rather
# than a rewrite. Expect to add more markers as those helpers grow; that
# is the accepted cost of scanning the file as a whole.
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

    # Shell contexts in which a bare word is being RUN as a command, as
    # opposed to being a nix attribute name that happens to collide with a
    # coreutils binary. Three anchors, one per defect form observed in real
    # regressions:
    #
    #   ^\s+cmd    line start          e.g. `mv "$tmp" "$dest"`
    #   |\s*cmd    after a pipe        e.g. `printf … | tr '\n' ' '`
    #   &&\s*cmd   after an AND list   e.g. `jq … > "$new" && mv "$new" "$f"`
    #
    # Defined once and shared by the scan below so a fourth anchor is a
    # one-line change rather than an edit per pattern.
    CMD_START="(^\s+|\|\s*|&&\s*)"

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

    # Pattern 1: $(bare-cmd) — command substitution with a bare command.
    # The trailing \b (word boundary) rather than a literal space is what
    # makes the ARGUMENT-LESS form visible: `tmp=$(mktemp)` closes the
    # substitution immediately, so a space-anchored pattern walked straight
    # past it while catching only `$(mktemp -d …)`.
    if rg --no-heading -n "\\\$\(($BARE_CMDS)\b" \
      --glob '*.nix' \
      $SCAN_PATHS 2>/dev/null \
      | grep -v '# bare-commands: ok' > /tmp/bare-cmd-hits 2>/dev/null; then
      FAILURES="$FAILURES
  $(${pkgs.coreutils}/bin/cat /tmp/bare-cmd-hits)"
    fi

    # Pattern 2: bare commands in shell strings, at any of the CMD_START
    # anchors — not just line start. A line-start-only anchor missed every
    # bare command that follows a pipe (`… | cut -f1`) or an AND list
    # (`… && mv x y`), which between them are the majority of real hits.
    # Exclude: lines containing /bin/ (already absolute), comments, nix expressions
    if rg --no-heading -n "$CMD_START($BARE_CMDS)\b" \
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

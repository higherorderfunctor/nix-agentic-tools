# Bare-command lint — catches shell wrapper scripts that use bare
# command names instead of absolute Nix store paths.
#
# Claude Code's MCP `env` field replaces the process environment
# entirely (no PATH inheritance). Any wrapper script spawned with
# `env` set that uses a bare command like `cat` will fail with
# "command not found". This check catches these before they ship.
#
# Scope: two scan sets, because two different things are being checked.
#
#   - Patterns 1 and 2 (whole-line, BARE_CMDS) scan lib/ and
#     packages/*/lib/ — the directories that produce writeShellScript
#     wrappers and HM activation scripts — plus the single FILE
#     overlays/lib.nix. dev/ and devshell/ are excluded, and so is the
#     rest of overlays/, because they primarily contain
#     installPhase/buildPhase code that runs inside stdenv with full PATH.
#   - Pattern 3 (versionCheck.cmd lines only, WRAPPER_CMDS) scans all of
#     overlays/ recursively. See "The versionCheck.cmd scan" below for
#     why that wider file set is both necessary and affordable.
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
#
# ── The `versionCheck.cmd` scan (pattern 3) ──────────────────────────
#
# One PATH-less context lives outside the scan set above and cannot be
# reached by widening it. Every per-package overlay may carry a
# `versionCheck.cmd` string, and `mkUpdateScript` interpolates it into
# `latest=$(<versionCheck.cmd>)` inside a
# `pkgs.writeShellScript "update-<pname>"` — a genuine wrapper, invoked
# directly by the update pipeline with no builder PATH. The string is
# authored in the PACKAGE file, so scanning only `overlays/lib.nix`
# checks the interpolation site while leaving every actual command
# unscanned.
#
# Pattern 3 therefore scans EVERY `.nix` file under `overlays/`
# recursively, but ONLY lines that mention `versionCheck.cmd`. Scoping
# by MECHANISM rather than by directory is what makes the wider scan
# affordable: `versionCheck.cmd` is a pure PATH-less context with no
# legitimate bare commands, unlike the installPhase/buildPhase code that
# fills the rest of those files.
#
# It gets its own command list, `WRAPPER_CMDS`. `BARE_CMDS` is
# coreutils-only and contains none of `curl`, `jq`, `sed` or `grep` —
# precisely the tools every real `versionCheck.cmd` is built from — so a
# pattern reusing it would be decorative. `WRAPPER_CMDS` is `BARE_CMDS`
# plus the fetch/filter tools; the wider list is safe here for the same
# reason the wider file scan is.
#
# Residual limitations, stated so they are not rediscovered as bugs:
#
#   - Pattern 3 is LINE-scoped. A `versionCheck.cmd` written as a
#     multi-line Nix string, or bound through a `let` and referenced by
#     name, would evade it. None exist today, and the encouraged path is
#     `vu.ghLatestVersionCmd` in overlays/lib.nix — which IS scanned, by
#     patterns 1 and 2, as part of the named-file set.
#   - `installPhase` / `buildPhase` bare commands across `overlays/`
#     remain deliberately unscanned. They run inside stdenv with a full
#     PATH from build inputs, so absolute paths there are optional (see
#     the nix-standards fragment); flagging them would cost a suppression
#     marker per line for no risk.
#   - The `/bin/` filter is applied per LINE, not per match, so a MIXED
#     `versionCheck.cmd` — one command absolute, another bare, as in
#     `"<pkgs.curl>/bin/curl … | jq -r .x"` — is skipped whole. The
#     command-start anchors already exclude a properly absolute
#     invocation on their own (after `|` comes the interpolation, not the
#     command name), so the line filter buys nothing here and costs the mixed
#     case. It is kept only for consistency with patterns 1 and 2, where
#     the same weakness is pre-existing. Narrowing it is a candidate
#     follow-up, not a silent change.
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

    # The wider list used by the versionCheck.cmd scan (pattern 3) —
    # BARE_CMDS plus the fetch/filter tools every real version check is
    # built from. BARE_CMDS alone carries none of curl/jq/sed/grep, so
    # reusing it there would match nothing that exists. See the header for
    # why the wider list is affordable in that one context and not in the
    # mixed files patterns 1 and 2 scan.
    WRAPPER_CMDS="awk|basename|cat|chmod|chown|cp|curl|cut|dirname|grep|head|jq|mkdir|mktemp|mv|readlink|rm|sed|sha256sum|sort|tail|tr|uname|uniq|wc|xargs"

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

    # Same idea for pattern 3, but the anchors have to work MID-LINE:
    # a versionCheck.cmd is one Nix string on one line, so a command can
    # only open the string, follow a pipe, follow an AND list, or open a
    # command substitution. The line-start anchor is meaningless here and
    # the opening quote takes its place.
    #
    #   "cmd     opens the string    e.g. `cmd = "curl -s https://…`
    #   |cmd     after a pipe        e.g. `… | jq -r '.tag_name'`
    #   &&cmd    after an AND list
    #   $(cmd    command substitution
    WRAPPER_CMD_START="(\"|\||&&|\\\$\()\s*"

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

    # Pattern 3 has its own, wider scan set: every .nix file under
    # overlays/, recursively. It is safe to widen because the pattern
    # itself is scoped to lines mentioning versionCheck.cmd — see header.
    WRAPPER_SCAN_PATHS=""
    for d in overlays; do
      if [ -d "$d" ]; then
        WRAPPER_SCAN_PATHS="$WRAPPER_SCAN_PATHS $d"
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
    #
    # The comment filter is PATH-PREFIX aware. rg emits `path:lineno:content`,
    # so a line NEVER begins with whitespace-then-hash and the anchored
    # `^\s*#` it replaces could not match anything — it excluded no comment,
    # ever. Harmless while the anchors were line-start-only (a comment opens
    # with `#`, which is not a command start), but the pipe and AND-list
    # anchors above make a COMMENT containing a piped or AND-ed bare command
    # a live false positive with nothing left to filter it. The other
    # `grep -v` filters are plain substring filters and were never affected.
    if rg --no-heading -n "$CMD_START($BARE_CMDS)\b" \
      --glob '*.nix' \
      $SCAN_PATHS 2>/dev/null \
      | grep -v '# bare-commands: ok' \
      | grep -v '/bin/' \
      | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' \
      | grep -v 'description' \
      | grep -v 'type ' \
      | grep -v 'mkOption' > /tmp/bare-cmd-hits2 2>/dev/null; then
      FAILURES="$FAILURES
  $(${pkgs.coreutils}/bin/cat /tmp/bare-cmd-hits2)"
    fi

    # Pattern 3: bare commands inside a `versionCheck.cmd` string, anywhere
    # under overlays/. mkUpdateScript interpolates that string into a
    # writeShellScript wrapper the update pipeline invokes directly, so it
    # is exactly the PATH-less case — but it is authored in the per-package
    # file, which patterns 1 and 2 do not scan. Line-scoped and mechanism-
    # scoped: the wider WRAPPER_CMDS list and the wider file set are both
    # paid for by requiring `versionCheck.cmd` on the same line.
    if [ -n "$WRAPPER_SCAN_PATHS" ] && rg --no-heading -n \
      "versionCheck\.cmd.*$WRAPPER_CMD_START($WRAPPER_CMDS)\b" \
      --glob '*.nix' \
      $WRAPPER_SCAN_PATHS 2>/dev/null \
      | grep -v '# bare-commands: ok' \
      | grep -v '/bin/' \
      | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' > /tmp/bare-cmd-hits3 2>/dev/null; then
      FAILURES="$FAILURES
  $(${pkgs.coreutils}/bin/cat /tmp/bare-cmd-hits3)"
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

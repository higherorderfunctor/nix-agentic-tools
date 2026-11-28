# Bare-command lint — catches shell wrapper scripts that use bare
# command names instead of absolute Nix store paths.
#
# Claude Code's MCP `env` field replaces the process environment
# entirely (no PATH inheritance). Any wrapper script spawned with
# `env` set that uses a bare command like `cat` will fail with
# "command not found". This check catches these before they ship.
#
# Wrapper scans cover shared lib/ and owner-private packages/*/lib/. Build
# recipes under owner packages/ trees are excluded from whole-line scans:
# their stdenv phases have a full PATH. Extractors that produce builder bodies
# live in lib/packaging.nix or owner lib/packaging.nix and use the existing
# `bare-commands: ok` suppression only for those build-context lines.
#
# ── The `versionCheck.cmd` scan (pattern 3) ──────────────────────────
#
# One PATH-less context lives outside the scan set above and cannot be
# reached by widening it. Every per-package overlay may carry a
# `versionCheck.cmd` string, and `mkUpdateScript` interpolates it into
# `latest=$(<versionCheck.cmd>)` inside a
# `pkgs.writeShellScript "update-<pname>"` — a genuine wrapper, invoked
# directly by the update pipeline with no builder PATH. The string is
# authored in the PACKAGE file, so scanning only `lib/packaging.nix`
# checks the interpolation site while leaving every actual command
# unscanned.
#
# Pattern 3 therefore scans EVERY `.nix` file under `packages/`
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
# Pattern 3 carries NO `/bin/` filter, and that is deliberate. Do not
# add one back "for consistency" with pattern 2.
#
# That filter is per LINE, not per match, so on this pattern it would
# drop any MIXED command string — one invocation absolute, another bare,
# as in `"<pkgs.curl>/bin/curl … | jq -r .x"`. Mixed is not an edge case
# here, it is THE defect shape: every correct `versionCheck.cmd` in the
# tree opens with an absolute `curl`, so a regression that leaves one
# later command bare produces a line that still contains `/bin/`. With
# the filter in place the pattern was inert on 100% of its intended
# targets — measured, not inferred: all five inline command strings
# (claude-code, copilot-cli, kimchi, kiro-cli, generic/dns-root-hints)
# contain `/bin/`.
#
# It costs nothing to drop, because the anchors already do the job
# structurally. `WRAPPER_CMD_START` requires the command name to follow
# `"`, `|`, `&&` or `$(`; a properly absolute invocation presents a `$`
# there (the `${pkgs.foo}` interpolation), never a command name, so it
# cannot match in the first place. Verified against the two lines most
# likely to bite: `generic/dns-root-hints.nix`, whose string contains
# `/bin/grep` and `/bin/head` with both `grep` and `head` in
# WRAPPER_CMDS, and `lib/packaging.nix`'s `latest=$(<versionCheck.cmd>)`,
# which sits directly under the `$(` anchor. Neither matches the raw
# regex — with the filter removed, it finds ZERO hits across all of
# `packages/` on a clean tree.
#
# Pattern 2 KEEPS its `/bin/` filter. Pattern 1 never had one and needs
# none, for the same structural reason pattern 3 does not: an absolute
# invocation puts `$` after the `$(`, never a command NAME.
#
# Pattern 2's filter was re-measured on 2026-07-30 by enumerating
# exactly what it subtracts — its own raw hits that contain `/bin/`,
# with the sibling filters applied. Five lines, all five genuine false
# positives:
#
#   lib/packaging.nix — `wc="${pkgs.coreutils}/bin/wc"` and the same for
#     `tr`. A variable ASSIGNMENT, not an invocation: `^\s+` then `wc`
#     then `\b`, and `=` satisfies that word boundary. The value
#     assigned is already absolute.
#   packages/glab/lib/mkGlab.nix — `rm -f "$out/bin/glab"`.
#   packages/kiro-cli/lib/wrapPackage.nix — `rm -f "$out/bin/kiro-cli"`
#     and its `-chat` twin. Both these and glab's are a genuinely bare
#     `rm`, but inside a `symlinkJoin` `postBuild`: stdenv, full PATH,
#     the build context this check deliberately does not police. The
#     `/bin/` on those lines is a path ARGUMENT, not a command path.
#
# The 2026-07-25 measurement found four; glab's symlinkJoin arrived
# after it, and the kiro line moved out of mkKiro.nix when the wrapper
# was extracted. Both are the SAME false-positive shape, which is the
# point: this set grows with every symlinkJoin that replaces a bin, so
# the count is a measurement and never a constant.
#
# So the filter subtracts zero true positives today. Removing it would
# buy no coverage and cost three `# bare-commands: ok` markers — the
# mirror image of pattern 3, where the same filter subtracted five true
# positives and no false ones. That asymmetry is why the pattern-3
# argument does NOT transfer: there the anchors excluded absolute
# invocations structurally, here `^\s+` genuinely lands on lines that
# are not invocations at all.
#
# The blind spot is real regardless, so re-run the enumeration rather
# than trusting this paragraph. The filter is per LINE, so a MIXED line
# — one absolute command AND one bare command at a command-start anchor
# — is dropped whole. Confirmed by injecting one
# (`${pkgs.coreutils}/bin/printf … | head -1`) into a scanned file: the
# raw pattern matches it and `grep -v '/bin/'` removes it. Whether the
# filter is free is a property of the CORPUS, not of the regex, so the
# question is settled by re-measuring and never by re-arguing.
#
# The lesson, since it cost a round trip: this check has now had one
# filter that could NEVER match (`^\s*#` against path-prefixed output)
# and one that ALWAYS matched (`/bin/` against a corpus where every real
# target contains it). Same failure class, opposite polarity — a line
# filter whose truth value is constant across the real corpus is dead
# code either way, and only measuring it against that corpus reveals
# which kind you have.
#
# Residual limitations, stated so they are not rediscovered as bugs:
#
#   - Pattern 3 is LINE-scoped. A `versionCheck.cmd` written as a
#     multi-line Nix string, or bound through a `let` and referenced by
#     name, would evade it. None exist today, and the encouraged path is
#     `vu.ghLatestVersionCmd` in lib/packaging.nix — which IS scanned, by
#     patterns 1 and 2, as part of the named-file set.
#   - `installPhase` / `buildPhase` bare commands across `overlays/`
#     remain deliberately unscanned. They run inside stdenv with a full
#     PATH from build inputs, so absolute paths there are optional (see
#     the nix-standards fragment); flagging them would cost a suppression
#     marker per line for no risk.
{pkgs, ...}: {
  checks.bare-commands =
    pkgs.runCommandLocal "bare-commands-check" {
      nativeBuildInputs = [pkgs.ripgrep];
      src = ../..;
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
        SCAN_PATHS=(lib packages/*/lib)

        # Pattern 3 has its own, wider scan set: every .nix file under
        # packages/, recursively. It is safe to widen because the pattern
        # itself is scoped to lines mentioning versionCheck.cmd — see header.
        WRAPPER_SCAN_PATHS=(packages)
        NIX_FILES=(--glob '*.nix')

        # Pin representatives of each scan scope: a clean result otherwise
        # cannot distinguish no bare commands from the wrong file set.
        require_scan_member() {
          local expected="$1" files rc=0
          shift
          # An empty listing (status 1) still needs the missing member named.
          files=$(rg --files "''${NIX_FILES[@]}" "$@") || rc=$?
          if (( rc > 1 )); then return "$rc"; fi
          if ! grep -Fx -- "$expected" <<<"$files" >/dev/null; then
            printf 'ERROR: bare-commands scan did not select %s\n' "$expected" >&2
            return 1
          fi
        }
        require_scan_member lib/packaging.nix "''${SCAN_PATHS[@]}"
        require_scan_member packages/kiro-cli/lib/wrapPackage.nix "''${SCAN_PATHS[@]}"
        require_scan_member packages/dns-root-hints/packages/ai/generic/dns-root-hints/package.nix "''${WRAPPER_SCAN_PATHS[@]}"

        # Exit status 1 means no matches; any other error must fail the check.
        # Capture the search before filtering so a filter's no-match status
        # cannot hide a failed search.
        scan_bare_commands() {
          local pattern="$1" exclude="$2" matches rc=0
          shift 2
          matches=$(rg --no-heading -n "$pattern" "''${NIX_FILES[@]}" "$@") || rc=$?
          if (( rc == 1 )); then return 0; fi
          if (( rc != 0 )); then return "$rc"; fi
          rc=0
          matches=$(grep -vE -- "$exclude" <<<"$matches") || rc=$?
          if (( rc == 0 )); then
            FAILURES="$FAILURES
      $matches"
          fi
          (( rc <= 1 ))
        }
        SUPPRESSION='# bare-commands: ok'
        COMMENT='^[^:]*:[0-9]+:[[:space:]]*#'

        # Pattern 1: $(bare-cmd) — command substitution with a bare command.
        # The trailing \b (word boundary) rather than a literal space is what
        # makes the ARGUMENT-LESS form visible: `tmp=$(mktemp)` closes the
        # substitution immediately, so a space-anchored pattern walked straight
        # past it while catching only `$(mktemp -d …)`.
        scan_bare_commands "\\\$\(($BARE_CMDS)\b" "$SUPPRESSION" "''${SCAN_PATHS[@]}"

        # Pattern 2: bare commands in shell strings, at any of the CMD_START
        # anchors — not just line start. A line-start-only anchor missed every
        # bare command that follows a pipe (`… | cut -f1`) or an AND list
        # (`… && mv x y`), which between them are the majority of real hits.
        # Exclude: lines containing /bin/, comments, nix expressions. The
        # `/bin/` filter is a blind spot on MIXED lines and is kept only
        # because it currently subtracts four false positives and no true
        # ones — re-measure before touching it, see the header.
        #
        # The comment filter is PATH-PREFIX aware. rg emits `path:lineno:content`,
        # so a line NEVER begins with whitespace-then-hash and the anchored
        # `^\s*#` it replaces could not match anything — it excluded no comment,
        # ever. Harmless while the anchors were line-start-only (a comment opens
        # with `#`, which is not a command start), but the pipe and AND-list
        # anchors above make a COMMENT containing a piped or AND-ed bare command
        # a live false positive with nothing left to filter it. The other
        # `grep -v` filters are plain substring filters and were never affected.
        scan_bare_commands "$CMD_START($BARE_CMDS)\b" \
          "$SUPPRESSION|$COMMENT|/bin/|description|mkOption|type " "''${SCAN_PATHS[@]}"

        # Pattern 3: bare commands inside a `versionCheck.cmd` string, anywhere
        # under packages/. mkUpdateScript interpolates that string into a
        # writeShellScript wrapper the update pipeline invokes directly, so it
        # is exactly the PATH-less case — but it is authored in the per-package
        # file, which patterns 1 and 2 do not scan. Line-scoped and mechanism-
        # scoped: the wider WRAPPER_CMDS list and the wider file set are both
        # paid for by requiring `versionCheck.cmd` on the same line.
        #
        # NOTE the absent `/bin/` filter — see the header. It is not an
        # oversight and must not be "restored": it would subtract only true
        # positives here, because the anchors already exclude absolute
        # invocations structurally.
        scan_bare_commands "versionCheck\.cmd.*$WRAPPER_CMD_START($WRAPPER_CMDS)\b" \
          "$SUPPRESSION|$COMMENT" "''${WRAPPER_SCAN_PATHS[@]}"

        # Trim the leading blank line when a scan found matches.
        FAILURES="$(printf '%s\n' "$FAILURES" | sed '/^$/d')"

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
    '';
}

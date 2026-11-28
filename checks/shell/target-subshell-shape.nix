# Target-subshell shape gate — keeps errexit ARMED inside the update
# pipeline's per-target bodies.
#
# Bash disables errexit for any command whose status it tests: an `if`
# condition, a `while`/`until` condition, a `!` negation, or the left side of
# `||`/`&&`. That suppression reaches INSIDE a subshell and overrides a
# `set -e` written in the subshell itself. So this shape is a trap:
#
#     if ! ( set -euETo pipefail; false; echo REACHED ); then   # REACHED runs
#
# while this one is safe:
#
#     set +e; ( set -euETo pipefail; false; echo REACHED ); rc=$?   # rc=1
#
# The update pipeline used the trap shape from at least 2026-04-13 to
# 2026-09-09. Every bare command in a target body fell through to the
# trailing `git commit`, whose success became the target's exit status, so a
# nixpkgs bump whose build verification FAILED shipped as `UPDATED` on every
# sweep — measured on run 34351134945, which logged `UPDATED: nixpkgs` with
# zero `HELD BACK:` lines in 12,274 lines of log.
#
# Prose did not hold. The rule was written into a fragment and then broken
# twice inside two days, each time caught only by a reviewer. shellcheck has
# no diagnostic for it (CLAUDE.md says so explicitly), which is why this
# exists as a build-failing check rather than a review obligation.
#
# WHY THIS CHECK IS A GREP AND NOT A LINTER. Deciding "which failures in this
# body must abort" is a judgement call and any scanner for it needs a
# suppression marker per false positive. Deciding "is this subshell in a
# status-tested context" is syntax. Fixing the SHAPE makes errexit the
# default for every command in the body, so the only thing left to check is
# the shape — one grep, no markers, no drift.
{pkgs, ...}: {
  checks.target-subshell-shape =
    pkgs.runCommandLocal "target-subshell-shape-check" {
      nativeBuildInputs = [pkgs.ripgrep];
      src = ../..;
    } ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :

            cd "$src"

            TARGETS="dev/scripts/update-input.sh dev/scripts/update-lock.sh dev/scripts/update-pkg.sh"
            failures=""

            # The pattern must match a subshell `(` opening in a tested context while
            # NOT matching arithmetic `((`. Rust's regex engine has no lookaround, so
            # "( not followed by (" is spelled as "( followed by a non-( or EOL".
            #
            # Anchoring on `\($` was the first version and it was WRONG: it saw only
            # the multi-line form, so `if ! ( set -e; false ); then` on one line — or
            # even `if ! (  # note` — sailed straight through the gate this check
            # exists to be. Caught in review on #1576.
            # TWO patterns, because a bash subshell-as-condition has exactly two
          # written forms and a single loose one false-positives on embedded
          # awk. `if (match($0, /…/, arr) && …)` in update-pkg.sh's marker
          # scanner is awk, not shell, and a pattern that only required `(`
          # after the keyword flagged it. Both forms below require something
          # only SHELL does: end the line at the `(`, or close with `; then`/
          # `; do`.
          #
          #   multi-line:  if ! (            [optionally + trailing comment]
          #   one-line:    if ! ( … ); then
          #
          # `[^(]` in the one-liner keeps arithmetic `if (( … ))` out.
          COND_ML='^\s*(if|elif|while|until)\s+!?\s*\(\s*(#.*)?$'
          COND_OL='^\s*(if|elif|while|until)\s+!?\s*\([^(].*;\s*(then|do)\b'

            # List operators also consume the subshell's status and suppress errexit.
            LIST_OP='^\s*\)\s*(\|\||&&)'
            scan_traps() {
              local rc=0
              rg --no-filename -n -e "$COND_ML" -e "$COND_OL" -e "$LIST_OP" "$@" || rc=$?
              # rg status 1 is a clean scan; scanner errors must fail the gate.
              (( rc <= 1 ))
            }

            # Exercise the same scan as the real targets. Require the exact line hit
            # for each unsafe shape and no hit for each safe shape. The real-target
            # scan already sees the required bare opening and closing lines below,
            # along with shell function declarations and bracket tests.
            # The inline and trailing-comment cases caught the old end-of-line
            # anchor. The embedded awk row preserves the old false-positive input
            # from update-pkg.sh even if the marker scanner changes.
            while IFS='|' read -r row outcome line; do
              case "$outcome" in
                trap) expected="1:$line" ;;
                safe) expected="" ;;
                *) printf 'ERROR: fixture %s has unknown outcome %s\n' "$row" "$outcome" >&2; exit 1 ;;
              esac
              hit=$(scan_traps <<<"$line")
              if [[ $hit != "$expected" ]]; then
                failures+="FIXTURE $row: expected $outcome (hit '$expected'), got '$hit' for '$line'"$'\n'
              fi
            done <<'FIXTURES'
      reject-and-list|trap|) && echo continued
      reject-elif-condition|trap|    elif ! (
      reject-inline-condition-before-then|trap|  if ! ( set -euETo pipefail; false ); then
      reject-or-list|trap|) || target_rc=$?
      reject-toplevel-condition|trap|if ! (
      reject-trailing-comment-condition|trap|    if ! (  # trailing comment
      reject-until-inline|trap|until ( false ); do :; done
      reject-until-multiline|trap|  until (
      reject-while-condition|trap|  while ! (
      accept-arithmetic-if|safe|if (( x > 1 )); then
      accept-embedded-awk|safe|              if (match($0, /# upstream: ([A-Za-z]+) @ (.+)$/, arr) && arr[1] != "" && arr[2] != "")
      FIXTURES

            for f in $TARGETS; do
              hits=$(scan_traps "$f")
              if [ -n "$hits" ]; then
                failures+="$f: subshell status is tested by a condition or list operator:"$'\n'"$hits"$'\n'
              fi

              # Require both ordered boundaries of the standalone subshell.
              # Without a positive control, a scan could pass after the target
              # body moves, or match unrelated errexit toggles in the same file.
              if ! rg -Uq '^set \+e\n\(\n[[:blank:]]+set -euETo pipefail$' "$f"; then
                failures+="$f: expected set +e immediately before a standalone strict-mode subshell"$'\n'
              fi
              if ! rg -Uq '^\)\ntarget_rc=\$\?\nset -e$' "$f"; then
                failures+="$f: expected standalone subshell status captured before restoring errexit"$'\n'
              fi
            done

            if [ -n "$failures" ]; then
              echo "ERROR: update-pipeline target bodies must keep errexit armed."
              echo ""
              echo "$failures"
              echo "A subshell whose status bash TESTS (if / while / until / ! / || / &&)"
              echo "runs with errexit disabled, and that suppression overrides a 'set -e'"
              echo "written inside the subshell. Use the standalone form instead:"
              echo ""
              echo "    target_rc=0"
              echo "    set +e"
              echo "    ("
              echo "      set -euETo pipefail"
              echo "      ..."
              echo "    )"
              echo "    target_rc=\$?"
              echo "    set -e"
              echo ""
              echo "See dev/fragments/pipeline/update-pipeline.md for the rule."
              exit 1
            fi

            echo "Target subshells keep errexit armed."
            ${pkgs.coreutils}/bin/mkdir -p "$out"
            ${pkgs.coreutils}/bin/touch "$out/ok"
    '';
}

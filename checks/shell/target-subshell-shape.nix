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

            # ── Fixture self-test ─────────────────────────────────────────────
            #
            # A gate that silently stops discriminating is worse than no gate, so
            # prove the pattern separates the two classes BEFORE trusting it on the
            # real files. Both directions: it must catch every trap shape and must
            # not fire on arithmetic or ordinary conditionals.
            fixture_bad='if ! (
          if ! (  # trailing comment
        if ! ( set -euETo pipefail; false ); then
      if ! ( true ); then :; fi
      until ( false ); do :; done
        while ! (
        until (
          elif ! ('
            fixture_ok='if (( x > 1 )); then
          while (( i-- )); do
        if [ -n "$x" ]; then
        foo() {
          ((count++))
                    if (match($0, /# upstream: ([A-Za-z]+) @ (.+)$/, arr) \&\& arr[1] != "")'

            while IFS= read -r line; do
              [ -n "$line" ] || continue
              if ! printf '%s\n' "$line" | rg -q "$COND_ML" && ! printf '%s\n' "$line" | rg -q "$COND_OL"; then
                failures="''${failures}FIXTURE: pattern missed a trap shape: $line
        "
              fi
            done <<<"$fixture_bad"

            while IFS= read -r line; do
              [ -n "$line" ] || continue
              if printf '%s\n' "$line" | rg -q "$COND_ML" || printf '%s\n' "$line" | rg -q "$COND_OL"; then
                failures="''${failures}FIXTURE: pattern matched a safe line: $line
        "
              fi
            done <<<"$fixture_ok"


            # ── Negative scan: the trap shapes must not appear ──────────────────
            #
            # 1. `if ! (`  — a subshell as an `if` condition.
            # 2. `while ! (` / `until (` — the same suppression, other keywords.
            # 3. `) || <var>=` / `) && ` — a subshell whose status is consumed by a
            #    list operator, which suppresses errexit exactly like `if !` does.
            for f in $TARGETS; do
              if hits=$( (rg -n "$COND_ML" "$f" || true; rg -n "$COND_OL" "$f" || true) | sort -u ); [ -n "$hits" ]; then
                failures="''${failures}$f: subshell used as a status-tested condition:
          $hits
          "
              fi
              if hits=$(rg -n '^\s*\)\s*(\|\||&&)' "$f" || true); [ -n "$hits" ]; then
                failures="''${failures}$f: subshell status consumed by a list operator:
          $hits
          "
              fi
            done

            # ── Positive control: the safe shape must actually be present ───────
            #
            # Without this the negative scan passes vacuously the moment someone
            # deletes or renames a target body, and the check would report clean on a
            # file it no longer covers.
            for f in $TARGETS; do
              for needle in 'set \+e' '^\)$' 'target_rc=\$\?' '^set -e$'; do
                if ! rg -q "$needle" "$f"; then
                  failures="''${failures}$f: positive control FAILED — expected to find /$needle/, which is part of the standalone-subshell shape this check exists to preserve. Either the target body was restructured or this check is now scanning the wrong file.
          "
                fi
              done
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

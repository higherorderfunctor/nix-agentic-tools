#!/usr/bin/env bash
# validate-at-stop — Claude Code `Stop` hook. Runs at the hand-back boundary
# (after the chunk's last edit), so a formatter rewrite never races the Edit
# tool's read-snapshot. Auto-fixes formatting silently; blocks-with-reason on
# judgment lint (reaching the model); escapes loops via stop_hook_active.
# Fileset = working-tree changes (unstaged ∪ staged ∪ untracked), which fixes
# prek's staged-only blind spot at Stop time.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

payload="$(cat)"
get() { printf '%s' "$payload" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$1',''))"; }
active="$(get stop_hook_active)"
repo="$(get cwd)"
[ -n "$repo" ] && cd "$repo"

# Not a work tree — Claude Code runs anywhere, and a cwd outside a repo has
# no changeset to validate. This is the ONE git failure that is expected and
# is a legitimate no-op, so answer it explicitly and up front; every other
# git failure below is a real fault and is reported rather than absorbed.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# `git diff --quiet` is a THREE-valued signal, not a boolean: 0 = no
# difference, 1 = difference, >1 (commonly 128) = git ITSELF failed. Under
# the bare `git diff --quiet && …` form, `&&` read every non-zero status as
# "there IS a difference", so an erroring git fell through to the changeset
# scan below — where the same failing git produced an EMPTY file list and the
# hook exited 0. Validation was silently skipped, indistinguishable from a
# clean tree. Discriminate by value instead; `|| rc=$?` is the one place
# errexit is suppressed, so the ordinary exit-1 path still cannot kill the
# hook. Exit 1 rather than git's own status on error: a Stop hook's exit 2 is
# the reserved block-with-reason channel, and a git fault must not land on it
# by coincidence.
diff_quiet() {
  local rc=0
  git "$@" --quiet || rc=$?
  case "$rc" in
  0 | 1) return "$rc" ;;
  *)
    echo "validate-at-stop: git $* --quiet failed (exit $rc); refusing to" \
      "read a git error as a diff answer" >&2
    exit 1
    ;;
  esac
}

# (1) no-diff early exit — pure-conversation turns cost nothing
if diff_quiet diff && diff_quiet diff --cached; then
  # `git ls-files` is only TWO-valued, but its ANSWER arrives on stdout, so a
  # failure yields an EMPTY capture that `[ -z … ]` reads as "no untracked
  # files" — the same silent skip by another route, and it is the ONLY thing
  # holding the gate open when the whole changeset is untracked. Check the
  # status, not just the string.
  #
  # The capture cannot stay inside the `&&` chain above. A helper that
  # `exit`s would run inside `$( … )`, so the exit would kill only that
  # command-substitution subshell and the empty string would answer the test
  # anyway — the guard would read as correct and do nothing.
  untracked_rc=0
  untracked=$(git ls-files --others --exclude-standard) || untracked_rc=$?
  if [ "$untracked_rc" -ne 0 ]; then
    echo "validate-at-stop: git ls-files --others --exclude-standard failed" \
      "(exit $untracked_rc); refusing to read a git error as an empty" \
      "changeset" >&2
    exit 1
  fi
  [ -n "$untracked" ] || exit 0
fi

# working-tree changeset (unstaged ∪ staged ∪ untracked), NUL-safe
mapfile -d '' -t files < <(
  {
    git diff -z --name-only
    git diff -z --cached --name-only
    git ls-files -z --others --exclude-standard
  } | sort -zu
)
[ "${#files[@]}" -eq 0 ] && exit 0

# Drop deleted paths — a nonexistent file makes the linters error (false block).
existing=()
for f in "${files[@]}"; do [ -e "$f" ] && existing+=("$f"); done
files=("${existing[@]}")
[ "${#files[@]}" -eq 0 ] && exit 0

# (2) auto-fix formatting SILENTLY (reuse git-hooks treefmt config). Never blocks.
prek run treefmt --files "${files[@]}" >/dev/null 2>&1 || true
git add -u -- "${files[@]}" >/dev/null 2>&1 || true

# (3) judgment lint over the same changeset, reusing git-hooks config/excludes.
# Keep this id list in sync with the judgment hooks in devenv.nix `git-hooks.hooks`
# (treefmt is the auto-fix above; gitleaks/convco are commit-time only).
read -r -a judgment <<<"${JUDGMENT_HOOKS_OVERRIDE:-cspell deadnix shellcheck statix}"
report=""
for id in "${judgment[@]}"; do
  if ! out="$(prek run "$id" --files "${files[@]}" 2>&1)"; then
    report="${report}### ${id}"$'\n'"${out}"$'\n\n'
  fi
done

if [ -n "$report" ]; then
  if [ "$active" = "True" ]; then
    # loop-guard: already continued once — do not trap on a persistent finding.
    printf '%s\n' '{"systemMessage":"validate-at-stop: findings persist after one fix pass; allowing stop. Review the working tree."}'
    exit 0
  fi
  python3 - "$report" <<'PY'
import json, sys
reason = ("validate-at-stop found lint findings before hand-back "
          "(these also run at commit + CI):\n\n" + sys.argv[1] +
          "Fix them; if a cspell word is legitimate add it to "
          "config/cspell/project-terms.txt (sorted insert), then finish.")
print(json.dumps({"decision": "block", "reason": reason}))
PY
  exit 0
fi
exit 0

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

# (1) no-diff early exit — pure-conversation turns cost nothing
if git diff --quiet && git diff --cached --quiet &&
  [ -z "$(git ls-files --others --exclude-standard)" ]; then
  exit 0
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

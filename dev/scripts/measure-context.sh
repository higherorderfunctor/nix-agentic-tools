#!/usr/bin/env bash
# Measure always-loaded steering token budget for each
# ecosystem. Runs from repo root. Token count is approximate
# (wc -w as a proxy — claude's tokenizer is different but
# word-count is proportional for English prose).
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

cd "$(git rev-parse --show-toplevel)"

report() {
  local label=$1
  shift
  local total_lines=0
  local total_words=0
  for f in "$@"; do
    if [ -f "$f" ]; then
      lines=$(wc -l <"$f")
      words=$(wc -w <"$f")
      printf '  %-50s %5d lines  %6d words\n' "$f" "$lines" "$words"
      total_lines=$((total_lines + lines))
      total_words=$((total_words + words))
    else
      printf '  %-50s MISSING\n' "$f"
    fi
  done
  printf '  %-50s %5d lines  %6d words (total)\n' "== $label ==" "$total_lines" "$total_words"
  printf '\n'
}

echo "=== Always-loaded steering budget ==="
printf '\n'

# Always-on rules (no `paths:` key) load with the context, so they count.
claude_always=()
for f in .claude/rules/*.md; do
  [ -f "$f" ] || continue
  grep -q '^paths:' "$f" || claude_always+=("$f")
done

report "Claude" \
  .claude/CLAUDE.md \
  "${claude_always[@]}"

report "Copilot" \
  .github/copilot-instructions.md \
  .github/instructions/stacked-workflows-router.instructions.md

report "AGENTS.md (Codex, Kiro, Kimchi)" \
  AGENTS.md

echo "=== Source monorepo fragments (composed into the orientation) ==="
printf '\n'
for f in dev/fragments/monorepo/*.md; do
  lines=$(wc -l <"$f")
  words=$(wc -w <"$f")
  printf '  %-60s %5d lines  %6d words\n' "$f" "$lines" "$words"
done

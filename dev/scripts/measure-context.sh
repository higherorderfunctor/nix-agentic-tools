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

report "Claude" \
	CLAUDE.md \
	.claude/rules/common.md

report "Copilot" \
	.github/copilot-instructions.md

report "Kiro" \
	.kiro/steering/common.md

report "AGENTS.md (Codex + flat consumers)" \
	AGENTS.md

echo "=== Source monorepo fragments (composed into common.md) ==="
printf '\n'
for f in dev/fragments/monorepo/*.md; do
	lines=$(wc -l <"$f")
	words=$(wc -w <"$f")
	printf '  %-60s %5d lines  %6d words\n' "$f" "$lines" "$words"
done

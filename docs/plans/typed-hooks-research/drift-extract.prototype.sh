#!/usr/bin/env bash
# PROTOTYPE (scratchpad, not committed): validates the §10 hook-surface drift
# mechanism end-to-end against the pinned binaries. Advisory model, mirrors
# checks/model-staleness-claude.nix. Emits draft hooks-surface.json sidecars.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

repo="/home/caubut/Documents/projects/nix-agentic-tools"
out="/tmp/claude-1000/-home-caubut-Documents-projects-nix-agentic-tools/2e94ecbf-e0c4-4828-9fef-e69f6903aab0/scratchpad/sidecars"
mkdir -p "$out"
today="$(date +%Y-%m-%d)"

claude="$(nix build "$repo#claude-code" --no-link --print-out-paths 2>/dev/null)/bin/claude"
kiro="/nix/store/p1nz5dw1my6yd6qp5q2hami3sfjy6qag-kiro-cli-2.13.0/bin/.kiro-cli-chat-wrapped"
[ -e "$kiro" ] || kiro="$(nix build "$repo#kiro-cli" --no-link --print-out-paths 2>/dev/null)/bin/.kiro-cli-chat-wrapped"
cver="$(python3 -c 'import json;print(json.load(open("'"$repo"'/overlays/claude-code-sources.json"))["version"])')"
kver="$(python3 -c 'import json;print(json.load(open("'"$repo"'/overlays/kiro-cli-sources.json"))["version"])')"

# --- Claude: extract the event enum from the binary (RELIABLE anchor) ---
mapfile -t claude_events < <(grep -aoE '"PreToolUse"(,"[A-Za-z]+")+' "$claude" |
  grep -aoE '"[A-Za-z]+"' | tr -d '"' | sort -u)
# Curated subset we would type first (classic load-bearing 9).
claude_typed=(PreToolUse PostToolUse UserPromptSubmit Notification Stop SubagentStop PreCompact SessionStart SessionEnd)

# --- Kiro: probe documented-v3 triggers for binary presence ---
kiro_documented=(SessionStart Stop PreToolUse PostToolUse UserPromptSubmit Manual AgentSpawn PreTaskExec PostTaskExec PostFileCreate PostFileSave PostFileDelete)

echo "#################### DRIFT REPORT ($today) ####################"
echo "## CLAUDE claude-code $cver — binary embeds ${#claude_events[@]} events"
# advisory: events in binary but NOT in our curated typed set
missing_from_typed=()
for e in "${claude_events[@]}"; do
  hit=0
  for t in "${claude_typed[@]}"; do [ "$e" = "$t" ] && hit=1 && break; done
  [ "$hit" -eq 0 ] && missing_from_typed+=("$e")
done
echo "  [advisory] ${#missing_from_typed[@]} binary events NOT in the curated typed set (freeform tail):"
printf '    %s\n' "${missing_from_typed[@]}" | paste -sd' ' -
# blocking: a typed event MISSING from the binary = correctness bug
echo "  [blocking] typed events absent from binary (would be a bug):"
bug=0
for t in "${claude_typed[@]}"; do
  grep -aqoF "\"$t\"" "$claude" || {
    echo "    MISSING: $t"
    bug=1
  }
done
[ "$bug" -eq 0 ] && echo "    none — all curated typed events present"

echo "## KIRO kiro-cli $kver — documented-v3 triggers vs binary presence"
for t in "${kiro_documented[@]}"; do
  n="$(grep -acF "$t" "$kiro" 2>/dev/null || true)"
  [ "$n" -gt 0 ] && st="present" || st="ABSENT(doc-ahead?)"
  printf '    %-18s %-18s (%s literal hits)\n' "$t" "$st" "$n"
done

# --- Emit draft sidecars (the SSOT + provenance store) ---
python3 - "$out" "$today" "$cver" "$kver" "${claude_events[*]}" <<'PY'
import json,sys
out,today,cver,kver,cev = sys.argv[1:6]
claude_events=cev.split()
typed9=["PreToolUse","PostToolUse","UserPromptSubmit","Notification","Stop","SubagentStop","PreCompact","SessionStart","SessionEnd"]
json.dump({
 "cli":"claude-code","schemaVersion":1,
 "provenance":{"binaryVersion":cver,"binarySource":"overlays/claude-code-sources.json",
   "docsUrl":"https://code.claude.com/docs/en/hooks","lastVerifiedVersion":cver,"lastVerifiedDate":today,
   "notes":"binary-grep authoritative for EVENT ENUM only; field names (e.g. stop_hook_active, permissionDecision) do NOT reliably appear as literals — use docs snapshot for stdin/stdout schema."},
 "typedEvents":typed9,
 "binaryEventVocabulary":sorted(claude_events),
}, open(out+"/claude-code.hooks-surface.json","w"), indent=1)
# Kiro: implemented-set is the binary-present subset of the documented triggers
kiro_present=["SessionStart","Stop","PreToolUse","PostToolUse","UserPromptSubmit","Manual","AgentSpawn"]
json.dump({
 "cli":"kiro-cli","schemaVersion":1,
 "provenance":{"binaryVersion":kver,"binarySource":"overlays/kiro-cli-sources.json",
   "docsUrls":["https://kiro.dev/docs/cli/hooks/ (Jun5, 5 triggers)","https://kiro.dev/docs/cli/v3/hooks/ (Jun17, 11 triggers)"],
   "lastVerifiedVersion":kver,"lastVerifiedDate":today,
   "notes":"THREE-WAY conflict: Jun5 docs=5, Jun17 docs=11, binary=~6 present. PreTaskExec/PostTaskExec/PostFile{Create,Save,Delete} ABSENT as literals in 2.13.0 (fragments taskExec/fileSaved exist). SessionStart+Manual present-but-undocumented-on-Jun5. Needs live TUI probe to confirm which fire."},
 "typedEvents_binaryPresent":kiro_present,
 "documentedButAbsentInBinary":["PreTaskExec","PostTaskExec","PostFileCreate","PostFileSave","PostFileDelete"],
}, open(out+"/kiro-cli.hooks-surface.json","w"), indent=1)
print("wrote",out+"/claude-code.hooks-surface.json")
print("wrote",out+"/kiro-cli.hooks-surface.json")
PY
echo "#################### END ####################"

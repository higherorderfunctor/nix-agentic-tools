#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: capture.sh <case>...   (or: capture.sh all)
# Re-runs the system-prompt capture cases (codex:P; inputs to codex:A and codex:C) into
# <work> = $PROBE_OUT/claude-sysprompt or a fresh temp dir, printed at the end.
# Each case specifies its argv, stdin, environment and mock reply plan.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# -eq 0 ]]; then
  sed -n '2,/^here=/p' "${BASH_SOURCE[0]}" | sed -n 's/^# \{0,1\}//p'
  exit 2
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$here/../../common/pin.sh"
work="$(probe_workdir claude-sysprompt)"
export CLAUDE_BIN="${CLAUDE_BIN:-$(probe_pkg claude-code)/bin/claude}"
P=(-p --no-session-persistence --model haiku)
APP=(--append-system-prompt "Inline append sentinel: APPINLINE-1313.")
SUB=(--append-subagent-system-prompt "Subagent append: SUBAPP-1414.")
SDK=(--input-format stream-json --output-format stream-json --verbose)
SID=7d0c5b0e-1111-4222-8333-944455556666
# shellcheck disable=SC2016 # $ARGUMENTS is the hook template variable, not shell
HOOKS='{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"prompt","prompt":"Hook prompt sentinel HOOKP-1616: $ARGUMENTS"}]}],"Stop":[{"hooks":[{"type":"agent","prompt":"Agent hook sentinel HOOKA-1717: $ARGUMENTS"}]}]}}'
run() { "$here/run.sh" "$work" "$@"; }
one() {
  case "$1" in
  k2-baseline) run "$1" - -- "${P[@]}" "${APP[@]}" hello ;;
  k3-sdk) STDIN_FILE=$here/sdk-in.jsonl run "$1" "$here/plan-sdk.json" -- "${P[@]}" "${SDK[@]}" "${APP[@]}" --allowedTools Agent ;;
  k3-sdk-env) CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT=1 STDIN_FILE=$here/sdk-in.jsonl run "$1" "$here/plan-sdk.json" -- "${P[@]}" "${SDK[@]}" --allowedTools Agent ;;
  k3-sdk-noapp) STDIN_FILE=$here/sdk-in3.jsonl run "$1" - -- "${P[@]}" "${SDK[@]}" --append-system-prompt-file "$here/append.md" ;;
  k3-sdk-sys) STDIN_FILE=$here/sdk-in2.jsonl run "$1" - -- "${P[@]}" "${SDK[@]}" --append-system-prompt-file "$here/append.md" --system-prompt "CLI sys: SYSINLINE-2020." ;;
  k4-agents) run "$1" "$here/plan-agents.json" -- "${P[@]}" --allowedTools Agent "${APP[@]}" --append-system-prompt-file "$here/append.md" "SPAWNALL now" ;;
  k6-fork) CLAUDE_CODE_FORK_SUBAGENT=1 run "$1" "$here/plan-fork.json" -- "${P[@]}" --allowedTools Agent "${APP[@]}" "${SUB[@]}" SPAWN ;;
  k6-nested) run "$1" "$here/plan-nest.json" -- "${P[@]}" --allowedTools Agent "${SUB[@]}" SPAWN ;;
  k7-workflow) run "$1" "$here/plan-wf.json" -- "${P[@]}" --allowedTools Agent Workflow "${APP[@]}" "${SUB[@]}" "WFSPAWN ultracode" ;;
  k8-hooks) run "$1" - -- "${P[@]}" "${APP[@]}" --settings "$HOOKS" hi ;;
  p1-sysprompt) run "$1" "$here/plan-gp.json" -- "${P[@]}" --allowedTools Agent --system-prompt "Replacement inline: SYSINLINE-2020." "${APP[@]}" SPAWN ;;
  p2-dups) run "$1" - -- "${P[@]}" --allowedTools Agent --system-prompt-file "$here/sysrepl.md" --system-prompt "Replacement inline: SYSINLINE-2020." --append-system-prompt "First inline: APPONE-3030." --append-system-prompt "Second inline: APPTWO-4040." hi ;;
  p2b-twosys) run "$1" - -- "${P[@]}" --allowedTools Agent --system-prompt "First sys: SYSONE-5050." --system-prompt "Second sys: SYSTWO-6060." hi ;;
  p3-agent-named) run "$1" "$here/plan-gp.json" -- "${P[@]}" --allowedTools Agent --agent named-agent --system-prompt "Replacement inline: SYSINLINE-2020." "${APP[@]}" SPAWN ;;
  p4-agent-claude) run "$1" - -- "${P[@]}" --allowedTools Agent --agent claude "${APP[@]}" hi ;;
  p5-subappend) run "$1" "$here/plan-gp.json" -- "${P[@]}" --allowedTools Agent "${SUB[@]}" "${APP[@]}" SPAWN ;;
  p6-agentsjson) run "$1" "$here/plan-json.json" -- "${P[@]}" --allowedTools Agent --agents '{"jsonagent":{"description":"json agent JSONDESC-8080","prompt":"JSON agent body: JSONBODY-8181."}}' SPAWN ;;
  p7-style) run "$1" "$here/plan-gp.json" -- "${P[@]}" --allowedTools Agent --settings '{"outputStyle":"sentinel-style"}' "${APP[@]}" SPAWN ;;
  p7b-stylekeep) run "$1" - -- "${P[@]}" --allowedTools Agent --settings '{"outputStyle":"keep-style"}' hi ;;
  p8-bare) run "$1" - -- "${P[@]}" --allowedTools Agent --bare "${APP[@]}" hi ;;
  p9-noappend) run "$1" - -- "${P[@]}" --allowedTools Agent -- hi ;;
  p9b-exdyn) run "$1" - -- "${P[@]}" --allowedTools Agent --exclude-dynamic-system-prompt-sections hi ;;
  p10-agentonly) run "$1" - -- "${P[@]}" --allowedTools Agent --agent named-agent "${APP[@]}" hi ;;
  p10b-agentsetting) run "$1" - -- "${P[@]}" --allowedTools Agent --settings '{"agent":"named-agent"}' hi ;;
  snap1) run "$1" - -- -p --model haiku --session-id "$SID" --append-system-prompt "Version one: APPVONE-2121." first ;;
  snap2) run "$1" - -- -p --model haiku --resume "$SID" --append-system-prompt "Version two: APPVTWO-2222." second ;;
  snap3) run "$1" - -- -p --model haiku --resume "$SID" --system-prompt-snapshot off --append-system-prompt "Version three: APPVTHREE-2323." third ;;
  *)
    printf 'unknown case: %s\n' "$1" >&2
    return 2
    ;;
  esac
}
if [[ $1 == all ]]; then
  set -- k2-baseline k3-sdk k3-sdk-env k3-sdk-noapp k3-sdk-sys k4-agents k6-fork k6-nested k7-workflow k8-hooks \
    p1-sysprompt p2-dups p2b-twosys p3-agent-named p4-agent-claude p5-subappend p6-agentsjson p7-style p7b-stylekeep \
    p8-bare p9-noappend p9b-exdyn p10-agentonly p10b-agentsetting snap1 snap2 snap3
fi
for c in "$@"; do
  printf '== %s\n' "$c"
  one "$c"
done
printf 'work: %s\n' "$work"

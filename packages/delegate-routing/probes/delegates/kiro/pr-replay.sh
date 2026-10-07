#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# Prompt-reach replays (pr-* cases): headless (chat --v3 --no-interactive) and ACP (acp --agent-engine v3)
# side by side. usage: [KIRO_PKG=<store path>] [PROBE_OUT=<dir>] pr-replay.sh [id ...]   (no id = all)
# Each id runs wire2.sh once into <out>/<id>/kiro/<case>/run, writes summary.txt there (reach.py lines,
# unique tool results, ACP call/prompt results) and checks it: "ok"/"FAIL" per expectation, exit 1 on any FAIL.
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${PROBE_OUT:-$(mktemp -d -t delegate-probe-kiro-pr.XXXXXX)}"
# Marker order is the order of the "hits:" fields that the patterns below match.
M=(GLOBAL_STEERING_SENTINEL ROOT_AGENTS_MD_SENTINEL DUP_TEXT_SENTINEL ACP_INLINE_STEERING_SENTINEL
  KDEFAULT_USER_SENTINEL VIBE_USER_SENTINEL WS_CUSTOM_PROMPT_SENTINEL ACP_CUSTOM_PROMPT_SENTINEL
  ACP_INLINE_AGENT_PROMPT_SENTINEL CUSTOM_PROMPT_SENTINEL GEN_BODY_SENTINEL GEN_APPEND_SENTINEL
  FILEP_PROMPT_SENTINEL MDAGENT_BODY_SENTINEL HOOKED_PROMPT_SENTINEL HOOKEDCA_PROMPT_SENTINEL
  ORCH_INLINE_SYS_SENTINEL DUPAGENT_BODY_SENTINEL HOOK_AGENTSPAWN_SENTINEL HOOKCA_AGENTSPAWN_SENTINEL
  HOOK_UPS_SENTINEL HOOKCA_UPS_SENTINEL SUMMARY_SENTINEL GENERIC_REPLY_SENTINEL "automated summarization request"
  "conversation was summarized" "<first_message>" USER_SENTINEL_1 USER_SENTINEL_2)
ACP3=(acp --agent-engine v3 --auth-method cli)
HL=(chat --v3 --no-interactive -a)
WF=(SETTINGS='{"chat.enableWorkflows":true}' CASE_ENV="KIRO_ENABLED_FEATURES=workflows KIRO_ROLLOUT_FEATURES=workflows")
fails=0
sum=""

# run <id> <case> [VAR=value ...] -- <kiro-cli-chat args...>
run() {
  local id=$1 case=$2 envs=()
  shift 2
  while [[ $1 != -- ]]; do
    envs+=("$1")
    shift
  done
  shift
  env "${envs[@]}" PROBE_OUT="$out/$id" "$S/wire2.sh" "$case" -- "$@" >/dev/null
  local r="$out/$id/kiro/$case/run"
  sum="$r/summary.txt"
  {
    python3 "$S/reach.py" "$r/wire.jsonl" "${M[@]}"
    python3 "$S/toolres.py" "$r/wire.jsonl" | grep TOOL_RESULT | sort -u || :
    if [[ -f $r/acp.log ]]; then grep -E '^ *[0-9.]+ (call|prompt) ' "$r/out.txt" || :; fi
  } >"$sum"
  printf '== %s  %s\n' "$id" "$sum"
}

expect() {
  if grep -Eq -- "$1" "$sum"; then printf '   ok    %s\n' "$1"; else
    printf '   FAIL  %s\n' "$1"
    fails=$((fails + 1))
  fi
}

refute() {
  if grep -Eq -- "$1" "$sum"; then
    printf '   FAIL  absent: %s\n' "$1"
    fails=$((fails + 1))
  else printf '   ok    absent: %s\n' "$1"; fi
}

case_pr-hl-invoke() {
  run pr-hl-invoke pr-hl-invoke T=180 -- "${HL[@]}" "MAIN_KICKOFF USER_SENTINEL_1"
  expect 'base@1700 .*hits: GLOBAL_STEERING_SENTINEL:h0@308 ROOT_AGENTS_MD_SENTINEL:h0@1656 USER_SENTINEL_1:cur'
  expect 'h0len=6[0-9]{3} base@-1 .*hits: GLOBAL_STEERING_SENTINEL:h0@308 ROOT_AGENTS_MD_SENTINEL:h0@1656$'
  expect 'base@-1 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 GEN_BODY_SENTINEL:h0@1700 GEN_APPEND_SENTINEL:h0@1719$'
  expect 'base@-1 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 FILEP_PROMPT_SENTINEL:h0@1700$'
  expect 'base@-1 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 MDAGENT_BODY_SENTINEL:h0@1700$'
  expect 'base@-1 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 HOOKED_PROMPT_SENTINEL:h0@1700$'
  expect 'base@-1 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 HOOKEDCA_PROMPT_SENTINEL:h0@1700$'
  refute 'HOOKC?A?_(AGENTSPAWN|UPS)_SENTINEL'
}

case_pr-hl-named() {
  run pr-hl-named pr-hl-named T=180 -- "${HL[@]}" --agent gen "MAIN_KICKOFF USER_SENTINEL_1"
  expect '^#1 .*base@-1 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 GEN_BODY_SENTINEL:h0@1700 GEN_APPEND_SENTINEL:h0@1719 USER_SENTINEL_1:cur'
  expect 'base@-1 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 CUSTOM_PROMPT_SENTINEL:h0@1700$'
  expect "TOOL_RESULT tu_0 status=error .*Agent 'general-task-execution' not found in registry"
}

case_pr-acp-invoke() {
  run pr-acp-invoke pr-acp-invoke T=240 -- "${ACP3[@]}"
  expect 'base@2139 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 ACP_INLINE_STEERING_SENTINEL:h0@2091 USER_SENTINEL_1:cur'
  expect 'base@-1 .*ACP_INLINE_STEERING_SENTINEL:h0@2091 GEN_BODY_SENTINEL:h0@2139 GEN_APPEND_SENTINEL:h0@2158$'
  expect 'base@-1 .*ACP_INLINE_STEERING_SENTINEL:h0@2091 ACP_INLINE_AGENT_PROMPT_SENTINEL:h0@2139$'
  expect 'base@-1 .*ACP_INLINE_STEERING_SENTINEL:h0@2091 HOOKEDCA_PROMPT_SENTINEL:h0@2139$'
  refute 'HOOKC?A?_(AGENTSPAWN|UPS)_SENTINEL'
}

case_pr-acp-named() {
  run pr-acp-named pr-acp-named T=240 -- "${ACP3[@]}"
  expect '^#1 .*base@-1 .*ACP_INLINE_STEERING_SENTINEL:h0@2091 GEN_BODY_SENTINEL:h0@2139 GEN_APPEND_SENTINEL:h0@2158 USER_SENTINEL_1:cur'
  expect 'base@-1 .*ACP_INLINE_STEERING_SENTINEL:h0@2091 CUSTOM_PROMPT_SENTINEL:h0@2139$'
  expect "TOOL_RESULT tu_0 status=error .*Agent 'general-task-execution' not found in registry"
}

case_pr-acp-orch() {
  run pr-acp-orch pr-acp-orch T=240 -- "${ACP3[@]}"
  expect 'base@-1 .*ACP_INLINE_STEERING_SENTINEL:h0@2091 ORCH_INLINE_SYS_SENTINEL:h0@2139$'
  expect 'base@-1 .*ACP_INLINE_STEERING_SENTINEL:h0@2091 ACP_INLINE_AGENT_PROMPT_SENTINEL:h0@2139$'
  expect 'base@-1 .*ACP_INLINE_STEERING_SENTINEL:h0@2091 GEN_BODY_SENTINEL:h0@2139 GEN_APPEND_SENTINEL:h0@2158$'
  expect 'base@-1 .*ACP_INLINE_STEERING_SENTINEL:h0@2091 HOOKEDCA_PROMPT_SENTINEL:h0@2139$'
  refute 'HOOKC?A?_(AGENTSPAWN|UPS)_SENTINEL'
}

case_pr-acp-hooked() {
  run pr-acp-hooked pr-acp-hooked T=90 -- "${ACP3[@]}"
  expect 'HOOKED_PROMPT_SENTINEL:h0@1700 HOOK_AGENTSPAWN_SENTINEL:h0@[0-9]+ HOOK_UPS_SENTINEL:cur'
}

case_pr-hl-wf() {
  run pr-hl-wf pr-hl-wf "${WF[@]}" T=120 -- "${HL[@]}" "MAIN_KICKOFF USER_SENTINEL_1"
  expect 'base@-1 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 GEN_BODY_SENTINEL:h0@1700 GEN_APPEND_SENTINEL:h0@1719 USER_SENTINEL_1:cur'
  expect 'HOOKED_PROMPT_SENTINEL:h0@1700 HOOK_AGENTSPAWN_SENTINEL:h0@[0-9]+ HOOK_UPS_SENTINEL:cur USER_SENTINEL_1:cur'
  expect 'HOOKEDCA_PROMPT_SENTINEL:h0@1700 HOOKCA_AGENTSPAWN_SENTINEL:h0@[0-9]+ HOOKCA_UPS_SENTINEL:cur USER_SENTINEL_1:cur'
  expect "tw_wf-fc-out status=error .*fileCheck path '/nonexistent-outside/status.json' that resolves outside the allowed workspace roots \(.*/pr-hl-wf/run/ws\)"
  expect "tw_wf-inl status=error .*custom agent 'inlagent' which is not registered"
  expect 'tw_wf-fc-in status=success'
}

case_pr-acp-wf() {
  run pr-acp-wf pr-acp-wf "${WF[@]}" T=120 -- "${ACP3[@]}"
  expect 'base@-1 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 GEN_BODY_SENTINEL:h0@1700 GEN_APPEND_SENTINEL:h0@1719 USER_SENTINEL_1:cur'
  expect 'HOOKCA_AGENTSPAWN_SENTINEL:h0@[0-9]+ HOOKCA_UPS_SENTINEL:cur'
  refute 'ACP_INLINE_STEERING_SENTINEL:h0@2091 (CUSTOM_PROMPT|GEN_BODY|HOOKED_PROMPT|HOOKEDCA_PROMPT)'
  expect "tw_wf-fc-out status=error .*outside the allowed workspace roots \(.*/pr-acp-wf/run/ws\)"
  expect '"name": "wf-fc-in", "workflowName": "wf-fc-in", "status": "completed"'
  expect '"name": "wf-inl", "workflowName": "wf-inl", "status": "failed"'
}

case_pr-kdefault() {
  run pr-kdefault pr-kdefault T=90 -- "${HL[@]}" "hello USER_SENTINEL_1"
  expect '^#1 .*base@1700 '
  refute 'KDEFAULT_USER_SENTINEL'
}

case_pr-kdefault-sel() {
  run pr-kdefault-sel pr-kdefault T=90 -- "${HL[@]}" --agent kiro_default "hello USER_SENTINEL_1"
  expect '^#1 .*base@-1 .*KDEFAULT_USER_SENTINEL:h0@1700'
}

case_pr-vibe() {
  run pr-vibe pr-vibe T=90 -- "${HL[@]}" "hello USER_SENTINEL_1"
  expect '^#1 .*base@1700 '
  refute 'VIBE_USER_SENTINEL'
}

case_pr-vibe-sel() {
  run pr-vibe-sel pr-vibe T=90 -- "${HL[@]}" --agent vibe "hello USER_SENTINEL_1"
  expect '^#1 .*base@1700 '
  refute 'VIBE_USER_SENTINEL'
}

case_pr-acp-shadow() {
  run pr-acp-shadow pr-acp-shadow T=90 -- "${ACP3[@]}"
  expect '^#1 .*base@1700 '
  refute 'KDEFAULT_USER_SENTINEL|VIBE_USER_SENTINEL'
}

case_pr-hl-collide() {
  run pr-hl-collide pr-hl-collide T=90 -- "${HL[@]}" --agent custom "hello USER_SENTINEL_1"
  expect 'WS_CUSTOM_PROMPT_SENTINEL:h0@1700 CUSTOM_PROMPT_SENTINEL:h0@1703 '
}

case_pr-acp-collide() {
  run pr-acp-collide pr-acp-collide T=90 -- "${ACP3[@]}"
  expect 'ACP_CUSTOM_PROMPT_SENTINEL:h0@1700 CUSTOM_PROMPT_SENTINEL:h0@1704 '
}

case_pr-hl-compact() {
  run pr-hl-compact pr-hl-compact CASE_ENV=KIRO_FEATURE_SESSION_TITLE_LLM_ENABLED=true T=90 -- "${HL[@]}" "MAIN_KICKOFF USER_SENTINEL_1"
  expect "hist=0 h0len=0 base@-1 cache=- first=.You write a short title for a coding assistant session.*hits: <first_message>:cur USER_SENTINEL_1:cur$"
  expect 'base@1700 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 automated summarization request:cur'
  expect 'base@1700 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 SUMMARY_SENTINEL:cur conversation was summarized:cur$'
}

case_pr-hl-compact-agent() {
  run pr-hl-compact-agent pr-hl-compact CASE_ENV=KIRO_FEATURE_SESSION_TITLE_LLM_ENABLED=true T=90 -- "${HL[@]}" --agent gen "MAIN_KICKOFF USER_SENTINEL_1"
  expect 'base@-1 .*GEN_APPEND_SENTINEL:h0@1719 automated summarization request:cur'
  expect 'base@-1 .*GEN_APPEND_SENTINEL:h0@1719 SUMMARY_SENTINEL:cur conversation was summarized:cur$'
}

case_pr-acp-compact() {
  run pr-acp-compact pr-acp-compact CASE_ENV=KIRO_FEATURE_SESSION_TITLE_LLM_ENABLED=true T=150 -- "${ACP3[@]}"
  expect "hist=0 h0len=0 base@-1 cache=- first=.You write a short title"
  expect 'base@2139 .*ACP_INLINE_STEERING_SENTINEL:h0@2091 .*automated summarization request:cur'
  expect 'base@2139 .*ACP_INLINE_STEERING_SENTINEL:h0@2091 GENERIC_REPLY_SENTINEL:cur conversation was summarized:cur USER_SENTINEL_2:cur$'
  expect 'call _kiro/session/compact .*"success": true'
}

case_pr-hl-dup() {
  run pr-hl-dup pr-hl-dup T=90 -- "${HL[@]}" "hello USER_SENTINEL_1"
  expect '^#1 .*base@2469 cache=- .*DUP_TEXT_SENTINEL:h0@655,h0@1984 '
}

case_pr-hl-dup-agent() {
  run pr-hl-dup-agent pr-hl-dup T=90 -- "${HL[@]}" --agent dupagent "hello USER_SENTINEL_1"
  expect '^#1 .*base@-1 cache=- .*DUP_TEXT_SENTINEL:h0@655,h0@1984,h0@2469 .*DUPAGENT_BODY_SENTINEL:h0@2488'
}

all=(pr-hl-invoke pr-hl-named pr-acp-invoke pr-acp-named pr-acp-orch pr-acp-hooked pr-hl-wf pr-acp-wf
  pr-kdefault pr-kdefault-sel pr-vibe pr-vibe-sel pr-acp-shadow pr-hl-collide pr-acp-collide pr-hl-compact
  pr-hl-compact-agent pr-acp-compact pr-hl-dup pr-hl-dup-agent)
ids=("$@")
if ((${#ids[@]} == 0)); then ids=("${all[@]}"); fi
for id in "${ids[@]}"; do "case_$id"; done
# No request in any run carries a client cache breakpoint.
if grep -l -E 'cachePoint|clientCacheConfig' "$out"/*/kiro/*/run/wire.jsonl 2>/dev/null; then
  printf 'FAIL  cache fields present\n'
  fails=$((fails + 1))
else printf 'ok    no cachePoint/clientCacheConfig in any captured request\n'; fi
printf 'out=%s fails=%s\n' "$out" "$fails"
((fails == 0))

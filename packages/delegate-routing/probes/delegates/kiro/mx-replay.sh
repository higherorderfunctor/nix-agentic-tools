#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# Prompt-surface and delegate-control replays (mx-* cases) for the v3 engine: file-match / manual / auto
# steering, host prompt fields, output style, agent resources, userPromptSubmit exit codes, mode and wf-*
# prompts, inline-agent settings, unanswered permissions, workflow-step permissions, child transcripts and
# user_input, resume prompt snapshots and the `serve` WebSocket server.
# usage: [KIRO_PKG=<store path>] [PROBE_OUT=<dir>] mx-replay.sh [id ...]   (no id = all)
# Each id runs wire2.sh into <out>/<id>/kiro/<case>/run, writes summary.txt there (reach.py and wiresum.py
# lines, unique tool results, ACP call/prompt/sh/wait results, permission and userInput frames) and checks it:
# "ok"/"FAIL" per expectation, exit 1 on any FAIL.
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${PROBE_OUT:-$(mktemp -d -t delegate-probe-kiro-mx.XXXXXX)}"
ACP3=(acp --agent-engine v3 --auth-method cli)
HL=(chat --v3 --no-interactive)
WF=(SETTINGS='{"chat.enableWorkflows":true}' CASE_ENV="KIRO_ENABLED_FEATURES=workflows KIRO_ROLLOUT_FEATURES=workflows")
fails=0
sum=""
run_dir=""

# summarize <run> <markers…>: rewrite <run>/summary.txt from the run's captures
summarize() {
  local r=$1
  shift
  {
    python3 "$S/reach.py" "$r/wire.jsonl" "$@"
    python3 "$S/wiresum.py" "$r/wire.jsonl" "$@" | grep 'rule=' || :
    python3 "$S/toolres.py" "$r/wire.jsonl" | grep TOOL_RESULT | sort -u || :
    grep -E -A3 '^ *[0-9.]+ (new|call|prompt|wait|sh|notify) ' "$r/out.txt" || :
    if [[ -f $r/acp.log ]]; then grep -E 'request_permission|"_kiro/userInput"|_kiro/permission/respond|## ' "$r/acp.log" || :; fi
  } >"$r/summary.txt"
  sum="$r/summary.txt"
}

# run <id> <case> <comma-separated markers> [VAR=value ...] -- <kiro-cli-chat args...>
run() {
  local id=$1 case=$2 marks=$3 envs=()
  shift 3
  while [[ $1 != -- ]]; do
    envs+=("$1")
    shift
  done
  shift
  env "${envs[@]}" PROBE_OUT="$out/$id" "$S/wire2.sh" "$case" -- "$@" >/dev/null
  run_dir="$out/$id/kiro/$case/run"
  IFS=, read -r -a MK <<<"$marks"
  summarize "$run_dir" "${MK[@]}"
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

STEER=WS_FM_SENTINEL,WS_AUTO_SENTINEL,WS_STEERING_MANUAL_SENTINEL,NESTED_AGENTS_MD_SENTINEL,README_SENTINEL,CLAUDE_MD_SENTINEL,ACP_MANUAL_SENTINEL,ACP_FM_SENTINEL,USER_SENTINEL_1,USER_SENTINEL_2,USER_SENTINEL_3

# fileMatch steering joins the message that carries the matching read; nested AGENTS.md is fileMatch for its
# directory; auto steering only through disclose_context; manual, README.md and CLAUDE.md never by default.
case_mx-hl-steer() {
  run mx-hl-steer mx-steer "$STEER" T=90 -- "${HL[@]}" -a "MAIN_KICKOFF USER_SENTINEL_1"
  expect '^#1 .*hits: USER_SENTINEL_1:cur$'
  expect '^#2 .*hits: WS_FM_SENTINEL:cur USER_SENTINEL_1:h2$'
  expect '^#3 .*WS_FM_SENTINEL:h4 NESTED_AGENTS_MD_SENTINEL:cur '
  expect '^#4 .*WS_AUTO_SENTINEL:cur '
  expect 'TOOL_RESULT dc_a status=success .*WS_AUTO_SENTINEL'
  refute 'WS_STEERING_MANUAL_SENTINEL|README_SENTINEL|CLAUDE_MD_SENTINEL'
}

# manual steering is injected into the current message when the prompt starts with /<name>
case_mx-hl-manual() {
  run mx-hl-manual mx-steer "$STEER" T=90 -- "${HL[@]}" -a "/ws-manual hello USER_SENTINEL_1"
  expect '^#1 .*hits: WS_STEERING_MANUAL_SENTINEL:cur USER_SENTINEL_1:cur$'
}

# ACP: file manual steering via /<name> is one-shot; inline ACP manual/fileMatch entries are listed but never injected
case_mx-acp-steer() {
  run mx-acp-steer mx-acp-steer "$STEER" T=150 -- "${ACP3[@]}"
  expect '^#2 .*hits: WS_FM_SENTINEL:cur USER_SENTINEL_1:h2$'
  expect '^#5 .*WS_STEERING_MANUAL_SENTINEL:cur .*USER_SENTINEL_2:cur$'
  expect '^#6 .*WS_STEERING_MANUAL_SENTINEL:h10 .*USER_SENTINEL_3:cur$'
  refute '^#.*(ACP_MANUAL_SENTINEL|ACP_FM_SENTINEL)'
}

HOST="HOST_,Answer in one or two sentences,CHILD_TASK,USER_SENTINEL_1,USER_SENTINEL_2,USER_SENTINEL_3"

# systemPrompt/appendSystemPrompt on initialize, session/new and session/prompt reach no request; outputStyle is a
# per-prompt _meta id (default|concise) that appends a fixed instruction to that main turn only
case_mx-host() {
  run mx-host mx-host "$HOST" T=150 -- "${ACP3[@]}"
  refute '^#.*HOST_'
  expect '^#1 .*Answer in one or two sentences:cur USER_SENTINEL_1:cur$'
  expect '^#2 .*hits: CHILD_TASK:cur$'
  expect '^#4 .*Answer in one or two sentences:h2 .*USER_SENTINEL_2:cur$'
  expect '^#5 .*Answer in one or two sentences:h2 .*USER_SENTINEL_3:cur$'
}

# headless: cli.json chat.outputStyle sets the same per-turn instruction; an unknown id is silently default
case_mx-hl-style() {
  run mx-hl-style mx-host "$HOST,OUTSTYLE_CUSTOM_SENTINEL" SETTINGS='{"chat.outputStyle":"concise"}' SCRIPT=none T=90 -- "${HL[@]}" -a "MAIN_KICKOFF USER_SENTINEL_1"
  expect '^#1 .*Answer in one or two sentences:cur USER_SENTINEL_1:cur$'
  expect '^#2 .*hits: CHILD_TASK:cur$'
  run mx-hl-style-custom mx-host "$HOST,OUTSTYLE_CUSTOM_SENTINEL" SETTINGS='{"chat.outputStyle":"OUTSTYLE_CUSTOM_SENTINEL"}' SCRIPT=none T=90 -- "${HL[@]}" -a "MAIN_KICKOFF USER_SENTINEL_1"
  refute '^#.*(OUTSTYLE_CUSTOM_SENTINEL|Answer in one or two sentences)'
}

RES=RESAG_PROMPT_SENTINEL,CUSTOM_PROMPT_SENTINEL,RES_FILE_SENTINEL,RES_GLOB_SENTINEL,CHILD_TASK

# agent resources: loaded for the session's main agent (after its body, <steering-files>) and inherited by every
# invoke child; a child agent's own resources are not loaded
case_mx-res() {
  run mx-res-named mx-res "$RES" T=120 -- "${HL[@]}" -a --agent resag "MAIN_KICKOFF USER_SENTINEL_1"
  expect '^#1 .*RESAG_PROMPT_SENTINEL:h0@1700 RES_FILE_SENTINEL:h0@1740 RES_GLOB_SENTINEL:h0@1760$'
  expect '^#2 .*RESAG_PROMPT_SENTINEL:h0@1700 RES_FILE_SENTINEL:h0@[0-9]+ RES_GLOB_SENTINEL:h0@[0-9]+ CHILD_TASK:cur$'
  run mx-res-default mx-res "$RES" T=120 -- "${HL[@]}" -a "MAIN_KICKOFF USER_SENTINEL_1"
  expect '^#2 .*hits: RESAG_PROMPT_SENTINEL:h0@1700 CHILD_TASK:cur$'
  refute '^#.*RES_(FILE|GLOB)_SENTINEL'
  run mx-res-custom mx-res-custom "$RES" T=120 -- "${HL[@]}" -a --agent resag "MAIN_KICKOFF USER_SENTINEL_1"
  expect '^#2 .*CUSTOM_PROMPT_SENTINEL:h0@1700 RES_FILE_SENTINEL:h0@[0-9]+ RES_GLOB_SENTINEL:h0@[0-9]+ CHILD_TASK:cur$'
}

# agent-profile userPromptSubmit: exit 0 wraps stdout in HOOK_INSTRUCTION; exit 1 and exit 2 both append
# "Output:… Exit Code: N" and neither blocks the turn; stderr is dropped when stdout is non-empty
case_mx-ups() {
  local n
  for n in 0 1 2; do
    run "mx-ups-hl$n" mx-ups "UPS${n}_STDOUT_SENTINEL,UPS${n}_STDERR_SENTINEL,<HOOK_INSTRUCTION>,Exit Code: $n,USER_SENTINEL_1,USER_SENTINEL_2" SCRIPT=none T=60 -- "${HL[@]}" -a --agent "ups$n" "hello USER_SENTINEL_1"
    if ((n == 0)); then
      expect '^#1 .*hits: UPS0_STDOUT_SENTINEL:cur <HOOK_INSTRUCTION>:cur USER_SENTINEL_1:cur$'
    else expect "^#1 .*hits: UPS${n}_STDOUT_SENTINEL:cur Exit Code: $n:cur USER_SENTINEL_1:cur$"; fi
    refute "UPS${n}_STDERR_SENTINEL"
    run "mx-ups-acp$n" mx-ups "UPS${n}_STDOUT_SENTINEL,UPS${n}_STDERR_SENTINEL,Exit Code: $n,USER_SENTINEL_1,USER_SENTINEL_2" SCRIPT="$S/cases/mx-ups/script-ups$n.json" T=90 -- "${ACP3[@]}"
    expect "^#2 .*UPS${n}_STDOUT_SENTINEL:h2,cur .*USER_SENTINEL_2:cur$"
    expect 'prompt .*"id": 4, "result": \{"stopReason": "end_turn"\}'
    refute "UPS${n}_STDERR_SENTINEL"
  done
}

MODES="MODE_VIBE_SENTINEL,MODE_SPEC_SENTINEL,MODE_QUICK_SPEC_SENTINEL,MODE_BUG_FIX_SENTINEL,MODE_PLAN_SENTINEL,MODE_AUTONOMOUS_SENTINEL,GLOBAL_STEERING_SENTINEL,either respond directly or delegate"

# ACP modeIds: spec / quick-spec / bug-fix run a sub-intent classifier turn, then steering + KAS base + mode text;
# plan replaces the base and moves steering into the current message; autonomous has its own base
case_mx-modes() {
  run mx-modes mx-modes "$MODES" T=500 -- "${ACP3[@]}"
  local m
  for m in SPEC QUICK_SPEC BUG_FIX; do
    expect "first='You are a sub-intent classifier for a specification agent.' hits: MODE_${m}_SENTINEL:cur$"
    expect "base@1727 .*MODE_${m}_SENTINEL:cur GLOBAL_STEERING_SENTINEL:h0@308$"
  done
  expect '"agentMode": "spec"'
  expect '"agentMode": "quick-spec"'
  expect '"agentMode": "bug-fix"'
  expect "base@-1 .*first='You are a specialized planning agent .*MODE_PLAN_SENTINEL:cur GLOBAL_STEERING_SENTINEL:cur$"
  expect 'base@1700 .*MODE_AUTONOMOUS_SENTINEL:cur GLOBAL_STEERING_SENTINEL:h0@308 either respond directly or delegate:h0@[0-9]+$'
}

WFA=(wf-coder "You are a coding subagent invoked from a workflow"
  wf-planner "You are a planning agent in a multi-step workflow"
  wf-review-aggregator "You are a review aggregation subagent"
  wf-pr-submitter "You are a PR submission subagent"
  wf-pr-responder "You are a PR response subagent"
  wf-workflow-creator "You are a workflow architect"
  wf-auto-researcher "You are an autonomous research subagent"
  wf-design "You are a requirements-and-design authoring subagent"
  wf-design-reviewer "You are a design review subagent")

# built-in wf-* step agents: each replaces the KAS base with its own body after file steering
case_mx-wfagents() {
  local i marks="ROOT_AGENTS_MD_SENTINEL"
  for ((i = 0; i < ${#WFA[@]}; i += 2)); do marks+=",${WFA[i + 1]}"; done
  run mx-wfagents mx-wfagents "$marks,WFA_" "${WF[@]}" T=120 -- "${ACP3[@]}"
  for ((i = 0; i < ${#WFA[@]}; i += 2)); do
    expect "base@-1 .*ROOT_AGENTS_MD_SENTINEL:h0@1656 ${WFA[i + 1]}:h0@[0-9]+ WFA_:cur$"
  done
  expect '"status": "completed"'
}

# headless cli.json / rollout settings cannot enable inline agents: the schema has no inlineAgent and the call fails
case_mx-hl-inline() {
  run mx-hl-inline mx-hl-inline INLINE_SYS_SENTINEL,INLINE_TASK SETTINGS='{"chat.inlineAgents":true,"chat.enableInlineAgents":true,"inlineAgents":{"enabled":true}}' CASE_ENV="KIRO_ENABLED_FEATURES=inlineAgents KIRO_ROLLOUT_FEATURES=inlineAgents" T=90 -- "${HL[@]}" -a "MAIN_KICKOFF USER_SENTINEL_1"
  expect "TOOL_RESULT tu_i status=error .*Agent 'anonymous' not found in registry"
  refute 'INLINE_SYS_SENTINEL:h0'
}

# an unanswered session/request_permission holds the turn with no timeout, even past KIRO_SUBAGENT_DEADLINE_MS;
# session/cancel releases it
case_mx-perm-ignore() {
  run mx-perm-ignore mx-perm-ignore CHILD_PERM,AFTER_CANCEL T=150 -- "${ACP3[@]}"
  expect '## permission policy -> ignore'
  expect '^ *4[6-9]\.[0-9]+ wait p .*"stopReason": "cancelled"'
  expect 'TOOL_RESULT tu_p status=error .*Sub-agent execution was cancelled'
  refute 'TOOL_RESULT cb1 status=success'
  run mx-perm-ignore-deadline mx-perm-ignore CHILD_PERM,AFTER_CANCEL CASE_ENV="KIRO_SUBAGENT_DEADLINE_MS=5000" T=150 -- "${ACP3[@]}"
  expect '^ *4[6-9]\.[0-9]+ wait p .*"stopReason": "cancelled"'
  refute 'timed out after 5000ms'
  run mx-perm-ignore-main mx-perm-ignore CHILD_PERM,AFTER_CANCEL SCRIPT="$S/cases/mx-perm-ignore/script-main.json" T=150 -- "${ACP3[@]}"
  expect '^ *4[6-9]\.[0-9]+ wait p .*"stopReason": "cancelled"'
  expect 'TOOL_RESULT tu_p status=error .*The tool call was cancelled before it was approved\.'
}

# workflow step shell: headless without -a rejects it silently, with -a runs it; over ACP the permission request
# arrives on the step's own session id, not the parent's
case_mx-wf-perm() {
  run mx-wf-perm-hl mx-wf-perm WFP_STEP,STEP_BASH_RAN "${WF[@]}" SCRIPT=none T=120 -- "${HL[@]}" "MAIN_KICKOFF USER_SENTINEL_1"
  expect 'TOOL_RESULT sb1 status=error .*The user rejected this tool call\.'
  run mx-wf-perm-hl-a mx-wf-perm WFP_STEP,STEP_BASH_RAN "${WF[@]}" SCRIPT=none T=120 -- "${HL[@]}" -a "MAIN_KICKOFF USER_SENTINEL_1"
  expect 'TOOL_RESULT sb1 status=success .*STEP_BASH_RAN'
  run mx-wf-perm-acp mx-wf-perm WFP_STEP,STEP_BASH_RAN "${WF[@]}" T=120 -- "${ACP3[@]}"
  expect 'TOOL_RESULT sb1 status=error .*The user rejected this tool call\.'
  local parent step
  parent=$(grep -o -m1 '"id": "sess_[^"]*"' "$run_dir/out.txt" | grep -o 'sess_[^"]*')
  step=$(grep 'request_permission' "$run_dir/acp.log" | grep 'run_command_sb1' | grep -o -m1 '"sessionId":"sess_[^"]*"' | grep -o 'sess_[^"]*')
  if [[ -n $step && $step != "$parent" ]]; then printf '   ok    step permission on its own session (%s != parent %s)\n' "$step" "$parent"; else
    printf '   FAIL  step permission session %s vs parent %s\n' "$step" "$parent"
    fails=$((fails + 1))
  fi
}

# after the turn, _kiro/session/export carries sub-executions/<agentSubtaskId>.jsonl with the child transcript;
# _kiro/session/history returns no updates
case_mx-child-hist() {
  run mx-child-hist mx-child-hist CHILD_TASK T=120 -- "${ACP3[@]}"
  expect 'call _kiro/session/history .*"updates": \[\], "hasMore": false'
  expect 'sh 0 sub-executions/[0-9a-f-]+\.jsonl'
  expect '^ +1 CHILD_DONE_SENTINEL$'
  expect 'sessions/[0-9a-f]+/sess_[0-9a-f-]+/sub-executions/[0-9a-f-]+\.jsonl'
}

# child user_input: options + no capability -> session/request_permission (allow = first option); userInput
# capability -> _kiro/userInput; no options -> no client request, "ready to move on"; headless -a -> first option
case_mx-child-uinput() {
  run mx-child-uinput mx-child-uinput CHILD_UINPUT T=90 -- "${ACP3[@]}"
  expect 'session/request_permission.*UINPUT_Q_SENTINEL'
  expect 'TOOL_RESULT ui_1 status=success .*Response: UOPT_A'
  run mx-child-uinput-cap mx-child-uinput CHILD_UINPUT SCRIPT="$S/cases/mx-child-uinput/script-cap.json" T=90 -- "${ACP3[@]}"
  expect '"method":"_kiro/userInput".*UINPUT_Q_SENTINEL'
  expect 'TOOL_RESULT ui_1 status=success .*Response: UINPUT_ANSWER_SENTINEL'
  run mx-child-uinput-noopts mx-child-uinput-noopts CHILD_UINPUT T=90 -- "${ACP3[@]}"
  expect 'TOOL_RESULT ui_1 status=success .*User is ready to move on to the next phase'
  refute 'UINPUT_Q_SENTINEL.*(request_permission|_kiro/userInput)|(request_permission|_kiro/userInput).*UINPUT_Q_SENTINEL'
  run mx-child-uinput-hl mx-child-uinput CHILD_UINPUT SCRIPT=none T=60 -- "${HL[@]}" -a "MAIN_KICKOFF USER_SENTINEL_1"
  expect 'TOOL_RESULT ui_1 status=success .*Response: UOPT_A'
}

SNAP=SNAP_STEER_V1_SENTINEL,SNAP_STEER_V2_SENTINEL,SNAP_INLINE_V1_SENTINEL,SNAP_INLINE_V2_SENTINEL,SNAP_AGENT_V1_SENTINEL,SNAP_AGENT_V2_SENTINEL,CHILD_TASK,USER_SENTINEL_1,USER_SENTINEL_2

# bump the snapshot fixtures V1 -> V2 inside a finished run
snap_bump() { sed -i 's/_V1_/_V2_/' "$1/ws/.kiro/steering/snap.md" "$1/home/.kiro/agents/snapag.json"; }

# resume replays the persisted history[0]: steering, agent prompt and inline steering edited between processes
# do not reach the resumed session (ACP session/load and headless --resume)
case_mx-resume() {
  run mx-resume-acp mx-resume "$SNAP" T=90 -- "${ACP3[@]}"
  local r=$run_dir old
  old=$(grep -o -m1 '"id": "sess_[^"]*"' "$r/out.txt" | grep -o 'sess_[^"]*')
  snap_bump "$r"
  sed "s/@OLD@/$old/g" "$S/cases/mx-resume/script-load.json" >"$r/script-load.json"
  KEEP=1 SCRIPT="$r/script-load.json" PROBE_OUT="$out/mx-resume-acp" T=120 "$S/wire2.sh" mx-resume -- "${ACP3[@]}" >/dev/null
  IFS=, read -r -a MK <<<"$SNAP"
  summarize "$r" "${MK[@]}"
  expect '^#4 .*hist=6 .*SNAP_STEER_V1_SENTINEL:h0@1646 SNAP_INLINE_V1_SENTINEL:h0@[0-9]+ SNAP_AGENT_V1_SENTINEL:h0@[0-9]+ .*USER_SENTINEL_2:cur$'
  refute '^#.*_V2_SENTINEL'
  run mx-resume-hl mx-resume "$SNAP" SCRIPT=none T=90 -- "${HL[@]}" -a --agent snapag "MAIN_KICKOFF USER_SENTINEL_1"
  r=$run_dir
  snap_bump "$r"
  KEEP=1 SCRIPT=none PROBE_OUT="$out/mx-resume-hl" T=90 "$S/wire2.sh" mx-resume -- "${HL[@]}" -a --resume "RESUMED USER_SENTINEL_2" >/dev/null
  summarize "$r" "${MK[@]}"
  expect '^#4 .*hist=6 .*SNAP_STEER_V1_SENTINEL:h0@1646 SNAP_AGENT_V1_SENTINEL:h0@[0-9]+ .*USER_SENTINEL_2:cur$'
  refute '^#.*_V2_SENTINEL'
}

# workflow pause -> resume keeps the step session's snapshot; the next step renders steering fresh
case_mx-wf-snap() {
  run mx-wf-snap mx-wf-snap "SNAP_STEER_V1_SENTINEL,SNAP_STEER_V2_SENTINEL,WFS_STEP1,WFS_STEP2" "${WF[@]}" T=90 -- "${ACP3[@]}"
  expect 'sh 0 SNAP_STEER_V2_SENTINEL'
  expect '^#2 .*hits: SNAP_STEER_V1_SENTINEL:h0@1646 WFS_STEP1:cur$'
  expect '^#3 .*hits: SNAP_STEER_V2_SENTINEL:h0@1646 WFS_STEP2:cur$'
  local c1 c2
  c1=$(grep -E '^#1 ' "$sum" | grep -o 'conv=[^ ]*')
  c2=$(grep -E '^#2 ' "$sum" | grep -o 'conv=[^ ]*')
  if [[ -n $c1 && $c1 == "$c2" ]]; then printf '   ok    resumed step reuses its session (%s)\n' "$c1"; else
    printf '   FAIL  resumed step session %s vs %s\n' "$c1" "$c2"
    fails=$((fails + 1))
  fi
}

# `serve`: the same KAS over a WebSocket; WS clients are observers whose JSON-RPC permission replies are discarded,
# so approvals go through _kiro/permission/respond. Offline auth uses a fake KIRO_API_KEY (local capture only).
case_mx-serve() {
  local wrap
  wrap="$(command -v node) $S/ws-bridge.cjs"
  run mx-serve mx-serve CHILD_TASK,USER_SENTINEL_1,USER_SENTINEL_2 CASE_ENV="KIRO_API_KEY=fake-offline-probe-key" WRAP="$wrap" T=90 -- serve --port 18801
  expect '_kiro/permission/respond.*"optionId": "accept"'
  expect '^#2 .*hits: CHILD_TASK:cur$'
  expect '^#4 .*USER_SENTINEL_2:cur$'
  run mx-serve-reply mx-serve CHILD_TASK,USER_SENTINEL_1 CASE_ENV="KIRO_API_KEY=fake-offline-probe-key" WRAP="$wrap" SCRIPT="$S/cases/mx-serve/script-reply.json" T=45 -- serve --port 18801
  expect '## permission policy -> allow'
  expect 'prompt \{"timeout": 3\}'
  refute 'CHILD_TASK:cur'
}

# client half of the account flag system_field_injection (simulated via CAP_FEATURES): main requests move steering
# and base into a top-level systemPrompt and history[0] becomes "Hello"; invoke children keep user-role history[0]
case_mx-sysfield() {
  run mx-sysfield mx-host "GLOBAL_STEERING_SENTINEL,CHILD_TASK,USER_SENTINEL_1,You are Kiro" CAP_FEATURES='{"system_field_injection":true}' SCRIPT=none T=90 -- "${HL[@]}" -a "MAIN_KICKOFF USER_SENTINEL_1"
  expect "^#1 .*h0len=5 .*first='Hello' hits: GLOBAL_STEERING_SENTINEL:top USER_SENTINEL_1:cur You are Kiro:top$"
  expect '^#2 .*hits: GLOBAL_STEERING_SENTINEL:h0@308 CHILD_TASK:cur$'
  run mx-sysfield-off mx-host "GLOBAL_STEERING_SENTINEL,CHILD_TASK,USER_SENTINEL_1,You are Kiro" SCRIPT=none T=90 -- "${HL[@]}" -a "MAIN_KICKOFF USER_SENTINEL_1"
  expect '^#1 .*hits: GLOBAL_STEERING_SENTINEL:h0@308 USER_SENTINEL_1:cur You are Kiro:h0@1700$'
}

# the workspace is always trusted: no kiro-scope:untrusted-execution rule in the session's permission rules
case_mx-trust() {
  run mx-trust mx-trust - T=60 -- "${ACP3[@]}"
  expect 'call _kiro/permissions/list .*"rules"'
  if grep -q 'untrusted-execution' "$run_dir/acp.log"; then
    printf '   FAIL  untrusted-execution rule present\n'
    fails=$((fails + 1))
  else printf '   ok    absent: untrusted-execution rule in _kiro/permissions/list\n'; fi
}

# capacity summary: peak in-flight model requests for <marker> and their distinct conversations, run statuses
# from every _kiro/workflow/list result in acp.log, and the number of prompts that ended their turn
capacity() {
  local r=$1 marker=$2
  {
    python3 "$S/inflight.py" "$r/wire.jsonl" "$marker"
    python3 - "$r/acp.log" <<'PY_STATUS'
import collections, json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    if " << " not in line:
        continue
    try:
        runs = json.loads(line.split(" << ", 1)[1])["result"]["runs"]
    except (ValueError, KeyError, TypeError):
        continue
    counts = collections.Counter(run["status"] for run in runs)
    print(f"workflow/list runs={len(runs)} " + " ".join(f"{k}={v}" for k, v in sorted(counts.items())))
PY_STATUS
    printf 'end_turn=%s\n' "$(grep -c 'wait p[0-9]* .*"stopReason": "end_turn"' "$r/out.txt" || :)"
  } >>"$sum"
}

# host _kiro/workflow/new + invoke x20 in one session, each one step held 20 s by the server: all 20 runs are
# running at once and all 20 step requests are in flight together (no run cap at 20); all complete
case_mx-wfcap() {
  run mx-wfcap mx-wfcap WFCAP_STEP "${WF[@]}" T=150 -- "${ACP3[@]}"
  capacity "$run_dir" WFCAP_STEP
  expect '^marker=WFCAP_STEP requests=20 peak_inflight=20 '
  expect '^workflow/list runs=20 running=20$'
  expect '^workflow/list runs=20 completed=20$'
}

# one `acp` process: 20 more session/new calls succeed, and 20 prompts (one per session) held 15 s by the server
# are all in flight together across 20 conversations (no session or prompt cap at 20); all end their turn
case_mx-sesscap() {
  run mx-sesscap mx-sesscap SESSCAP_PROMPT T=120 -- "${ACP3[@]}"
  capacity "$run_dir" SESSCAP_PROMPT
  expect '^marker=SESSCAP_PROMPT requests=20 peak_inflight=20 '
  expect '^conversations=20$'
  expect '^end_turn=20$'
  refute 'new S[0-9]+ .*"error"'
}

all=(mx-hl-steer mx-hl-manual mx-acp-steer mx-host mx-hl-style mx-res mx-ups mx-modes mx-wfagents mx-hl-inline
  mx-perm-ignore mx-wf-perm mx-child-hist mx-child-uinput mx-resume mx-wf-snap mx-serve mx-sysfield mx-trust mx-wfcap
  mx-sesscap)
ids=("$@")
if ((${#ids[@]} == 0)); then ids=("${all[@]}"); fi
for id in "${ids[@]}"; do "case_$id"; done
printf 'out=%s fails=%s\n' "$out" "$fails"
((fails == 0))

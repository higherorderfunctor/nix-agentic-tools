#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# cli_path stand-in for sdk-py.py / acp-adapter.py: records argv and stdin per spawn
# (argv-<pid>.txt, stdin-<pid>.jsonl), then execs the pinned claude.
# With RECORDER_INJECT_FILE set it also prepends --append-system-prompt-file <file>, the
# way a wrapper that owns an append channel would.
out="${RECORDER_OUT:?}"
extra=()
if [[ -n ${RECORDER_INJECT_FILE:-} ]]; then extra=(--append-system-prompt-file "$RECORDER_INJECT_FILE"); fi
printf '%s\n' "${extra[@]}" "$@" >"$out/argv-$$.txt"
env | sed -n 's/^\(CLAUDE_CODE_ENTRYPOINT\|CLAUDE_AGENT_SDK_VERSION\)=/\1=/p' >"$out/env-$$.txt"
exec "${CLAUDE_BIN:?}" "${extra[@]}" "$@" < <(tee "$out/stdin-$$.jsonl")

#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: [MODE=json|rpc] [PROMPT_ARGS=…] [STDIN_FILE=…] [EXTRA_ENV="K=V …"] [HARNESS_SETTINGS=file] [WORKFLOWS=1] \
#          run.sh <label> [extra kimchi args...]
# claude:inv — loads observer.ts, which prints every registered tool and command at the first input event
# and swallows the input (no model call). Writes <work>/<label>.{tools,commands}.json and the run dir
# <work>/run-<label>-*; work = $PROBE_OUT/kimchi-inv or a fresh temp dir. WORKFLOWS=1 links the pinned
# kimchi-workflows extension into the harness extensions dir.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$here/../../common/pin.sh"
label="${1:?usage: run.sh <label> [args...]}"
shift
work="$(probe_workdir kimchi-inv)"
kimchi="${KIMCHI_PKG:-$(probe_pkg kimchi)}/bin/kimchi"
base="$(mktemp -d "$work/run-$label-XXXX")"
mkdir -p "$base"/{home,project,tmp,cache,config,data,runtime,state}
chmod 700 "$base"/runtime
if [[ -n ${HARNESS_SETTINGS:-} ]]; then
  mkdir -p "$base/home/.config/kimchi/harness"
  cp "$HARNESS_SETTINGS" "$base/home/.config/kimchi/harness/settings.json"
fi
if [[ -n ${WORKFLOWS:-} ]]; then
  mkdir -p "$base/home/.config/kimchi/harness/extensions"
  ln -s "${KIMCHI_WORKFLOWS_PKG:-$(probe_pkg kimchi-workflows)}" "$base/home/.config/kimchi/harness/extensions/workflows"
fi
read -r -a extra_env <<<"${EXTRA_ENV:-}"
read -r -a prompt_args <<<"${PROMPT_ARGS--p hello}"
stdin_file="$(realpath "${STDIN_FILE:-/dev/null}")"
cd "$base/project"
env -i HOME="$base/home" PATH="$PATH" TMPDIR="$base/tmp" XDG_CACHE_HOME="$base/cache" XDG_CONFIG_HOME="$base/config" \
  XDG_DATA_HOME="$base/data" XDG_RUNTIME_DIR="$base/runtime" XDG_STATE_HOME="$base/state" \
  KIMCHI_TELEMETRY_ENABLED=0 "${extra_env[@]}" \
  timeout 60 "$kimchi" --mode "${MODE:-json}" --no-session -e "$here/observer.ts" "$@" "${prompt_args[@]}" \
  <"$stdin_file" >"$base/stdout" 2>"$base/stderr" || echo "exit=$?" >>"$base/stderr"
grep '^INV_TOOLS ' "$base/stderr" | sed 's/^INV_TOOLS //' | python3 -m json.tool >"$work/$label.tools.json"
grep '^INV_COMMANDS ' "$base/stderr" | sed 's/^INV_COMMANDS //' | python3 -m json.tool >"$work/$label.commands.json"
printf 'tools: %s\n' "$work/$label.tools.json"

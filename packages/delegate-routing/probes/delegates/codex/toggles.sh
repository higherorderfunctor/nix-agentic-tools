#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: toggles.sh [variants.txt]   — one offline request per config variant; prints the multi-agent tool surface
# variants: probes/toggles/variants.txt (claude:R11, default) or probes/toggles/judge-variants.txt (judge:J1).
# Line format: name|model|extra TOML (\n escapes). Generated probes live in <work>/probes/toggles-<name>.
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common/pin.sh
source "$D/../common/pin.sh"
variants="${1:-$D/probes/toggles/variants.txt}"
CODEX_WORK="${CODEX_WORK:-$(probe_workdir codex)}"
CODEX_PKG="${CODEX_PKG:-$(probe_pkg chatgpt-codex)}"
export CODEX_WORK CODEX_PKG
port=19110
while IFS='|' read -r name model extra; do
  P="$CODEX_WORK/probes/toggles-$name"
  mkdir -p "$P"
  sed "s|^model = .*|model = \"$model\"|" "$D/base.toml" >"$P/config.toml"
  printf '%b\n' "$extra" >>"$P/config.toml"
  echo '{"*": [{"msg": "X"}]}' >"$P/scenario.json"
  echo '{"thread": {}, "turn": "GO", "timeout": 15, "settle": 0}' >"$P/probe.json"
  port=$((port + 1))
  PROBE_DIR="$P" timeout 120 "$D/run.sh" "toggles-$name" "$port" </dev/null >/dev/null 2>&1 || echo "run failed: $name"
done <"$variants"
python3 "$D/toggles_report.py" "$variants" "$CODEX_WORK/results"

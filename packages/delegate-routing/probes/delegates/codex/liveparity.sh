#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: liveparity.sh [model]     LIVE: one short `codex exec` turn on the operator's ChatGPT login.
# codex:L3 — live account catalog vs the bundled catalog, per model, plus one real V2 spawn.
# A scratch CODEX_HOME gets a copy of ~/.codex/auth.json (umask 077; never printed) and a minimal
# config; the run fetches the account catalog into <scratch>/models_cache.json. Prints, per slug,
# the live and bundled `multi_agent_version` and visibility, then the root rollout's function calls
# (namespace, name) and the child rollout's agent_path/model/effort. The scratch home is deleted.
# Refuses to run when the access token would be refreshed (a refresh in the scratch copy would
# rotate the operator's refresh token out from under ~/.codex).
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common/pin.sh
source "$D/../common/pin.sh"
model="${1:-gpt-6-luna}"
pkg="${CODEX_PKG:-$(probe_pkg chatgpt-codex)}"
src="$(probe_pkg chatgpt-codex.src)"
auth="$HOME/.codex/auth.json"
[[ -f $auth ]] || {
  printf 'no %s: log in with codex login first\n' "$auth" >&2
  false
}
# CHATGPT_ACCESS_TOKEN_REFRESH_WINDOW_MINUTES = 5 (login/src/auth/manager.rs); keep a margin.
exp="$(jq -r '.tokens.access_token | split(".")[1] | gsub("-";"+") | gsub("_";"/") | . + ("=" * ((4 - length % 4) % 4)) | @base64d | fromjson | .exp' "$auth")"
if ((exp < $(date +%s) + 3600)); then
  printf 'access token expires within the hour; run any codex command once so ~/.codex refreshes it, then retry\n' >&2
  false
fi
S="$(mktemp -d -t codex-liveparity.XXXXXX)"
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/home" "$S/plain"
(
  umask 077
  cp "$auth" "$S/home/auth.json"
)
cat >"$S/home/config.toml" <<EOF
model = "$model"
model_reasoning_effort = "low"
sandbox_mode = "read-only"
approval_policy = "never"
check_for_update_on_startup = false
[features]
memories = false
EOF
(cd "$S/plain" && CODEX_HOME="$S/home" timeout 300 "$pkg/bin/codex" --no-daemon exec --json --skip-git-repo-check \
  'Use your spawn_agent tool exactly once: task_name "p", fork_turns "none", message "Reply with exactly the word PONG and nothing else." Then call wait_agent once, then reply with exactly DONE.' \
  </dev/null >"$S/events.jsonl" 2>"$S/stderr.txt")
if ! cmp -s "$auth" "$S/home/auth.json"; then
  printf 'WARNING: the scratch auth.json changed (token refreshed); copy it back to %s before using codex again\n' "$auth" >&2
fi
python3 - "$S/home/models_cache.json" "$src/codex-rs/models-manager/models.json" <<'EOF'
import json, sys
live_doc = json.load(open(sys.argv[1]))
live = {m["slug"]: m for m in live_doc["models"]}
bundled = {m["slug"]: m for m in json.load(open(sys.argv[2]))["models"]}
print(f"live catalog client_version={live_doc.get('client_version')} fetched_at={live_doc.get('fetched_at')}")
print("slug live_mav bundled_mav live_vis bundled_vis")
for s in sorted(set(live) | set(bundled)):
    L, B = live.get(s), bundled.get(s)
    print(s, L.get("multi_agent_version") if L else "ABSENT", B.get("multi_agent_version") if B else "ABSENT",
          L.get("visibility") if L else "-", B.get("visibility") if B else "-")
EOF
python3 - "$S/home/sessions" <<'EOF'
import json, pathlib, sys
for path in sorted(pathlib.Path(sys.argv[1]).rglob("*.jsonl")):
    rows = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    meta = next(r["payload"] for r in rows if r.get("type") == "session_meta")
    ctx = next((r["payload"] for r in rows if r.get("type") == "turn_context"), {})
    calls = [(r["payload"].get("namespace"), r["payload"].get("name")) for r in rows
             if r.get("type") == "response_item" and r["payload"].get("type") == "function_call"]
    role = "root" if meta.get("source") == "exec" else "child " + str(meta.get("agent_path"))
    print(f"{role}: model={ctx.get('model')} effort={ctx.get('effort')} calls={calls}")
EOF

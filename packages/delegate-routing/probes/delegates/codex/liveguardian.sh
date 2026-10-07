#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: liveguardian.sh [model]     LIVE: one short app-server turn on the operator's ChatGPT login.
# codex:L3.live-guardian — the auto-review (guardian) policy as actually sent, and whether the live
# catalog's codex-auto-review template has an `{{ extra_policy }}` slot. Codex reaches the backend
# through liveproxy.py (`openai_base_url`), which logs request bodies (never headers) and the
# catalog. Config sets `[auto_review] extra_policy = "GUARD-EXTRA-4007"`; the turn asks for one
# escalated command so `approvals_reviewer = "auto_review"` sends it to codex-auto-review.
# A scratch CODEX_HOME holds a copy of ~/.codex/auth.json (umask 077, never printed); the scratch
# directory is deleted on exit. Refuses to run when the access token would be refreshed.
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common/pin.sh
source "$D/../common/pin.sh"
model="${1:-gpt-6-luna}"
port="${LIVEPROXY_PORT:-19495}"
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
S="$(mktemp -d -t codex-liveguardian.XXXXXX)"
proxy=""
cleanup() {
  if [[ -n $proxy ]]; then kill "$proxy" 2>/dev/null || :; fi
  rm -rf "$S"
}
trap cleanup EXIT
mkdir -p "$S/home" "$S/plain" "$S/wire"
(
  umask 077
  cp "$auth" "$S/home/auth.json"
)
cat >"$S/home/config.toml" <<EOF
model = "$model"
model_reasoning_effort = "low"
sandbox_mode = "read-only"
approval_policy = "on-request"
approvals_reviewer = "auto_review"
openai_base_url = "http://127.0.0.1:$port/backend-api/codex"
check_for_update_on_startup = false
[auto_review]
extra_policy = "GUARD-EXTRA-4007"
[features]
memories = false
enable_request_compression = false
EOF
cat >"$S/probe.json" <<'EOF'
{
  "thread": {},
  "turn": "Run the shell command `true` exactly once, with sandbox_permissions set to require_escalated and the justification `probe escalation`. Do not run anything else. Then reply with exactly DONE.",
  "timeout": 180,
  "approval": "decline"
}
EOF
python3 "$D/liveproxy.py" "$port" "$S/wire" &
proxy=$!
sleep 0.5
CODEX_BIN="$pkg/bin/codex" python3 "$D/asclient.py" "$S/home" "$S/as" "$S/plain" "$S/probe.json"
if ! cmp -s "$auth" "$S/home/auth.json"; then
  printf 'WARNING: the scratch auth.json changed (token refreshed); copy it back to %s before using codex again\n' "$auth" >&2
fi
python3 - "$S/wire" "$src/codex-rs/models-manager/models.json" "$S/as/as.jsonl" "${PROBE_OUT:-}" <<'EOF'
import hashlib, json, os, pathlib, sys
wire, bundled_path, as_log, keep = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
sha = lambda t: hashlib.sha256(t.encode()).hexdigest()[:12]
def template(doc):
    m = next((m for m in doc["models"] if m["slug"] == "codex-auto-review"), None)
    return ((m or {}).get("model_messages") or {}).get("auto_review", {}).get("policy_template") if m else None
bundled = template(json.load(open(bundled_path)))
print(f"bundled codex-auto-review template: len={len(bundled)} sha={sha(bundled)} extra_policy_slot={'{{ extra_policy }}' in bundled}")
live = template(json.load(open(wire / "models.json"))) if (wire / "models.json").exists() else None
if live is None:
    print("live catalog: no codex-auto-review policy_template captured")
else:
    print(f"live codex-auto-review template: len={len(live)} sha={sha(live)} extra_policy_slot={'{{ extra_policy }}' in live} same_as_bundled={live == bundled}")
for line in open(wire / "log.jsonl"):
    rec = json.loads(line)
    print(f"req n={rec['n']} {rec['method']} {rec['path'].split('?')[0]} status={rec.get('status')} model={rec.get('model')} subagent={rec.get('subagent')}")
    body_path = wire / f"req{rec['n']:02d}.json"
    if rec.get("subagent") != "guardian" or not body_path.exists():
        continue
    body = json.load(open(body_path))
    texts = [c.get("text", "") for it in body.get("input", []) if it.get("type") == "message" and it.get("role") == "developer"
             for c in it.get("content", [])]
    policy = next((t for t in texts if "# Security Policy" in t), "")
    print(f"  guardian policy message: len={len(policy)} sha={sha(policy)} GUARD-EXTRA-4007={'GUARD-EXTRA-4007' in policy}"
          f" matches_live_template_head={bool(live) and policy[:200] == live[:200]}")
    if keep and policy:
        os.makedirs(f"{keep}/codex-liveguardian", exist_ok=True)
        open(f"{keep}/codex-liveguardian/guardian-policy-sent.txt", "w").write(policy)
        if live:
            open(f"{keep}/codex-liveguardian/live-policy-template.txt", "w").write(live)
for line in open(as_log):
    msg = json.loads(line)["msg"]
    if msg.get("method") == "item/autoApprovalReview/completed":
        review = msg["params"]["review"]
        print(f"review status={review.get('status')} risk={review.get('riskLevel')}")
EOF

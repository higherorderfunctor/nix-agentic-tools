# shellcheck shell=bash
readonly delegate_usage_claude_url='https://api.anthropic.com/api/oauth/usage'
readonly delegate_usage_claude_beta='oauth-2025-04-20'
readonly delegate_usage_claude_projection='{five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage}'

usage_cpa_error() {
  printf '%s\n' "usage: proxy $1" >&2
  exit 1
}

usage_cpa_request() {
  local method=$1 endpoint=$2 payload=${3-} response status
  local prefix=${4:-v0/management}
  if ! delegate_usage_cpa_key=$(<"$delegate_usage_cpa_key_file"); then
    usage_cpa_error 'cannot read management key file'
  fi
  if [[ -z $delegate_usage_cpa_key || $delegate_usage_cpa_key == *$'\n'* || $delegate_usage_cpa_key == *$'\r'* ]]; then
    usage_cpa_error 'management key must be a nonempty single line'
  fi
  delegate_usage_cpa_key=${delegate_usage_cpa_key//\\/\\\\}
  delegate_usage_cpa_key=${delegate_usage_cpa_key//\"/\\\"}
  if ! response=$(
    curl -q --silent --max-time 75 --request "$method" \
      --url "${delegate_usage_cpa_url%/}/$prefix/$endpoint" \
      --header 'Content-Type: application/json' --data "$payload" \
      --write-out $'\n%{http_code}' --config - 2>/dev/null <<EOF_CPA
header = "Authorization: Bearer $delegate_usage_cpa_key"
EOF_CPA
  ); then
    usage_cpa_error 'management request failed'
  fi
  unset delegate_usage_cpa_key
  status=${response##*$'\n'}
  # An omitted config API collection is a missing path, not an empty array.
  if [[ $status == 404 && $prefix == v8/management ]]; then
    printf '[]'
    return
  fi
  [[ $status == 2?? ]] || usage_cpa_error "management HTTP $status"
  printf '%s' "${response%$'\n'*}"
}

# Shared by the packaged usage helpers; returns 1 only for direct-login fallback.
usage_cpa() {
  local vendor=$1 files accounts account request envelope vendor_status body result
  local delegate_usage_cpa_url delegate_usage_cpa_key_file url_variable key_variable
  local route=${2:-$vendor}
  url_variable="DELEGATE_USAGE_CPA_${route^^}_URL"
  key_variable="DELEGATE_USAGE_CPA_${route^^}_MANAGEMENT_KEY_FILE"
  delegate_usage_cpa_url=${!url_variable-}
  delegate_usage_cpa_key_file=${!key_variable-}
  if [[ -z $delegate_usage_cpa_url && -z $delegate_usage_cpa_key_file ]]; then
    return 1
  fi
  if [[ -z $delegate_usage_cpa_url || -z $delegate_usage_cpa_key_file ]]; then
    usage_cpa_error 'requires both URL and management-key file in the matching runtime pair'
  fi
  if [[ $vendor == zai ]]; then
    # These responses contain upstream keys. Project them in memory only.
    local claude_config openai_config
    claude_config=$(usage_cpa_request GET config/api-keys/claude "" v8/management) || exit 1
    openai_config=$(usage_cpa_request GET config/api-keys/openai-compatibility "" v8/management) || exit 1
    accounts=$(printf '%s\n%s' "$claude_config" "$openai_config" | python3 -c '
import json, sys
from urllib.parse import urlsplit
try:
    decoder = json.JSONDecoder()
    raw = sys.stdin.read()
    candidates = {}
    while raw.strip():
        groups, end = decoder.raw_decode(raw.lstrip())
        raw = raw.lstrip()[end:]
        if not isinstance(groups, list):
            raise ValueError()
        for group in groups:
            if urlsplit(group.get("base-url", "")).hostname != "api.z.ai":
                continue
            for key in group.get("keys", []):
                if key.get("api-key") and key.get("auth_index"):
                    candidates.setdefault(key["api-key"], key["auth_index"])
    if len(candidates) != 1:
        sys.exit(2)
    print(json.dumps([{"auth_index": next(iter(candidates.values()))}]))
except (AttributeError, TypeError, ValueError):
    sys.exit(3)
') || usage_cpa_error 'z.ai requires exactly one distinct key with an auth index on api.z.ai'
    unset claude_config openai_config
  else
    files=$(usage_cpa_request GET auth-files) || exit 1
    accounts=$(jq -ce --arg vendor "$vendor" '
      .files | if type != "array" then error("files") else
        map(select(.provider == $vendor and .account_type == "oauth" and .disabled != true)) end
    ' <<<"$files" 2>/dev/null) || usage_cpa_error 'invalid auth-files response'
    [[ $accounts != '[]' ]] || usage_cpa_error "has no enabled $vendor login"
  fi
  while IFS= read -r account; do
    request=$(jq -cn --argjson account "$account" --arg vendor "$vendor" \
      --arg claude_url "$delegate_usage_claude_url" --arg claude_beta "$delegate_usage_claude_beta" '{
      auth_index: $account.auth_index,
      method: "GET",
      url: (if $vendor == "claude" then $claude_url
            elif $vendor == "codex" then "https://chatgpt.com/backend-api/wham/usage"
            else "https://api.z.ai/api/monitor/usage/quota/limit" end),
      header: ({Authorization: "Bearer $TOKEN$", "Content-Type": "application/json"} +
        if $vendor == "claude" then {"anthropic-beta": $claude_beta}
        elif $vendor == "zai" then {"Accept-Language": "en-US,en"}
        else {"User-Agent": "codex-tui"} +
          if ($account.id_token.chatgpt_account_id // "") != ""
          then {"Chatgpt-Account-Id": $account.id_token.chatgpt_account_id} else {} end end)
    }' 2>/dev/null) || usage_cpa_error 'invalid account metadata'
    envelope=$(usage_cpa_request POST api-call "$request") || exit 1
    if ! jq -e '(.status_code | type == "number") and (.body | type == "string")' <<<"$envelope" >/dev/null 2>&1; then
      usage_cpa_error 'invalid api-call response'
    fi
    vendor_status=$(jq -r '.status_code' <<<"$envelope")
    if ! jq -e '.status_code >= 200 and .status_code < 300' <<<"$envelope" >/dev/null; then
      usage_cpa_error "vendor HTTP $vendor_status"
    fi
    body=$(jq -r '.body' <<<"$envelope")
    if [[ $vendor == zai ]]; then
      usage_zai <<<"$body" || usage_cpa_error 'invalid z.ai usage response'
      continue
    fi
    if ! result=$(jq -ce --arg vendor "$vendor" --argjson account "$account" '
      if type != "object" then error("body") else
      (if $vendor == "claude" then
        if (has("five_hour") | not) or (.five_hour != null and (.five_hour | type != "object")) then error("usage") else
        '"$delegate_usage_claude_projection"' end
      else .rate_limit.primary_window |
        if (.used_percent | type != "number") or (.reset_at | type != "number")
        then error("usage") else
        {usedPercent: .used_percent, remainingPercent: (100 - .used_percent),
         resetsAt: (.reset_at | strflocaltime("%Y-%m-%d %H:%M:%S %Z"))} end
      end) + {account: {auth_index: $account.auth_index,
                        name: ($account.email // $account.name // $account.auth_index)}} end
    ' <<<"$body" 2>/dev/null); then
      usage_cpa_error 'invalid vendor usage response'
    fi
    jq . <<<"$result"
  done < <(jq -c '.[]' <<<"$accounts")
}

usage_zai() {
  jq -e '
  def window: if .unit == 3 then "\(.number)h" else "\(.number)w" end;
  if .code != 200 then error("invalid z.ai envelope code") else . end
  | [.data.limits[]? | select(.unit == 3 or .unit == 6)
      | {key: window,
         value: {usedPercent: .percentage,
                 remainingPercent: (100 - .percentage),
                 resetsAt: (.nextResetTime / 1000 | floor | strflocaltime("%Y-%m-%d %H:%M:%S %Z"))}}] as $windows
  | if $windows == [] then error("z.ai response has no usage windows") else
      {level: .data.level, windows: ($windows | from_entries)}
    end
' 2>/dev/null
}

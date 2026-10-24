# shellcheck shell=bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
readonly delegate_usage_claude_url='https://api.anthropic.com/api/oauth/usage'
readonly delegate_usage_claude_beta='oauth-2025-04-20'
readonly delegate_usage_claude_projection='{five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage}'

usage_cpa_error() {
  printf '%s\n' "usage: CPA $1" >&2
  exit 1
}

usage_cpa_request() {
  local method=$1 endpoint=$2 payload=${3-} response status
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
      --url "${delegate_usage_cpa_url%/}/v0/management/$endpoint" \
      --header 'Content-Type: application/json' --data "$payload" \
      --write-out $'\n%{http_code}' --config - 2>/dev/null <<EOF_CPA
header = "Authorization: Bearer $delegate_usage_cpa_key"
EOF_CPA
  ); then
    unset delegate_usage_cpa_key
    usage_cpa_error 'management request failed'
  fi
  unset delegate_usage_cpa_key
  status=${response##*$'\n'}
  [[ $status == 2?? ]] || usage_cpa_error "management HTTP $status"
  printf '%s' "${response%$'\n'*}"
}

# Shared by the packaged usage helpers; returns 1 only for direct-login fallback.
usage_cpa() {
  local vendor=$1 files accounts account request envelope vendor_status body result
  local delegate_usage_cpa_url delegate_usage_cpa_key_file url_variable key_variable
  # Generic metadata is an explicit override of launcher-provided vendor defaults.
  if [[ -n ${DELEGATE_USAGE_CPA_URL-} || -n ${DELEGATE_USAGE_CPA_MANAGEMENT_KEY_FILE-} ]]; then
    delegate_usage_cpa_url=${DELEGATE_USAGE_CPA_URL-}
    delegate_usage_cpa_key_file=${DELEGATE_USAGE_CPA_MANAGEMENT_KEY_FILE-}
  else
    url_variable="DELEGATE_USAGE_CPA_${vendor^^}_URL"
    key_variable="DELEGATE_USAGE_CPA_${vendor^^}_MANAGEMENT_KEY_FILE"
    delegate_usage_cpa_url=${!url_variable-}
    delegate_usage_cpa_key_file=${!key_variable-}
  fi
  if [[ -z $delegate_usage_cpa_url && -z $delegate_usage_cpa_key_file ]]; then
    return 1
  fi
  if [[ -z $delegate_usage_cpa_url || -z $delegate_usage_cpa_key_file ]]; then
    usage_cpa_error 'requires both CPA URL and management-key file in the generic override or matching vendor pair'
  fi
  files=$(usage_cpa_request GET auth-files) || exit 1
  if ! accounts=$(jq -ce --arg vendor "$vendor" '
    .files | if type != "array" then error("files") else
      map(select(.provider == $vendor and .account_type == "oauth" and .disabled != true)) |
      if all(.[]; (.auth_index | type == "string" and length > 0))
      then . else error("auth_index") end end' <<<"$files" 2>/dev/null); then
    usage_cpa_error 'invalid auth-files response'
  fi
  if [[ $accounts == '[]' ]]; then
    printf 'usage: CPA has no enabled %s login; falling back to direct login\n' "$vendor" >&2
    return 1
  fi
  while IFS= read -r account; do
    request=$(jq -cn --argjson account "$account" --arg vendor "$vendor" \
      --arg claude_url "$delegate_usage_claude_url" --arg claude_beta "$delegate_usage_claude_beta" '{
      auth_index: $account.auth_index,
      method: "GET",
      url: (if $vendor == "claude" then $claude_url
            else "https://chatgpt.com/backend-api/wham/usage" end),
      header: ({Authorization: "Bearer $TOKEN$", "Content-Type": "application/json"} +
        if $vendor == "claude" then {"anthropic-beta": $claude_beta}
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

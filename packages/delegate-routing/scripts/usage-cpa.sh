# shellcheck shell=bash
# cspell:ignore todateiso fromdateiso
readonly delegate_usage_claude_url='https://api.anthropic.com/api/oauth/usage'
readonly delegate_usage_claude_beta='oauth-2025-04-20'
readonly delegate_usage_opencode_url='https://opencode.ai/zen/go/v1/usage'
readonly delegate_usage_zai_url='https://api.z.ai/api/monitor/usage/quota/limit'
# API-key vendors: the upstream hostname and base-URL path prefix that identify
# their key among CPA's configured credentials, whatever transport carries it.
declare -rA delegate_usage_api_keys=(
  [opencode]='opencode.ai /inference/go'
  [zai]='api.z.ai'
)

# All usage techniques and the runtime fixtures read this common schema.
usage_project() {
  jq -ce --arg vendor "$1" --argjson account "${2:-null}" --argjson resets "${3:-null}" '
    def utc:
      if type == "number" then floor | todateiso8601 else
        (capture("^(?<date>.{19})(?:\\.[0-9]+)?(?<zone>Z|[+-][0-9]{2}:[0-9]{2})$") // error("usage timestamp"))
        | (.date + "Z" | fromdateiso8601) -
          (if .zone == "Z" then 0 else
            ((.zone[1:3] | tonumber) * 3600 + (.zone[4:6] | tonumber) * 60)
            * (if .zone[0:1] == "+" then 1 else -1 end) end)
        | todateiso8601
      end;
    def window($seconds; $used; $reset; $status):
      if ($used | type) != "number" then error("usage percent") else
        {usedPercent: $used, remainingPercent: (100 - $used),
         # z.ai omits the reset time of a window that has not started yet.
         resetsAt: (if $reset == null and $used == 0 then null else ($reset | utc) end),
         status: $status, windowSeconds: $seconds} end;
    def duration:
      if . == 604800 then "7d" elif . == 18000 then "5h"
      elif . >= 2419200 and . <= 2678400 then "monthly" else "\(.)s" end;
    # Subtract one UTC calendar month, clamping the day at month end.
    def calendar_month:
      utc | fromdateiso8601 | . as $end
      | gmtime as $reset
      | ($reset | .[2] = 1 | .[3] = 0 | .[4] = 0 | .[5] = 0 | mktime) as $start
      | ($start - 1 | gmtime) as $previous
      | ($previous | .[2] = ([$reset[2], .[2]] | min)
          | .[3] = $reset[3] | .[4] = $reset[4] | .[5] = $reset[5] | mktime) as $begin
      | $end - $begin;
    def named_window($seconds; $scope; $used; $reset; $status):
      {key: (($seconds | duration) + (if $scope == null then "" else ":" + $scope end)),
       value: window($seconds; $used; $reset; $status)};
    def bonuses($count):
      if .credits != null then
        [.credits[] | {kind: "rate_limit_reset", count: 1,
                        expiresAt: ((.expires_at // .expiresAt) | if . == null then null else utc end)}]
      elif ($count // 0) > 0 then
        [{kind: "rate_limit_reset", count: $count, expiresAt: null}]
      else [] end;
    if type != "object" then error("usage body") else . end
    | {pool: $vendor,
       account: {auth_index: ($account.auth_index // null),
                 name: ($account.email // $account.name // $account.auth_index // null),
                 plan: null}, windows: {}, balances: [], bonuses: []} as $base
    | if $vendor == "claude" then
        if has("five_hour") | not then error("claude usage") else . end
        | . as $usage
        | $base + {
            windows: ([
              {seconds: 18000, scope: null, value: .five_hour},
              {seconds: 604800, scope: null, value: .seven_day},
              {seconds: 604800, scope: "opus", value: .seven_day_opus},
              {seconds: 604800, scope: "sonnet", value: .seven_day_sonnet}
              | select(.value != null)
              | named_window(.seconds; .scope; .value.utilization; .value.resets_at;
                  if .seconds == 604800 and .scope == null then
                    ([$usage.limits[]? | select(.kind == "weekly_all") | .severity][0] // null) else null end)
            ] + [
              .limits[]? | select(.kind == "weekly_scoped")
              | named_window(604800; (.scope.model.display_name | ascii_downcase);
                  .percent; .resets_at; if .is_active then "active" else "inactive" end)
            ] | from_entries),
            balances: [ .spend | select(. != null)
              | {kind: "extra_usage", remaining: ((.limit.amount_minor - .used.amount_minor) / pow(10; .limit.exponent)),
                 unit: .limit.currency, expiresAt: null}],
            bonuses: [.promo_credits | select(type == "object") | select(.count | type == "number")
              | {kind: "promo_credits", count: .count, expiresAt: null}]
          }
      elif $vendor == "codex" then
        (.rate_limit // .rateLimits // error("codex usage")) as $limits
        | ($limits.credits // .credits) as $credits
        | (.rate_limit_reset_credits // .rateLimitResetCredits) as $reset
        | $base + {
            account: ($base.account + {plan: (.plan_type // null)}),
            windows: ([($limits.primary_window // $limits.primary), ($limits.secondary_window // $limits.secondary)]
              | map(select(. != null)
                  | named_window((.limit_window_seconds // (.windowDurationMins * 60)); null;
                      (.used_percent // .usedPercent); (.reset_at // .resetsAt); null))
              | if . == [] then error("codex windows") else from_entries end),
            balances: [$credits | select(.has_credits // .hasCredits // false)
              | {kind: "credits", remaining: (.balance | tonumber), unit: "credits", expiresAt: null}],
            bonuses: (try (($resets // $reset) | bonuses($reset.available_count // $reset.availableCount))
              catch (null | bonuses($reset.available_count // $reset.availableCount)))
          }
      elif $vendor == "opencode" then
        .usage as $usage
        | $base + {windows: (["rolling", "weekly", "monthly"] | map(
            . as $name | $usage[$name]
            | if (.status | type) != "string" then error("opencode status") else . end
            | (.windowSeconds // (if $name == "rolling" then 18000
                elif $name == "weekly" then 604800 else (.resetsAt | calendar_month) end)) as $seconds
            | if ($seconds | type) != "number" or $seconds <= 0 then error("opencode duration") else . end
            | named_window($seconds; null; .percent; .resetsAt; .status)) | from_entries)}
      else
        if .code != 200 then error("z.ai envelope") else . end
        | [.data.limits[]? | select(.unit == 3 or .unit == 6)
          | named_window(((if .unit == 3 then 3600 else 604800 end) * .number); null;
              .percentage; (.nextResetTime | if . == null then null else . / 1000 end); null)] as $windows
        | if $windows == [] then error("z.ai windows") else
            $base + {account: ($base.account + {plan: .data.level}), windows: ($windows | from_entries)} end
      end
  ' 2>/dev/null
}

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
  local vendor=$1 files accounts account request envelope vendor_status body result resets reset_request
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
  if [[ -n ${delegate_usage_api_keys[$vendor]-} ]]; then
    # These responses contain upstream keys. Project them in memory only.
    local configs='' surface host prefix
    read -r host prefix <<<"${delegate_usage_api_keys[$vendor]}"
    for surface in claude codex openai-compatibility; do
      configs+=$(usage_cpa_request GET "config/api-keys/$surface" "" v8/management) || exit 1
      configs+=$'\n'
    done
    accounts=$(printf '%s' "$configs" | python3 -c '
import json, sys
from urllib.parse import urlsplit
host, prefix = sys.argv[1:3]
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
            base = urlsplit(group.get("base-url", ""))
            path = base.path.rstrip("/")
            if base.hostname != host or not (path == prefix or path.startswith(prefix + "/")):
                continue
            for key in group.get("keys", []):
                if key.get("api-key") and key.get("auth_index"):
                    candidates.setdefault(key["api-key"], key["auth_index"])
    if len(candidates) != 1:
        sys.exit(2)
    print(json.dumps([{"auth_index": next(iter(candidates.values()))}]))
except (AttributeError, TypeError, ValueError):
    sys.exit(3)
' "$host" "$prefix") ||
      usage_cpa_error "$vendor requires exactly one distinct key with an auth index on $host$prefix"
    unset configs
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
      --arg claude_url "$delegate_usage_claude_url" --arg claude_beta "$delegate_usage_claude_beta" \
      --arg opencode_url "$delegate_usage_opencode_url" --arg zai_url "$delegate_usage_zai_url" '{
      auth_index: $account.auth_index,
      method: "GET",
      url: (if $vendor == "claude" then $claude_url
            elif $vendor == "codex" then "https://chatgpt.com/backend-api/wham/usage"
            elif $vendor == "opencode" then $opencode_url
            else $zai_url end),
      header: ({Authorization: "Bearer $TOKEN$", "Content-Type": "application/json"} +
        if $vendor == "claude" then {"anthropic-beta": $claude_beta}
        elif $vendor == "zai" then {"Accept-Language": "en-US,en"}
        elif $vendor == "opencode" then {Accept: "application/json"}
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
    resets=null
    if [[ $vendor == codex ]]; then
      reset_request=$(jq -c '.url = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"' <<<"$request")
      # Expiry details are optional; the usage response still supplies the count.
      if envelope=$(usage_cpa_request POST api-call "$reset_request" 2>/dev/null); then
        resets=$(jq -ce '
          select(.status_code >= 200 and .status_code < 300) | .body | fromjson
          | select(.credits | type == "array")
        ' <<<"$envelope" 2>/dev/null) || resets=null
      fi
    fi
    if ! result=$(usage_project "$vendor" "$account" "$resets" <<<"$body"); then
      usage_cpa_error 'invalid vendor usage response'
    fi
    jq . <<<"$result"
  done < <(jq -c '.[]' <<<"$accounts")
}

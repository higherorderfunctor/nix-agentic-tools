# shellcheck shell=bash
# cspell:ignore fromdateiso noproxy todateiso
readonly delegate_usage_claude_url='https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1'
readonly delegate_usage_claude_beta='oauth-2025-04-20'
readonly delegate_usage_opencode_url='https://opencode.ai/zen/go/v1/usage'
readonly delegate_usage_zai_url='https://api.z.ai/api/monitor/usage/quota/limit'
# API-key vendors: the upstream hostname and base-URL path prefix that identify
# their key among CPA's configured credentials, whatever transport carries it.
declare -rA delegate_usage_api_keys=(
  [cloudflare]='api.cloudflare.com /client/v4'
  [opencode]='opencode.ai /inference/go'
  [zai]='api.z.ai'
)

# All usage techniques and the runtime fixtures read this common schema.
# The optional fifth argument selects usage (default) or prepaid inventory.
# The caller maps prepaid failures without changing validated main usage.
# shellcheck disable=SC2329 # usage_cpa can also call it by name as its projector.
usage_project() {
  jq -ce --arg vendor "$1" --argjson account "${2:-null}" --argjson resets "${3:-null}" --argjson prepaid "${4:-null}" --arg observation "${5:-usage}" '
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
      if ($used | type) != "number" or ($used | isfinite | not) then error("usage percent") else
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
    # Applicability is a cap, never an attribution to an expiring inventory lot.
    def codex_resets($summary):
      def unavailable($reason): {bonuses: [], missingExtras: [$reason]};
      def supported:
        if has("is_supported_by_plan") then .is_supported_by_plan else .isSupportedByPlan end;
      def expiry:
        if type == "number" then utc else
          . as $raw
          | capture("^(?<date>.{19})(?<fraction>\\.[0-9]+)?(?<zone>Z|[+-][0-9]{2}:[0-9]{2})$") as $parts
          | ($raw | utc | rtrimstr("Z")) + ($parts.fraction // "") + "Z"
        end;
      def valid_expiry:
        if type == "number" then isfinite and floor == . and . >= 0 and . <= 253402300799
        elif type != "string" then false
        elif test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$") | not then false
        else .[0:19] + "Z" | . == (fromdateiso8601 | todateiso8601) end;
      if (.credits | type) != "array" then unavailable("codex-reset-details-unavailable")
      elif any(.credits[]; type != "object") then unavailable("codex-reset-details-unavailable")
      elif any(.credits[]; (.expires_at // .expiresAt) | valid_expiry | not) then unavailable("codex-reset-details-unavailable") else
        # Normalize all expiry values before selection; bad details never become
        # an inventory-count fallback. Keep sub-second precision in emitted lots.
        [.credits[] | . + {expiry: ((.expires_at // .expiresAt) | expiry)}] as $rows
        | ($summary.applicable_available_count // $summary.applicableAvailableCount) as $count
        | if ($count | type) != "number" or ($count | isfinite | not)
            or $count < 0 or ($count | floor) != $count then
            unavailable("codex-reset-applicability-unknown")
          elif $count == 0 then {bonuses: [], missingExtras: []}
          elif any($rows[]; (.status | type) != "string" or
              (.status == "available" and (supported | type) != "boolean")) then
            unavailable("codex-reset-eligibility-unknown")
          else
            [$rows[] | select(.status == "available")
              | select(supported == true)
              | . + {epoch: (.expiry | capture("^(?<date>.{19})(?<fraction>\\.[0-9]+)?Z$")
                  | (.date + "Z" | fromdateiso8601) + ("0" + (.fraction // "") | tonumber))}
              | select(.epoch > now)] as $eligible
            # A Codex reset restores the 5-hour limit, the weekly limit, or both, so it
            # covers the whole pool (scope null). The API reports only how many
            # resets are applicable; count that many, earliest expiry first.
            | if ($eligible | length) < $count then unavailable("codex-reset-eligibility-unknown") else
              {bonuses: [$eligible | sort_by(.epoch) | .[:$count][]
                  | {kind: "rate_limit_reset", remaining: 1, unit: "resets", funding: "unknown",
                   scope: null, usable: true, expiresAt: .expiry}],
               missingExtras: []} end
          end
      end;
    def prepaid_balances:
      if (.promo_tranches | type) != "array" or (.tranches | type) != "array"
          then error("claude prepaid tranches") else . end
        | [((.promo_tranches[] | . + {funding: "promotional"}),
            (.tranches[] | . + {funding: "purchased"}))
           | if (.remaining_amount_minor_units | type) != "number"
               or (.remaining_amount_minor_units | isfinite | not) or .remaining_amount_minor_units < 0
               or .currency != "USD" then error("claude prepaid lot") else . end
           | {kind: "usage_credit", funding, remaining: (.remaining_amount_minor_units / 100),
              unit: .currency, expiresAt: (.expires_at | if . == null then null else utc end), scope: null}];
    def grant_inventory:
      . as $usage | try {
        value: [.cedar_ember.grants[]?
          | if (.id | type) != "string" or .id == ""
              or (.clears | type) != "array" or any(.clears[]; type != "string")
              or (.resets_left | type) != "number" or .resets_left < 0
              or (.resets_left | isfinite | not) or (.resets_left | floor) != .resets_left
              then error("claude grant") else . end
          | {kind: "rate_limit_reset", handle: .id, remaining: .resets_left, unit: "resets",
             funding: "promotional", clears, givesBackWeekly: .gives_back_weekly,
             usable: (if $usage.cedar_ember.eligible == false or .paused == true or .usable_now == false then false
                      elif $usage.cedar_ember.eligible == true and .paused == false and .usable_now == true then true
                      else null end),
             expiresAt: (.ends_at | if . == null then null else utc end)}],
        missing: (if (.cedar_ember.grants | type) == "array" then []
                  else ["claude-grants-unavailable"] end)}
      catch {value: [], missing: ["claude-grants-unavailable"]};
    if $observation == "prepaid" then
      $prepaid | prepaid_balances
    else
    if type != "object" then error("usage body") else . end
    | {pool: $vendor,
       account: {auth_index: ($account.auth_index // null),
                 name: ($account.email // $account.name // $account.auth_index // null),
                 plan: null}, windows: {}, balances: [], bonuses: []} as $base
    | if $vendor == "claude" then
        if has("five_hour") | not then error("claude usage") else . end
        | . as $usage
        | grant_inventory as $grants
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
            # Wallet lots are independent of spend-cap headroom. The evidenced
            # OAuth responses do not establish a cap period or usable credit.
            credit: {cap: (try .spend.limit catch null), spent: (try .spend.used catch null),
                     periodStart: null, periodEnd: null, usable: null},
            balances: [],
            # Preserve provider effects, including unknown targets, rather than
            # infer account/Fable coverage from a grant type or its name.
            grants: .cedar_ember,
            bonuses: $grants.value,
            missingExtras: $grants.missing
          }
      elif $vendor == "codex" then
        (.rate_limit // .rateLimits // error("codex usage")) as $limits
        | ($limits.credits // .credits) as $credits
        | (.rate_limit_reset_credits // .rateLimitResetCredits) as $reset
        | (try (($resets // $reset) | codex_resets($reset))
            catch {bonuses: [], missingExtras: ["codex-reset-details-unavailable"]}) as $extras
        | $base + $extras + {
            account: ($base.account + {plan: (.plan_type // null)}),
            windows: ([($limits.primary_window // $limits.primary), ($limits.secondary_window // $limits.secondary)]
              | map(select(. != null)
                  | named_window((.limit_window_seconds // (.windowDurationMins * 60)); null;
                      (.used_percent // .usedPercent); (.reset_at // .resetsAt); null))
              | if . == [] then error("codex windows") else from_entries end),
            balances: [$credits | select(.has_credits // .hasCredits // false)
              | {kind: "credits", funding: "unknown", scope: null, remaining: (.balance | tonumber), unit: "credits", expiresAt: null}]
          }
      elif $vendor == "cloudflare" then
        $base + {windows: {daily: window(86400; .percent; .reset; null)}}
      elif $vendor == "opencode" then
        .usage as $usage
        | $base + {windows: (["rolling", "weekly", "monthly"] | map(
            . as $name | $usage[$name]
            | if (.status | type) != "string" then error("opencode status") else . end
            | (.windowSeconds // (if $name == "rolling" then 18000
                elif $name == "weekly" then 604800 else (.resetsAt | calendar_month) end)) as $seconds
            | if ($seconds | type) != "number" or ($seconds | isfinite | not) or $seconds <= 0 then error("opencode duration") else . end
            | named_window($seconds; null; .percent; .resetsAt; .status)) | from_entries)}
      else
        if .code != 200 then error("z.ai envelope") else . end
        | [.data.limits[]? | select(.unit == 3 or .unit == 6)
          | named_window(((if .unit == 3 then 3600 else 604800 end) * .number); null;
              .percentage; (.nextResetTime | if . == null then null else . / 1000 end); null)] as $windows
        | if $windows == [] then error("z.ai windows") else
            $base + {account: ($base.account + {plan: .data.level}), windows: ($windows | from_entries)} end
      end
    end
  ' 2>/dev/null
}

# Both Claude transports use the same headers, request sequence and projection.
usage_claude_request() {
  local url=$1 request envelope record status successful encoded_body
  if [[ $delegate_usage_claude_account != null ]]; then
    request=$(jq -cn --argjson account "$delegate_usage_claude_account" --arg url "$url" \
      --arg ua "$delegate_usage_claude_agent" --arg beta "$delegate_usage_claude_beta" '
      {auth_index: $account.auth_index, method: "GET", url: $url,
       header: {Authorization: "Bearer $TOKEN$", "Content-Type": "application/json",
                "User-Agent": $ua, "anthropic-beta": $beta}}')
    envelope=$(usage_cpa_request POST api-call "$request") || return 1
    # Keep the external envelope at one typed boundary. Base64 makes its body
    # one shell field without interpreting provider text as shell syntax.
    record=$(jq -er '
      if (.status_code | type) != "number" then error("claude status") else . end
      | (.status_code >= 200 and .status_code < 300) as $successful
      | if $successful and (.body | type) != "string" then error("claude body") else . end
      | [.status_code, $successful, (if $successful then .body | @base64 else "" end)] | @tsv
    ' <<<"$envelope" 2>/dev/null) || return 1
    IFS=$'\t' read -r status successful encoded_body <<<"$record"
    if [[ $successful != true ]]; then
      printf 'usage: proxy vendor HTTP %s\n' "$status" >&2
      return 1
    fi
    printf '%s' "$encoded_body" | base64 --decode
  else
    # shellcheck disable=SC2154 # The appended vendor script sets delegate_usage_token.
    curl -q --fail --silent --show-error --max-time 75 --config - 2>/dev/null <<EOF_CLAUDE
url = "$url"
header = "Authorization: Bearer $delegate_usage_token"
header = "anthropic-beta: $delegate_usage_claude_beta"
header = "User-Agent: $delegate_usage_claude_agent"
EOF_CLAUDE
  fi
}

usage_claude() {
  local delegate_usage_claude_account=${1:-null} delegate_usage_claude_agent version body result
  local profile org prepaid balances='[]' missing=''
  if ! version=$(claude --version 2>/dev/null) ||
    [[ ! $version =~ ^([0-9]+\.[0-9]+\.[0-9]+([+-][a-zA-Z0-9.-]+)?)(\ \(Claude\ Code\))?$ ]]; then
    printf '%s\n' 'usage: claude version unavailable or invalid' >&2
    return 1
  fi
  delegate_usage_claude_agent="claude-cli/${BASH_REMATCH[1]} (external, cli)"
  body=$(usage_claude_request "$delegate_usage_claude_url") || {
    printf '%s\n' 'usage: claude usage request failed' >&2
    return 1
  }
  result=$(usage_project claude "$delegate_usage_claude_account" null null <<<"$body") || {
    printf '%s\n' 'usage: invalid claude usage response' >&2
    return 1
  }
  # Only the captured OAuth profile field establishes the token's organization.
  # Optional failures preserve main usage without inventing a zero balance.
  if ! profile=$(usage_claude_request 'https://api.anthropic.com/api/oauth/profile' 2>/dev/null) ||
    ! org=$(jq -er '.organization.uuid | select(type == "string") | select(test("^[A-Za-z0-9-]+$"))' <<<"$profile" 2>/dev/null); then
    missing=claude-prepaid-organization-unknown
  elif ! prepaid=$(usage_claude_request "https://api.anthropic.com/api/oauth/organizations/$org/prepaid/credits" 2>/dev/null) ||
    ! balances=$(usage_project claude null null "$prepaid" prepaid <<<null); then
    balances='[]' missing=claude-prepaid-unavailable
  fi
  jq --argjson balances "$balances" --arg missing "$missing" '
    .balances = $balances | .missingExtras = ([$missing | select(. != "")] + .missingExtras)
  ' <<<"$result"
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
    curl -q --noproxy '*' --silent --max-time 75 --request "$method" \
      --url "${delegate_usage_cpa_url%/}/$prefix/$endpoint" \
      --header 'Content-Type: application/json' --data @/dev/fd/3 \
      --write-out $'\n%{http_code}' --config - 3<<<"$payload" 2>/dev/null <<EOF_CPA
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
# Optional arguments: request builder (account JSON on stdin), projector (same
# arguments as usage_project), and an explicit CPA auth index to skip discovery.
usage_cpa() {
  local vendor=$1 files accounts account request envelope vendor_status body result resets reset_request
  local delegate_usage_cpa_url delegate_usage_cpa_key_file url_variable key_variable
  local route=${2:-$vendor} request_builder=${3:-} projector=${4:-usage_project}
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
  if [[ -n ${5:-} ]]; then
    accounts=$(jq -cn --arg index "$5" '[{auth_index: $index}]')
  elif [[ -n ${delegate_usage_api_keys[$vendor]-} ]]; then
    # These responses contain upstream keys. Project them in memory only.
    local configs='' surface host prefix
    local -a surfaces=(claude codex openai-compatibility)
    if [[ $vendor == cloudflare ]]; then surfaces+=(passthrough); fi
    read -r host prefix <<<"${delegate_usage_api_keys[$vendor]}"
    for surface in "${surfaces[@]}"; do
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
    if [[ $vendor == claude ]]; then
      usage_claude "$account" || exit 1
      continue
    fi
    if [[ -n $request_builder ]]; then
      request=$("$request_builder" <<<"$account") || usage_cpa_error 'invalid vendor request'
    else
      request=$(jq -cn --argjson account "$account" --arg vendor "$vendor" \
        --arg opencode_url "$delegate_usage_opencode_url" --arg zai_url "$delegate_usage_zai_url" '{
      auth_index: $account.auth_index,
      method: "GET",
      url: (if $vendor == "codex" then "https://chatgpt.com/backend-api/wham/usage"
            elif $vendor == "opencode" then $opencode_url
            else $zai_url end),
      header: ({Authorization: "Bearer $TOKEN$", "Content-Type": "application/json"} +
        if $vendor == "zai" then {"Accept-Language": "en-US,en"}
        elif $vendor == "opencode" then {Accept: "application/json"}
        else {"User-Agent": "codex-tui"} +
          if ($account.id_token.chatgpt_account_id // "") != ""
          then {"Chatgpt-Account-Id": $account.id_token.chatgpt_account_id} else {} end end)
    }' 2>/dev/null) || usage_cpa_error 'invalid account metadata'
    fi
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
      # Missing lot details preserve usage but cannot establish eligible resets.
      if envelope=$(usage_cpa_request POST api-call "$reset_request" 2>/dev/null); then
        resets=$(jq -ce '
          select(.status_code >= 200 and .status_code < 300) | .body | fromjson
          | select(.credits | type == "array")
        ' <<<"$envelope" 2>/dev/null) || resets=null
      fi
    fi
    if ! result=$("$projector" "$vendor" "$account" "$resets" <<<"$body"); then
      usage_cpa_error 'invalid vendor usage response'
    fi
    jq . <<<"$result"
  done < <(jq -c '.[]' <<<"$accounts")
}

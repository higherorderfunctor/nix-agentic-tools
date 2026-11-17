# shellcheck shell=bash
# cspell:ignore isinfinite isnan
# Reads a monthly budget that CPA Manager+ accounts for one upstream
# credential; usage-cpa.sh is prepended by mkUsageScript and supplies
# usage_cpa_error. Responses stay in memory. Failures print safe messages;
# unpriced models also emit a count diagnostic for delegate-routing-plan.
# Environment: MANAGER_URL (Manager+ base URL) and MANAGER_KEY_FILE (admin key
# file; read in process, sent as Authorization: Bearer through curl --config
# on stdin, never argv).
# Arguments: --provider and --base-url select the credential through Manager+
# credential discovery; --auth-index (repeatable) pins indices instead, which
# survives key rotation and is trimmed of surrounding whitespace; --limit
# (a finite positive USD amount; Manager+ prices in USD only), --reset-day (1..28)
# and --time-zone (IANA name, default UTC) describe the calendar window;
# --pool and --account-name label the output; --now-ms fixes the clock for
# replay and tests. Read by checks/usage-runtime.py and the consumer example
# in docs/development.md.
proxy_usage_request() {
  local method=$1 path=$2 payload=${3-} empty_not_found=${4-} response status
  if [[ ! -r $proxy_usage_key_file ]] || ! proxy_usage_key=$(<"$proxy_usage_key_file") 2>/dev/null; then
    usage_cpa_error 'cannot read management key file'
  fi
  if [[ -z $proxy_usage_key || $proxy_usage_key == *$'\n'* || $proxy_usage_key == *$'\r'* ]]; then
    usage_cpa_error 'management key must be a nonempty single line'
  fi
  proxy_usage_key=${proxy_usage_key//\\/\\\\}
  proxy_usage_key=${proxy_usage_key//\"/\\\"}
  if ! response=$(
    curl -q --silent --max-time 75 --request "$method" \
      --url "${proxy_usage_url%/}$path" \
      --header 'Content-Type: application/json' --data "$payload" \
      --write-out $'\n%{http_code}' --config - 2>/dev/null <<EOF_MANAGER
header = "Authorization: Bearer $proxy_usage_key"
EOF_MANAGER
  ); then
    usage_cpa_error 'management request failed'
  fi
  unset proxy_usage_key
  status=${response##*$'\n'}
  # A missing config collection is an empty credential set, not a hard error.
  if [[ $status == 404 && -n $empty_not_found ]]; then
    printf '[]'
    return
  fi
  [[ $status == 2?? ]] || usage_cpa_error "management HTTP $status"
  printf '%s' "${response%$'\n'*}"
}

readonly proxy_usage_url=${MANAGER_URL:-}
readonly proxy_usage_key_file=${MANAGER_KEY_FILE:-}
proxy_usage_provider='' proxy_usage_base_url='' proxy_usage_limit=''
proxy_usage_reset_day='' proxy_usage_zone=UTC proxy_usage_pool='' proxy_usage_account_name=''
proxy_usage_now_ms='' proxy_usage_index='' proxy_usage_indices=()
[[ -n $proxy_usage_url && -n $proxy_usage_key_file ]] ||
  usage_cpa_error 'requires MANAGER_URL and MANAGER_KEY_FILE'
while [[ $# -gt 0 ]]; do
  case $1 in
  --provider | --base-url | --limit | --reset-day | --time-zone | --pool | --account-name | --now-ms)
    [[ $# -ge 2 ]] || usage_cpa_error "requires a value for $1"
    case $1 in
    --provider) proxy_usage_provider=$2 ;;
    --base-url) proxy_usage_base_url=$2 ;;
    --limit) proxy_usage_limit=$2 ;;
    --reset-day) proxy_usage_reset_day=$2 ;;
    --time-zone) proxy_usage_zone=$2 ;;
    --pool) proxy_usage_pool=$2 ;;
    --account-name) proxy_usage_account_name=$2 ;;
    --now-ms) proxy_usage_now_ms=$2 ;;
    *) usage_cpa_error "unknown argument $1" ;;
    esac
    shift 2
    ;;
  --auth-index)
    [[ $# -ge 2 ]] || usage_cpa_error 'requires a value for --auth-index'
    proxy_usage_index=$2
    proxy_usage_index=${proxy_usage_index#"${proxy_usage_index%%[![:space:]]*}"}
    proxy_usage_index=${proxy_usage_index%"${proxy_usage_index##*[![:space:]]}"}
    [[ -n $proxy_usage_index ]] || usage_cpa_error 'requires a nonempty value for --auth-index'
    proxy_usage_indices+=("$proxy_usage_index")
    shift 2
    ;;
  *) usage_cpa_error "unknown argument $1" ;;
  esac
done
[[ -n $proxy_usage_limit ]] || usage_cpa_error 'requires --limit'
jq -en --arg limit "$proxy_usage_limit" \
  '$limit | tonumber | select((. > 0) and ((isinfinite or isnan) | not))' >/dev/null 2>&1 ||
  usage_cpa_error '--limit must be a finite positive number'
[[ -n $proxy_usage_reset_day ]] || usage_cpa_error 'requires --reset-day'
[[ $proxy_usage_reset_day =~ ^([1-9]|1[0-9]|2[0-8])$ ]] ||
  usage_cpa_error '--reset-day must be an integer from 1 through 28'
[[ -n $proxy_usage_pool ]] || usage_cpa_error 'requires --pool'
[[ -n $proxy_usage_account_name ]] || usage_cpa_error 'requires --account-name'
proxy_usage_now_ms=${proxy_usage_now_ms:-now}
[[ $proxy_usage_now_ms == now || $proxy_usage_now_ms =~ ^[0-9]+$ ]] ||
  usage_cpa_error '--now-ms must be epoch milliseconds'
if [[ ${#proxy_usage_indices[@]} -eq 0 ]]; then
  [[ -n $proxy_usage_provider && -n $proxy_usage_base_url ]] ||
    usage_cpa_error 'credential discovery requires --provider and --base-url'
fi

proxy_usage_status=$(proxy_usage_request GET /status) || exit 1
proxy_usage_collector=$(jq -er '.collector.collector // empty' <<<"$proxy_usage_status" 2>/dev/null) ||
  usage_cpa_error 'invalid status response'
[[ $proxy_usage_collector == running ]] || usage_cpa_error 'collector is not running'

if [[ ${#proxy_usage_indices[@]} -eq 0 ]]; then
  proxy_usage_config=$(proxy_usage_request GET "/v8/management/config/api-keys/$proxy_usage_provider" "" empty) || exit 1
  proxy_usage_discovered=$(
    jq -ce --arg base "$proxy_usage_base_url" \
      '[.[] | select(."base-url" == $base) | .keys[]?.auth_index | select(type == "string")] | unique' \
      <<<"$proxy_usage_config" 2>/dev/null
  ) || usage_cpa_error 'invalid api-keys response'
  proxy_usage_count=$(jq -r 'length' <<<"$proxy_usage_discovered")
  [[ $proxy_usage_count == 1 ]] ||
    usage_cpa_error "credential discovery matched $proxy_usage_count credentials; pass --auth-index to pin"
  mapfile -t proxy_usage_indices < <(jq -r '.[]' <<<"$proxy_usage_discovered")
fi
proxy_usage_indices_json=$(printf '%s\n' "${proxy_usage_indices[@]}" | jq -Rsc 'split("\n")[:-1] | unique')

proxy_usage_window=$(
  python3 -I - "$proxy_usage_now_ms" "$proxy_usage_reset_day" "$proxy_usage_zone" 2>/dev/null <<'PY'
import json
import sys
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

clock, reset_day, zone_name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
now = datetime.fromtimestamp(time.time() if clock == "now" else int(clock) / 1000,
                             tz=ZoneInfo(zone_name))


def boundary(year, month):
    return datetime(year, month, reset_day, tzinfo=now.tzinfo)


def add_months(year, month, delta):
    total = year * 12 + month - 1 + delta
    return total // 12, total % 12 + 1


current = boundary(now.year, now.month)
if current > now:
    start, reset = boundary(*add_months(now.year, now.month, -1)), current
else:
    start, reset = current, boundary(*add_months(now.year, now.month, 1))

start_ms = round(start.timestamp() * 1000)
reset_ms = round(reset.timestamp() * 1000)
print(json.dumps({
    "from_ms": start_ms,
    "now_ms": round(now.timestamp() * 1000),
    "resets_at": reset.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "window_seconds": (reset_ms - start_ms) // 1000,
}))
PY
) || usage_cpa_error 'invalid time zone or clock'

proxy_usage_payload=$(jq -cen --argjson window "$proxy_usage_window" --arg zone "$proxy_usage_zone" \
  --argjson indices "$proxy_usage_indices_json" '{
    from_ms: $window.from_ms,
    to_ms: $window.now_ms,
    time_zone: $zone,
    filters: {auth_indices: $indices, include_failed: true},
    include: {summary: true, summary_profile: "compact", model_stats: true}}')
proxy_usage_from=$(jq -r '.from_ms' <<<"$proxy_usage_window")
proxy_usage_current=$(jq -r '.now_ms' <<<"$proxy_usage_window")
[[ $proxy_usage_from =~ ^[0-9]+$ && $proxy_usage_current =~ ^[0-9]+$ ]] ||
  usage_cpa_error 'invalid time zone or clock'
if ((proxy_usage_from < proxy_usage_current)); then
  proxy_usage_analytics=$(proxy_usage_request POST /v0/management/monitoring/analytics "$proxy_usage_payload") || exit 1
  # Classify once at the analytics boundary: malformed data wins over an
  # unpriced diagnostic, which wins over incomplete but well-typed coverage.
  # Manager+ prices a stat through its billing or pricing model, so coverage is
  # judged from the analytics rows themselves, not a price book: a row that
  # consumed tokens and costs zero is one Manager+ could not price, which must
  # not read as accounted spend. Calls without tokens (failed before use) cost
  # nothing legitimately. A display model that merges a priced and an unpriced
  # billing model shows a positive total and passes; that is the limit of the
  # estimate. The count of unpriced models is reported, never names.
  # Manager+ 1.14.10 monitoring/service.go emits coverage only for deleted
  # raw-event warnings (Response omitempty; analytics coverageWarningRequired).
  # This compact request has no comparison or drill-down: omitted coverage
  # supports zero deleted raw events, not complete accounting or zero spend.
  # Retain the independently validated cost as estimated; unobserved spend is
  # unknown. Present null/partial coverage does not have that source contract.
  # Hourly pricing roll-ups carry no credential key, so deleted raw events or
  # degraded-summary limitations can lower this credential's total.
  proxy_usage_classification=$(jq -sr '
    def valid_analytics_response:
      length == 1 and (.[0] | type == "object"
           and (.summary | type == "object")
           and (.summary.total_cost | type == "number")
           and (.summary.total_cost >= 0)
           and (.summary.total_cost <= 1.7976931348623157e+308)
           and (.summary.total_calls | type == "number")
           and (.summary.total_calls >= 0)
           and (if .summary.total_calls > 0
                then (.model_stats | type == "array" and length > 0)
                else (.model_stats | (type == "array" or type == "null")) end)
           and (all(.model_stats[]?;
                    (.model | type) == "string"
                    and (.calls | type) == "number" and .calls >= 0
                    and (.total_tokens | type) == "number" and .total_tokens >= 0
                    and (.cost | type) == "number" and .cost >= 0
                    and (.cost <= 1.7976931348623157e+308)))
           and (.coverage | (type == "object" or type == "null"))
           and (.coverage.raw_deleted_event_count | (type == "number" or type == "null"))
           and ((.coverage.raw_deleted_event_count // 0) >= 0)
           and (.coverage.fidelity_limitations | (type == "array" or type == "null"))
           and (all(.coverage.fidelity_limitations[]?; type == "string")));
    if valid_analytics_response | not then "invalid"
    else .[0] |
      ([.model_stats[]? | select(.total_tokens > 0 and .cost == 0)] | length) as $unpriced |
      if $unpriced > 0 then $unpriced
      elif has("coverage") and
           (.coverage | .raw_deleted_event_count != 0
            or .fidelity_limitations == null
            or any(.fidelity_limitations[]?;
                   . == "core_metrics_require_raw_events"
                   or . == "extended_summary_metrics_require_raw_events"))
      then "incomplete"
      else "healthy" end
    end' <<<"$proxy_usage_analytics" 2>/dev/null) || usage_cpa_error 'invalid analytics response'
  case $proxy_usage_classification in
  healthy) ;;
  incomplete) usage_cpa_error 'cost coverage incomplete' ;;
  invalid) usage_cpa_error 'invalid analytics response' ;;
  *)
    jq -cn --argjson count "$proxy_usage_classification" '{count: $count, reason: "unpriced-models"}'
    usage_cpa_error "$proxy_usage_classification models have no price in CPA Manager"
    ;;
  esac
else
  # The reset instant itself: an empty range, which Manager+ rejects, and
  # nothing has been spent in the new window yet.
  proxy_usage_analytics='{"summary":{"total_cost":0}}'
fi

if [[ ${#proxy_usage_indices[@]} -eq 1 ]]; then
  proxy_usage_auth_index=$(jq -cen --arg index "${proxy_usage_indices[0]}" '$index')
else
  proxy_usage_auth_index=null
fi
# Divide before scaling so only a truly unrepresentable percent overflows, and
# fail on that instead of printing a clamped double.
proxy_usage_used=$(jq -en --argjson analytics "$proxy_usage_analytics" --argjson limit "$proxy_usage_limit" \
  '$analytics.summary.total_cost / $limit * 100 | select((isinfinite or isnan) | not)' 2>/dev/null) ||
  usage_cpa_error 'used percent is not finite'
jq -cen --arg pool "$proxy_usage_pool" --arg name "$proxy_usage_account_name" \
  --arg resets "$(jq -r '.resets_at' <<<"$proxy_usage_window")" \
  --argjson seconds "$(jq -r '.window_seconds' <<<"$proxy_usage_window")" \
  --argjson auth_index "$proxy_usage_auth_index" \
  --argjson used "$proxy_usage_used" '
  (100 - $used) as $left |
  {pool: $pool,
   account: {auth_index: $auth_index, name: $name, plan: null},
   windows: {monthly: {usedPercent: $used,
                       remainingPercent: (if $left < 0 then 0 else $left end),
                       resetsAt: $resets, status: "estimated", windowSeconds: $seconds}},
   balances: [],
   bonuses: []}' 2>/dev/null || usage_cpa_error 'invalid analytics response'

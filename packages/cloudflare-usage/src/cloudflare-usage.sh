# shellcheck shell=bash
# Composed with usage-cpa.sh by mkUsageScript, which supplies full strict mode.
[[ $# == 1 && ($1 == claude || $1 == codex) ]] || usage_cpa_error 'expected route claude or codex'
[[ -r ${CLOUDFLARE_ACCOUNT_ID_FILE:-} ]] || usage_cpa_error 'requires account-ID file'
delegate_cloudflare_account=$(<"$CLOUDFLARE_ACCOUNT_ID_FILE")
[[ $delegate_cloudflare_account =~ ^[a-fA-F0-9]{32}$ ]] || usage_cpa_error 'invalid account ID'
jq -en --arg limit "${CLOUDFLARE_DAILY_NEURONS_LIMIT:-}" '
  $limit | tonumber | select(isfinite and . > 0)
' >/dev/null 2>&1 || usage_cpa_error 'requires positive finite daily neurons limit'
# One UTC snapshot determines both the query date and next midnight.
delegate_cloudflare_day=$(jq -cn 'now | floor / 86400 | floor | . * 86400')

cloudflare_request() {
  jq -c --rawfile account "$CLOUDFLARE_ACCOUNT_ID_FILE" --argjson day "$delegate_cloudflare_day" '
    {auth_index: .auth_index, method: "POST",
     url: "https://api.cloudflare.com/client/v4/graphql",
     header: {Authorization: "Bearer $TOKEN$", "Content-Type": "application/json"},
     data: ({query: "query WorkersAINeurons($account:String!,$date:Date!){viewer{accounts(filter:{accountTag:$account}){accountTag aiInferenceAdaptiveGroups(limit:1,filter:{date_geq:$date,date_leq:$date}){sum{totalNeurons} count}}}}",
             variables: {account: ($account | rtrimstr("\n")), date: ($day | strftime("%Y-%m-%d"))}} | tojson)}
  ' 2>/dev/null
}

cloudflare_project() {
  local normalized
  normalized=$(jq -ce --rawfile account "$CLOUDFLARE_ACCOUNT_ID_FILE" \
    --arg limit "$CLOUDFLARE_DAILY_NEURONS_LIMIT" --argjson day "$delegate_cloudflare_day" '
    if (.errors // [] | length) != 0 then error("GraphQL errors") else . end
    | .data.viewer.accounts
    | if length != 1 or .[0].accountTag != ($account | rtrimstr("\n")) then error("account") else .[0] end
    | .aiInferenceAdaptiveGroups
    | if type != "array" or length > 1 then error("groups") else . end
    | (if length == 0 then 0 else .[0].sum.totalNeurons end)
    | if type != "number" or (isfinite | not) or . < 0 then error("neurons") else . end
    | {percent: (. / ($limit | tonumber) * 100), reset: ($day + 86400)}
  ' 2>/dev/null) || return 1
  usage_project "$@" <<<"$normalized"
}

usage_cpa cloudflare "$1" cloudflare_request cloudflare_project "${CLOUDFLARE_AUTH_INDEX:-}" && exit 0
usage_cpa_error 'requires matching runtime URL and management-key file'

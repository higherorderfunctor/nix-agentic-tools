# shellcheck shell=bash
# A selected airlock instance renders config.json in ai.services' private runtime directory.
usage_airlock_error() {
  printf '%s\n' "usage: airlock $1" >&2
  exit 1
}

# Shared by the packaged helpers; returns 1 only when airlock is not configured.
usage_airlock() {
  local vendor=$1 route prefix client config helper report result
  route=${2:-$vendor}
  prefix="DELEGATE_USAGE_AIRLOCK_${route^^}"
  local client_variable="${prefix}_CLIENT" config_variable="${prefix}_CONFIG"
  local helper_variable="${prefix}_CONFIG_HELPER"
  client=${!client_variable-}
  config=${!config_variable-}
  helper=${!helper_variable-}
  if [[ -z $client && -z $config && -z $helper ]]; then
    return 1
  fi
  [[ -n $client && (-n $helper || -n $config) ]] || usage_airlock_error 'requires client and config helper or config in the matching runtime selection'
  if [[ -z $config ]]; then
    config=$("$helper") || usage_airlock_error 'selected config path unavailable'
  fi
  [[ $config == /* ]] || usage_airlock_error 'selected config path must be absolute'
  if ! report=$(airlock usage --config "$config" --json 2>/dev/null); then
    usage_airlock_error 'usage report unavailable'
  fi
  if ! result=$(jq -ec --arg vendor "$vendor" --arg client "$client" '
    if .schema_version != 1 or (.credentials | type) != "array" then error("unsupported report") else . end
    | .credentials
    | map(select(.surface == ({claude:"claude_subscription", codex:"codex_rate_limits", zai:"zai_quota"}[$vendor])
      and any(.routes[]?; .client == $client)))
    | if length == 0 then error("no selected credential") else . end
    | .[]
    | if .global_quota_complete != true or (.status != "fresh" and .status != "exhausted") then error("quota incomplete") else . end
    | . as $credential
    | if $vendor == "claude" then
        (reduce .latest_fetch.pools[] as $pool ({};
          .[$pool.label] = {utilization: ($pool.utilized / 1000),
            resets_at: (if $pool.reset_at_unix == null then null else ($pool.reset_at_unix | strftime("%Y-%m-%dT%H:%M:%SZ")) end)}))
        + {account: {name: $credential.credential}}
      elif $vendor == "codex" then
        (.latest_fetch.pools[] | select(.label == "codex_primary")
          | {usedPercent: (.utilized / 1000), remainingPercent: ((.limit - .utilized) / 1000),
             resetsAt: (.reset_at_unix | strflocaltime("%Y-%m-%d %H:%M:%S %Z")),
             account: {name: $credential.credential}})
      else
        {windows: (reduce .latest_fetch.pools[] as $pool ({};
          .[$pool.label | ltrimstr("zai_")] = {usedPercent: ($pool.utilized / 1000),
            remainingPercent: (($pool.limit - $pool.utilized) / 1000),
            resetsAt: ($pool.reset_at_unix | strflocaltime("%Y-%m-%d %H:%M:%S %Z"))})),
         account: {name: $credential.credential}}
      end
  ' <<<"$report" 2>/dev/null); then
    usage_airlock_error 'invalid or incomplete usage report'
  fi
  printf '%s\n' "$result"
}

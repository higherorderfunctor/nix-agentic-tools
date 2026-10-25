# shellcheck shell=bash
# shellcheck disable=SC2154 # Shared constants come from the prepended usage-cpa.sh.
if usage_airlock claude; then exit 0; fi
if usage_cpa claude; then exit 0; fi

delegate_usage_token=$(jq -er '.claudeAiOauth.accessToken' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json")
curl --fail --silent --show-error --config - <<EOF_USAGE | jq "$delegate_usage_claude_projection"
url = "$delegate_usage_claude_url"
header = "Authorization: Bearer $delegate_usage_token"
header = "anthropic-beta: $delegate_usage_claude_beta"
EOF_USAGE
unset delegate_usage_token

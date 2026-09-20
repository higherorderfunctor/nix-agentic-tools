# shellcheck shell=bash
shopt -s inherit_errexit 2>/dev/null || :

delegate_usage_token=$(jq -er '.claudeAiOauth.accessToken' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json")
curl --fail --silent --show-error --config - <<EOF_USAGE | jq '{five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage}'
url = "https://api.anthropic.com/api/oauth/usage"
header = "Authorization: Bearer $delegate_usage_token"
header = "anthropic-beta: oauth-2025-04-20"
EOF_USAGE
unset delegate_usage_token

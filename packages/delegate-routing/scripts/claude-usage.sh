# shellcheck shell=bash
# shellcheck disable=SC2154 # delegate_usage_claude_* are injected by the Nix wrapper
shopt -s inherit_errexit 2>/dev/null || :

if usage_cpa claude; then
  exit 0
fi

delegate_usage_token=$(jq -er '.claudeAiOauth.accessToken' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json")
curl --fail --silent --show-error --config - <<EOF_USAGE | jq "$delegate_usage_claude_projection"
url = "$delegate_usage_claude_url"
header = "Authorization: Bearer $delegate_usage_token"
header = "anthropic-beta: $delegate_usage_claude_beta"
EOF_USAGE
unset delegate_usage_token

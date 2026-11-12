# shellcheck shell=bash
# shellcheck disable=SC2154 # Shared constants come from the prepended usage-cpa.sh.
if usage_cpa claude; then exit 0; fi

# shellcheck disable=SC2034 # usage_claude in the prepended usage-cpa.sh reads it.
delegate_usage_token=$(jq -er '.claudeAiOauth.accessToken' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json")
usage_claude || exit 1
unset delegate_usage_token

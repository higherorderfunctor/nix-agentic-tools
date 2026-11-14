# shellcheck shell=bash
# Claude direct login shares OAuth reads and projection with CPA accounts.
if usage_cpa claude; then exit 0; fi

# shellcheck disable=SC2034 # Read by usage_claude_request in the prepended usage-cpa.sh.
delegate_usage_token=$(jq -er '.claudeAiOauth.accessToken' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json")
usage_claude || exit 1
unset delegate_usage_token

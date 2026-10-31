# shellcheck shell=bash
# shellcheck disable=SC2154 # Shared constants come from the prepended usage-cpa.sh.
[[ ${1-} == claude || ${1-} == codex ]] || {
  echo 'opencode-usage: expected route claude or codex' >&2
  exit 1
}
if usage_cpa opencode "$1"; then exit 0; fi

[[ -r ${OPENCODE_API_KEY_FILE:-} ]] || {
  echo "opencode-usage: OPENCODE_API_KEY_FILE must name a readable file holding the OpenCode Go API key (got: '${OPENCODE_API_KEY_FILE:-}')" >&2
  exit 1
}

delegate_usage_key=$(<"$OPENCODE_API_KEY_FILE")
# The key travels over stdin so it never reaches argv or output.
delegate_usage_body=$(printf 'Authorization: Bearer %s\n' "$delegate_usage_key" |
  curl -q --fail --silent --show-error --max-time 25 \
    -H @- -H 'Accept: application/json' "$delegate_usage_opencode_url")
unset delegate_usage_key
usage_opencode <<<"$delegate_usage_body" || {
  echo 'opencode-usage: invalid OpenCode Go usage response' >&2
  exit 1
}

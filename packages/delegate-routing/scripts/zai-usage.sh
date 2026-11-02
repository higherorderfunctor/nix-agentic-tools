# shellcheck shell=bash
[[ ${1-} == claude || ${1-} == codex ]] || {
  echo 'zai-usage: expected route claude or codex' >&2
  exit 1
}
if usage_cpa zai "$1"; then exit 0; fi

[[ -r ${ZAI_API_KEY_FILE:-} ]] || {
  echo "zai-usage: ZAI_API_KEY_FILE must name a readable file holding the z.ai API key (got: '${ZAI_API_KEY_FILE:-}')" >&2
  exit 1
}

delegate_usage_key=$(<"$ZAI_API_KEY_FILE")
# The key travels over stdin so it never reaches argv or output.
delegate_usage_body=$(printf 'Authorization: Bearer %s\n' "$delegate_usage_key" |
  curl -q --fail --silent --show-error --max-time 25 \
    -H @- -H 'Accept-Language: en-US,en' \
    "${ZAI_API_BASE:-https://api.z.ai}/api/monitor/usage/quota/limit")
usage_zai <<<"$delegate_usage_body"

# shellcheck shell=bash
shopt -s inherit_errexit 2>/dev/null || :

[[ -r ${ZAI_API_KEY_FILE:-} ]] || {
  echo "zai-usage: ZAI_API_KEY_FILE must name a readable file holding the z.ai API key (got: '${ZAI_API_KEY_FILE:-}')" >&2
  exit 1
}

delegate_usage_key=$(<"$ZAI_API_KEY_FILE")
# The key travels over stdin so it never reaches argv or output.
delegate_usage_body=$(printf 'Authorization: Bearer %s\n' "$delegate_usage_key" |
  curl --fail --silent --show-error --max-time 25 \
    -H @- -H 'Accept-Language: en-US,en' \
    "${ZAI_API_BASE:-https://api.z.ai}/api/monitor/usage/quota/limit")
# unit 3 is hours, unit 6 is weeks; the limit type differs between docs and the live API.
jq '
  def window: if .unit == 3 then "\(.number)h" else "\(.number)w" end;
  if .code != 200 then error("z.ai envelope code \(.code): \(.msg)") else . end
  | [.data.limits[]? | select(.unit == 3 or .unit == 6)
      | {key: window,
         value: {usedPercent: .percentage,
                 remainingPercent: (100 - .percentage),
                 resetsAt: (.nextResetTime / 1000 | floor | strflocaltime("%Y-%m-%d %H:%M:%S %Z"))}}] as $windows
  | if $windows == [] then error("z.ai response has no usage windows") else
      {level: .data.level, windows: ($windows | from_entries)}
    end
' <<<"$delegate_usage_body"

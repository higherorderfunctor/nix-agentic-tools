#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: policy-helper.sh   — where a managed policyHelper's appendSystemPrompt lands.
# Mounts ./etc-claude-code at /etc/claude-code (managed-settings.json naming helper.sh) inside
# an unprivileged bwrap namespace: tmp-overlay over /etc, no root, the host /etc is untouched.
# Runs one -p turn through run.sh with an append file (APPFILE-9999) and an inline append
# (APPINLINE-1313), then prints the sentinels of the last system block in byte order:
#   policy-helper: last=sys[<i>] order=<token>,<token>,... tail=<JSON text from the first appended paragraph>
# Work dir: $PROBE_OUT/claude-policy-helper or a fresh temp dir.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$here/../../common/pin.sh"
work="$(probe_workdir claude-policy-helper)"
export CLAUDE_BIN="${CLAUDE_BIN:-$(probe_pkg claude-code)/bin/claude}"
bwrap --dev-bind / / --overlay-src /etc --tmp-overlay /etc --ro-bind "$here/etc-claude-code" /etc/claude-code \
  "$here/run.sh" "$work" policy-helper - -- -p --no-session-persistence --model haiku \
  --append-system-prompt-file "$here/append.md" --append-system-prompt "Inline append sentinel: APPINLINE-1313." hi
python3 -I - "$work/policy-helper" <<'PY'
import json, pathlib, re, sys
case = pathlib.Path(sys.argv[1])
for path in sorted(case.glob("req-*.json")):
    rec = json.loads(path.read_text())
    if rec["path"].startswith("/v1/messages") and "count_tokens" not in rec["path"]:
        blocks = rec["body"]["system"]
        text = blocks[-1]["text"]
        hits = list(re.finditer(r"\b[A-Z]{4,}-\d{4}\b", text))
        start = text.rfind("\n\n", 0, hits[0].start()) if hits else len(text)
        print(f"policy-helper: last=sys[{len(blocks) - 1}] order={','.join(m.group() for m in hits)} "
              f"tail={json.dumps(text[start:])}")
        break
else:
    sys.exit("no messages request")
PY
printf 'work: %s\n' "$work"

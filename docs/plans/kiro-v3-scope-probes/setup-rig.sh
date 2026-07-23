#!/usr/bin/env bash
# Build the /var/tmp/nat-kiro-probe hook rig that probe-hooks.sh drives. Three
# hooks, each appending a distinct marker to fired.log when it fires:
#   home/.kiro/hooks/probe-global.json    (reached via KIRO_HOME)  -> GLOBAL-*
#   work/.kiro/hooks/probe-local.json     (real workspace file)    -> LOCAL-*   (control)
#   work/.kiro/hooks/probe-symlink.json  -> src/probe-symlink.json -> SYMLINK-*
# Outside $HOME on purpose (Claude ancestor-walks for CLAUDE.md; keep no ambient
# config). Rerun freely — it wipes and rebuilds the rig.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

RIG=/var/tmp/nat-kiro-probe
rm -rf "${RIG:?}"
mkdir -p "$RIG/home/.kiro/hooks" "$RIG/home/.kiro/settings" "$RIG/work/.kiro/hooks" "$RIG/src"
: >"$RIG/fired.log"
echo '{}' >"$RIG/home/.kiro/settings/cli.json"
git -C "$RIG/work" init -q

# Emit a {version,hooks:[SessionStart,Stop]} envelope whose actions append
# "<marker>-<trigger>" to fired.log. $1 = hook-name prefix, $2 = marker prefix.
envelope() {
  cat <<JSON
{
  "version": "v1",
  "hooks": [
    { "name": "${1}-start", "trigger": "SessionStart",
      "action": { "type": "command", "command": "sh -c 'echo ${2}-SessionStart >> $RIG/fired.log'" } },
    { "name": "${1}-stop", "trigger": "Stop",
      "action": { "type": "command", "command": "sh -c 'echo ${2}-Stop >> $RIG/fired.log'" } }
  ]
}
JSON
}

envelope probeglobal GLOBAL >"$RIG/home/.kiro/hooks/probe-global.json"
envelope probelocal LOCAL >"$RIG/work/.kiro/hooks/probe-local.json"
envelope probesymlink SYMLINK >"$RIG/src/probe-symlink.json"
ln -s "$RIG/src/probe-symlink.json" "$RIG/work/.kiro/hooks/probe-symlink.json"

echo "rig ready at $RIG"
find "$RIG" \( -type f -o -type l \) -printf '%y %p\n' | sort

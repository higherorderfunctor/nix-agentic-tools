#!/usr/bin/env bash
# Real-home global-hook probe. Settles two things KIRO_HOME isolation cannot
# (the new 2.13.0 global-hooks loader reads the REAL $HOME/.kiro/hooks, ignoring
# KIRO_HOME): (a) do REAL-FILE global hooks fire under v3, and (b) is a symlinked
# global hook (e.g. an HM store-symlinked autoMemory) dropped. Runs in the real
# environment (NO KIRO_HOME) in a neutral fresh cwd, so anything that fires is
# GLOBAL. ADDITIVE + trap-cleaned: only ever creates/removes probe-realglobal.json;
# NEVER touches an existing kiro-memory.json.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

HOOKS="$HOME/.kiro/hooks"
PROBE="$HOOKS/probe-realglobal.json"
LOG=/var/tmp/nat-kiro-probe/realglobal.log
CAP=/var/tmp/nat-kiro-probe/realhome-capture.log
S=kiroreal
TMPCWD="$(mktemp -d /var/tmp/nat-realhome.XXXXXX)"

cleanup() {
  rm -f "$PROBE"
  tmux kill-session -t "$S" 2>/dev/null || true
  rm -rf "${TMPCWD:?}"
}
trap cleanup EXIT

mkdir -p "$HOOKS" /var/tmp/nat-kiro-probe
: >"$LOG"
git -C "$TMPCWD" init -q 2>/dev/null || true

# Snapshot ~/.kiro-memory BEFORE — a live autoMemory Stop would add a per-project
# entry; unchanged after the run = its (symlinked) hook did not fire.
mem_before="$(find "$HOME/.kiro-memory" -maxdepth 1 -mindepth 1 2>/dev/null | sort || true)"

cat >"$PROBE" <<JSON
{"version":"v1","hooks":[
 {"name":"probeRealglobal-start","trigger":"SessionStart","action":{"type":"command","command":"sh -c 'echo REALGLOBAL-SessionStart >> $LOG'"}},
 {"name":"probeRealglobal-stop","trigger":"Stop","action":{"type":"command","command":"sh -c 'echo REALGLOBAL-Stop >> $LOG'"}}
]}
JSON
echo "[probe] temp real-file global hook placed at $PROBE (any autoMemory symlink untouched)"

tmux kill-session -t "$S" 2>/dev/null || true
tmux new-session -d -s "$S" -x 220 -y 60 -c "$TMPCWD" kiro-cli chat

ready=0
for _ in $(seq 1 60); do
  sleep 1
  pane="$(tmux capture-pane -p -S -400 -t "$S" 2>/dev/null || true)"
  if grep -qiE 'ask a question|describe a task' <<<"$pane"; then
    ready=1
    break
  fi
  # A fresh dir may raise a folder-trust prompt; nudge the default.
  if grep -qiE 'trust' <<<"$pane"; then
    tmux send-keys -t "$S" Enter || true
  fi
done
echo "[probe] ready=$ready"

tmux send-keys -t "$S" 'Reply with only the token DONEZO and nothing else.' Enter || true
for _ in $(seq 1 60); do
  sleep 1
  if grep -q 'Stop' "$LOG" 2>/dev/null; then break; fi
done
sleep 3

tmux send-keys -t "$S" '/hooks' Enter || true
sleep 4
tmux capture-pane -p -S -400 -t "$S" >"$CAP.hooks" 2>/dev/null || true
tmux send-keys -t "$S" Escape || true
sleep 1
tmux send-keys -t "$S" '/quit' Enter 2>/dev/null || true
sleep 2
tmux kill-session -t "$S" 2>/dev/null || true

mem_after="$(find "$HOME/.kiro-memory" -maxdepth 1 -mindepth 1 2>/dev/null | sort || true)"

echo
echo "=== realglobal.log (did the REAL-FILE global hook fire?) ==="
if [ -s "$LOG" ]; then sort -u "$LOG" | sed 's/^/  fired: /'; else echo "  (nothing fired)"; fi
echo
echo "=== /hooks enumeration (real-file probe vs any symlinked global hook) ==="
grep -iE 'probeRealglobal|kiro-memory|no hooks' "$CAP.hooks" 2>/dev/null | sort -u | sed 's/^/  /' || echo "  (none)"
echo
echo "=== ~/.kiro-memory changed? (a live symlinked autoMemory Stop would add an entry) ==="
if [ "$mem_before" = "$mem_after" ]; then
  echo "  UNCHANGED -> a symlinked global autoMemory hook did NOT fire"
else
  echo "  CHANGED:"
  comm -13 <(printf '%s\n' "$mem_before") <(printf '%s\n' "$mem_after") | sed 's/^/    +/' || true
fi
echo
echo "Settled reading: REALGLOBAL-* fires -> v3 DOES honor real-file global hooks in ~/.kiro/hooks;"
echo "a symlinked entry in the SAME dir is absent from /hooks and never fires (global loader drops symlinks)."

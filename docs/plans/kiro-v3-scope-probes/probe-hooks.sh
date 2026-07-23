#!/usr/bin/env bash
# v3 hook-scope probe via a REAL interactive TUI (tmux raw pty). Run setup-rig.sh
# first. The headless `--no-interactive` path runs the model but SKIPS the hook
# engine — only the live TUI fires hooks — so we drive a real session with tmux
# send-keys / capture-pane. ORDER MATTERS: the chat TURN goes first (fires
# SessionStart/UserPromptSubmit/Stop for every honored scope -> fired.log is the
# ground truth), THEN /hooks (a modal that would otherwise eat the turn text as
# its filter).
#
# NB: the kiro-cli wrapper already injects `--tui --v3`; do NOT pass them (they
# double and clap aborts). Spends ~1 short turn of the real Kiro account.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

RIG=/var/tmp/nat-kiro-probe
S=kiroprobe
CAP="$RIG/tmux-capture.log"

tmux kill-session -t "$S" 2>/dev/null || true
: >"$RIG/fired.log"
: >"$CAP"
: >"$CAP.hooks"

tmux new-session -d -s "$S" -x 220 -y 60 -c "$RIG/work" \
  env KIRO_HOME="$RIG/home/.kiro" kiro-cli chat

ready=0
for _ in $(seq 1 45); do
  sleep 1
  if tmux capture-pane -p -S -400 -t "$S" 2>/dev/null | grep -qiE 'ask a question|describe a task'; then
    ready=1
    break
  fi
done
echo "[probe] ready=$ready"

# Chat TURN — the definitive firing test for every scope.
tmux send-keys -t "$S" 'Reply with only the token DONEZO and nothing else.' Enter || true
turn=0
for _ in $(seq 1 45); do
  sleep 1
  if grep -q 'Stop' "$RIG/fired.log" 2>/dev/null; then
    turn=1
    break
  fi
done
sleep 3
echo "[probe] turn-stop-detected=$turn"

# /hooks enumeration (loaded-set cross-check), captured last.
tmux send-keys -t "$S" '/hooks' Enter || true
sleep 4
tmux capture-pane -p -S -400 -t "$S" >"$CAP.hooks" 2>/dev/null || true
tmux send-keys -t "$S" Escape || true
sleep 1
tmux capture-pane -p -S -3000 -t "$S" >"$CAP" 2>/dev/null || true
tmux send-keys -t "$S" '/quit' Enter 2>/dev/null || true
sleep 2
tmux kill-session -t "$S" 2>/dev/null || true

echo
echo "=== fired.log (GROUND TRUTH — what v3 actually FIRED) ==="
if [ -s "$RIG/fired.log" ]; then
  sort -u "$RIG/fired.log" | sed 's/^/  fired: /'
else
  echo "  (nothing fired)"
fi
echo
echo "=== /hooks enumeration (what v3 LOADED for this workspace) ==="
grep -iE 'probe(global|local|symlink)|no hooks' "$CAP.hooks" 2>/dev/null | sort -u | sed 's/^/  /' || echo "  (none)"
echo
echo "Read:"
echo "  LOCAL-*   MUST appear -> positive control (real workspace file); absent = probe broken."
echo "  SYMLINK-* absent      -> v3 DROPS symlinked workspace hooks (settled finding)."
echo "  GLOBAL-*  absent HERE -> KIRO_HOME does NOT relocate the global-hooks dir; v3 reads the"
echo "                          the real ~/.kiro/hooks. Use probe-global-realhome.sh for global."

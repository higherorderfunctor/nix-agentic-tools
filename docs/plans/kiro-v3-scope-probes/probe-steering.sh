#!/usr/bin/env bash
# Steering symlink probe. Does v3 DROP a symlinked steering file (like hooks) or
# FOLLOW it (like agents/skills)? Self-contained: builds a workspace rig with a
# real steering file (control) + a symlinked one, both `inclusion: always`, and
# reads which kiro actually loaded via `/context show` (the decisive
# loaded-vs-not signal — no model-recite ambiguity).
#
# ANSWER AS OF 2.21.4 (re-run 2026-09-12): it FOLLOWS. Both the real control and
# the symlink are listed by `/context show`. The behaviour CHANGED at some point
# after 2.13.0, where this probe originally recorded a drop; do not read the old
# conclusion as current. Re-run on a Kiro bump rather than trusting either.
#
# Global steering is NOT covered here — no SAVED script tests it, though the
# 2026-07-23 round did measure it ad hoc at 2.13.0 and found it dropped. To
# re-cover it, place a symlinked file in the REAL ~/.kiro/steering and run in a
# neutral cwd (additive, trap-cleaned — mirror probe-global-realhome.sh).
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

R=/var/tmp/nat-kiro-probe/steer
S=kirosteer

rm -rf "${R:?}"
mkdir -p "$R/home/.kiro/settings" "$R/work/.kiro/steering" "$R/src"
echo '{}' >"$R/home/.kiro/settings/cli.json"
git -C "$R/work" init -q

printf -- '---\ninclusion: always\n---\nBuild marker: REALSTEER.\n' >"$R/work/.kiro/steering/real-steer.md"
printf -- '---\ninclusion: always\n---\nBuild marker: SYMSTEER.\n' >"$R/src/symfile-steer.md"
ln -s "$R/src/symfile-steer.md" "$R/work/.kiro/steering/symfile-steer.md"

tmux kill-session -t "$S" 2>/dev/null || true
tmux new-session -d -s "$S" -x 220 -y 60 -c "$R/work" \
	env KIRO_HOME="$R/home/.kiro" kiro-cli chat --model gpt-5.6-luna

ready=0
for _ in $(seq 1 50); do
	sleep 1
	pane="$(tmux capture-pane -p -S -200 -t "$S" 2>/dev/null || true)"
	if grep -qiE 'ask a question|describe a task' <<<"$pane"; then
		ready=1
		break
	fi
	if grep -qiE 'trust' <<<"$pane"; then tmux send-keys -t "$S" Enter || true; fi
done
echo "[probe] ready=$ready"

tmux send-keys -t "$S" '/context show' Enter || true
sleep 4
tmux capture-pane -p -S -600 -t "$S" >"$R/context.cap" 2>/dev/null || true
tmux send-keys -t "$S" Escape || true
sleep 1
tmux send-keys -t "$S" '/quit' Enter 2>/dev/null || true
sleep 2
tmux kill-session -t "$S" 2>/dev/null || true

echo
echo "=== /context show — steering files kiro LOADED (real vs symlink) ==="
grep -iE 'real-steer|symfile-steer' "$R/context.cap" 2>/dev/null | sort -u | sed 's/^/  /' || echo "  (neither listed)"
echo
echo "Read (WORKSPACE steering only — this rig builds no global steering):"
echo "  both listed     -> v3 FOLLOWS symlinked WORKSPACE steering. This is the"
echo "                     2.21.4 result; the symlink sink is correct for that"
echo "                     surface and copy delivery is not required for it."
echo "  real-steer only -> v3 DROPS symlinked WORKSPACE steering. This was the"
echo "                     2.13.0 result; seeing it again means the behaviour"
echo "                     regressed and workspace steering needs copy delivery"
echo "                     like Kiro hooks already do."
echo
echo "Do NOT carry either outcome to GLOBAL steering (~/.kiro/steering). That"
echo "scope was measured at 2.13.0 (dropped) and has not been re-run since."

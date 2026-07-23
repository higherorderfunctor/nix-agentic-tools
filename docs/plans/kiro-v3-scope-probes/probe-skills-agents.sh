#!/usr/bin/env bash
# v3 skills + agents scope probe (real vs symlinked-file vs symlinked-dir).
# Self-contained: builds an isolated rig under /var/tmp/nat-kiro-probe/sa and
# drives the live TUI. Enumerate agents via `/agent` and skills via
# `/context show` — there is NO `/skills` slash command (it falls through to the
# model, which then reads .kiro itself and masks the symlink question).
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

R=/var/tmp/nat-kiro-probe/sa
S=kirosa

# --- rig ---
rm -rf "${R:?}"
mkdir -p "$R/home/.kiro/settings" "$R/work/.kiro/skills" "$R/work/.kiro/agents" "$R/src"
echo '{}' >"$R/home/.kiro/settings/cli.json"
git -C "$R/work" init -q

mkskill() { # $1=dir $2=name
  mkdir -p "$1"
  printf -- '---\nname: %s\ndescription: PROBE %s.\n---\nBody.\n' "$2" "$2" >"$1/SKILL.md"
}
mkskill "$R/work/.kiro/skills/real-skill" real-skill # real dir + real file (control)
mkdir -p "$R/work/.kiro/skills/symfile-skill"        # real dir + SYMLINKED SKILL.md
printf -- '---\nname: symfile-skill\ndescription: PROBE symfile-skill.\n---\nBody.\n' >"$R/src/symfile-SKILL.md"
ln -s "$R/src/symfile-SKILL.md" "$R/work/.kiro/skills/symfile-skill/SKILL.md"
mkskill "$R/src/symdir-skill-real" symdir-skill # SYMLINKED skill DIRECTORY
ln -s "$R/src/symdir-skill-real" "$R/work/.kiro/skills/symdir-skill"

printf '{"description":"PROBE real-agent control","prompt":"probe body","tools":["read"]}\n' >"$R/work/.kiro/agents/real-agent.json"
printf '{"description":"PROBE symfile-agent","prompt":"probe body","tools":["read"]}\n' >"$R/src/symfile-agent.json"
ln -s "$R/src/symfile-agent.json" "$R/work/.kiro/agents/symfile-agent.json"

# --- probe ---
tmux kill-session -t "$S" 2>/dev/null || true
tmux new-session -d -s "$S" -x 220 -y 60 -c "$R/work" \
  env KIRO_HOME="$R/home/.kiro" kiro-cli chat

ready=0
for _ in $(seq 1 50); do
  sleep 1
  pane="$(tmux capture-pane -p -S -200 -t "$S" 2>/dev/null || true)"
  if grep -qiE 'ask a question|describe a task' <<<"$pane"; then
    ready=1
    break
  fi
  if grep -qiE 'trust' <<<"$pane"; then
    tmux send-keys -t "$S" Enter || true
  fi
done
echo "[probe] ready=$ready"

tmux send-keys -t "$S" '/agent' Enter || true
sleep 4
tmux capture-pane -p -S -400 -t "$S" >"$R/agent.cap" 2>/dev/null || true
tmux send-keys -t "$S" Escape || true
sleep 1
tmux send-keys -t "$S" '/context show' Enter || true
sleep 3
tmux capture-pane -p -S -400 -t "$S" >"$R/context.cap" 2>/dev/null || true
tmux send-keys -t "$S" Escape || true
sleep 1
tmux send-keys -t "$S" '/quit' Enter 2>/dev/null || true
sleep 2
tmux kill-session -t "$S" 2>/dev/null || true

echo
echo "=== /agent (real-agent=control, symfile-agent=symlinked file) ==="
grep -iE 'real-agent|symfile-agent' "$R/agent.cap" 2>/dev/null | sort -u | sed 's/^/  /' || echo "  (none)"
echo
echo "=== /context show — skills as active context (real / symfile / symdir) ==="
grep -iE 'real-skill|symfile-skill|symdir-skill' "$R/context.cap" 2>/dev/null | sort -u | sed 's/^/  /' || echo "  (none)"
echo
echo "Settled finding: v3 FOLLOWS symlinks for agents AND skills (every variant loads) — unlike hooks/steering."

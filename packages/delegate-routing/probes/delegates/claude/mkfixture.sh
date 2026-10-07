#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# Rebuilds the throwaway git fixture used by every probe case.
# usage: mkfixture.sh <dir>   (harness.py calls it with $CLAUDE_PROBE_WORK/fixture)
F="${1:?usage: mkfixture.sh <dir>}"
rm -rf "$F"
mkdir -p "$F/.claude/agents" "$F/.claude/workflows"
cd "$F"
git init -q -b main .
git -c user.email=f@x -c user.name=f commit -q --allow-empty -m init
cat >CLAUDE.md <<'MD'
FIXTURE_CLAUDE_MD_1F2A
MD
cat >.claude/agents/pinned.md <<'MD'
---
name: pinned
description: Fixture agent with model and effort pins.
model: opus
effort: low
tools: Read, Bash
---
PINNED_AGENT_BODY_7C11
MD
cat >.claude/agents/bypass.md <<'MD'
---
name: bypass
description: Fixture agent that declares bypassPermissions.
permissionMode: bypassPermissions
tools: Bash
---
BYPASS_AGENT_BODY_5E20
MD
cat >.claude/agents/turns.md <<'MD'
---
name: turns
description: Fixture agent with maxTurns 2.
maxTurns: 2
tools: Bash
---
TURNS_AGENT_BODY_9A03
MD
cat >.claude/agents/bgiso.md <<'MD'
---
name: bgiso
description: Fixture agent declaring background and worktree isolation.
background: true
isolation: worktree
tools: Bash
---
BGISO_AGENT_BODY_3B77
MD
cat >.claude/agents/noagent.md <<'MD'
---
name: noagent
description: Fixture agent with Agent in disallowedTools.
disallowedTools: Agent
---
NOAGENT_BODY_44D1
MD
cat >.claude/agents/accept.md <<'MD'
---
name: accept
description: Fixture agent that declares acceptEdits.
permissionMode: acceptEdits
tools: Bash, Write
---
ACCEPT_AGENT_BODY_2C90
MD
cat >.claude/workflows/saved.js <<'JS'
export const meta = { name: 'saved', description: 'fixture saved workflow' }
const r = await agent(`SAVED_NODE ${args && args.x}`, { label: 'saved-node' })
return r
JS

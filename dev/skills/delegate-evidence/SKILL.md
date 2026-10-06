---
name: delegate-evidence
description: >-
  Use when the delegate-routing skill seems not to work, or before stating how
  Claude, Codex, Kiro or Kimchi actually behave: delegation, nesting, model or
  effort reach, system prompts, worktrees, hooks. Answer from the delegate map
  or the acceptance suite, never from memory.
---

# Delegate evidence

Two sources answer questions about harness behavior. Use them instead of memory.

## The map: how each harness behaves

`packages/delegate-routing/docs/delegates/` holds the map. Start at its
`README.md`. Every fact cell carries an evidence mark and a case id, such as
`claude:depth`. `evidence.md` lists the pinned versions and the open unknowns.

To rerun a row, look up its case id in
`packages/delegate-routing/probes/delegates/<harness>/README.md`. That table
gives the exact command and the expected output. There is no single runner.

## The acceptance suite: does the skill route correctly

`packages/delegate-routing/eval/` holds real-session cases that check what the
skill makes an agent decide. Render every case without a login:

```bash
python3 packages/delegate-routing/eval/run.py --set vendor --render-only --repeat 1 --out "$(mktemp -d)"
```

A live run costs model turns and needs the safety preflight described in
`eval/README.md`. Its command adds `--allow-paid --safety-preflight <file>`.

## Rules

- Make no claim about harness behavior without a map row or a run. If the map
  lacks it, add a case to that harness's probe directory and run it.
- Run login-free cases yourself. Cases marked OFFLINE, fake-provider or
  capture-mock cases need no account.
- For a case that needs a login, an account or a paid turn, give the operator a
  numbered list of steps: the setup, the exact command, and what output to send
  back.

## When the operator reports the skill misbehaving

1. Run the acceptance suite cases for the reported behavior.
2. Run the map rows behind the failing behavior, to see what the harness really
   does at the pinned version.
3. Fix the skill, the configuration, or the map.
4. Report what the evidence showed, citing the case ids and outputs.

# Delegate reference

How Claude Code, Codex, Kiro and Kimchi start, control and prompt their
delegates, at pinned versions. Use it to decide what a normalized delegation
option can promise in each harness, and what would have to move outside them.
Every fact cell carries an evidence mark. Probe scripts for replay live in
`packages/delegate-routing/probes/delegates/<harness>/`.

## Files

| Topic            | File                                       | Answers questions like                                                           |
| ---------------- | ------------------------------------------ | -------------------------------------------------------------------------------- |
| Delegate tools   | [tools.md](tools.md)                       | What starts a delegate? Max depth? Max concurrency? Workflows?                   |
| Lifecycle        | [lifecycle.md](lifecycle.md)               | Can I steer, cancel, resume or time out a running child?                         |
| Control surfaces | [control-surfaces.md](control-surfaces.md) | Which config key, flag, env var or patch sets model, effort, tools, permissions? |
| System prompt    | [system-prompt.md](system-prompt.md)       | What prompt does each delegate kind get? Which append channel reaches it?        |
| Evidence         | [evidence.md](evidence.md)                 | How was each row proven? How do I rerun it after a version bump?                 |

Use [evidence.md](evidence.md) for pins, marks and replay methods. The topic
files own the facts; their exceptions and evidence marks apply to each decision.

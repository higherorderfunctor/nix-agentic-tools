## Delegate sizing

> **Last verified:** 2026-09-19 (commit ebf06268) — the runtime-specific table
> and delegation controls now belong to the delegate-sizing skill package.

Load the delegate-sizing skill before delegating. Enable it with
`ai.programs.delegate-sizing.enable`; it sizes model and effort for delegates
and workflow nodes in Claude, Codex and Kiro.

The five always-on rules live in
[`packages/delegate-sizing/fragments/skill-routing.md`](../../../packages/delegate-sizing/fragments/skill-routing.md)
and are delivered through the skill-module factory's rules hook. This retired
orientation fragment is no longer registered, avoiding a second always-on copy.

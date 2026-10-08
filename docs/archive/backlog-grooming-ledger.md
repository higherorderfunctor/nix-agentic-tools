# Historical documentation grooming candidates

**Archived 2026-09-12.** The package-restructure synthesis and redesign are
complete. Use [Repository ownership and layout](../repository-layout.md) as the
settled reference. The old resume menu, fixture-first sequence, and claims that
the restructure was unimplemented have been retired.

The separate documentation-grooming candidates below came from the June 2026
audit. Their status claims are historical and were not re-audited by the
package-layout cleanup. They are retained to avoid losing unrelated work; they
do not authorize another sweep. Paths in the table are relative to `docs/`.

| File                                                          | Why                                                                                           |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `ai-rules-livelink-plan.md`                                   | Feature shipped then REVERTED (`056c7ad`).                                                    |
| `concepts.md`                                                 | grill-me glossary stub (Q-GRILL retire).                                                      |
| `plans/ci-darwin-nuscht-and-update-timeout.md`                | COMPLETE — 3 CI fixes landed.                                                                 |
| `plans/claude-effort-pin-and-mutable-state-reconciliation.md` | SUPERSEDED by convergence; forensics safe in memory `project_claude_effort_pin_state`.        |
| `plans/kiro-agent-engine-and-mode.md`                         | COMPLETE — `v3` bool shipped (`19a87a9`).                                                     |
| `plans/per-cli-model-and-thinking-config.md`                  | SUPERSEDED by convergence; shipped.                                                           |
| `plans/typed-model-and-thinking-config-convergence.md`        | COMPLETE (`94d2262`). ⚠ memory cites it as canonical handoff — update memory if path changes. |
| `plans/typed-model-and-thinking-config-implementation.md`     | COMPLETE — 7+1 commits landed.                                                                |

The original audit also proposed removing `spiral-context.md` and reviewing the
`grill-me` skill, while retaining the harness work and unrelated plans. Those
separate proposals are unchanged by this cleanup. Its description of `plan.md`
as absent from main was stale; the file is tracked and was not changed here.

The
[complete original ledger](https://github.com/higherorderfunctor/nix-agentic-tools/blob/3510a5dbc816a1598e0ff0c357c0c237dc78b267/docs/backlog-grooming-ledger.md),
including its historical dispositions, remains in Git history.

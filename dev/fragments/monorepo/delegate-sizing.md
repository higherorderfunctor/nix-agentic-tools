## Delegate Sizing — choose the model AND the effort per delegate

> **Last verified:** 2026-09-02 (commit pending — first version, corrected
> before merge after a Codex review found that the initial draft mistook
> `[agents]` defaults for the only sizing controls. Codex also supports explicit
> spawn overrides and model/effort settings in custom agent files.) If a harness
> gains or loses a per-delegate model or effort control, update the routing
> table in the same commit — a table cell that is wrong is worse than one that
> says `unknown`.

An unsized delegate inherits the session's model and reasoning effort unless a
spawn override, agent default or custom agent configuration says otherwise. When
the session is pinned to the most capable model at the highest effort, **every
unsized delegate repeats that expensive choice**. That is the failure this
section exists to prevent.

In the operator's words:

> "not sure i need to spend fable token prices on all your subagents when opus
> for reasoning or sonnet for mechanical extraction is likely fine. size the
> correct model, and also effort level. you are cranked to the max, when
> medium/high would otherwise be fine."

### The rule

- **Mechanical delegate** — read, grep, measure, run a check, copy, format,
  commit: **cheapest capable model, medium or low effort.** The work is lookup
  and transcription. Nothing about it is decided by judgement, so paying for
  judgement buys nothing.
- **Reasoning delegate** — synthesis, verification judgement, design assessment,
  refute/defend: **mid-tier reasoning model, high effort.** A delegate whose
  output the operator ACTS ON is a reasoning delegate even when most of its work
  is reading. The test is what the output is used for, not what the delegate
  does to produce it.
- **Top tier and maximum effort only when the operator asks, or when the call is
  genuinely hard.** Hard, not important. An important question with a mechanical
  answer is still mechanical, and "this matters" is not evidence that a bigger
  model would answer it differently.

**Set the sizing with the harness's concrete controls, then say the exact choice
in the launch message.** One line — "sized `gpt-5.6-luna`/low: mechanical
extraction" — makes the choice reviewable. The prose is audit metadata, not the
control: a delegate with no concrete override or configured default is unsized
no matter what its prompt claims. A follow-up cannot resize a running delegate;
interrupt or close it and respawn it when the choice changes.

### Size each STAGE of a fan-out, not the fan-out

A fan-out is not one sizing decision. The finders in a review fan-out are
mechanical — open the cited line, check whether it says what the diff claims —
while the contest stage is pure judgement, and those two stages want different
models. Size them separately.

**The stage that dominates cost is rarely the one you were thinking about.**
Finders are bounded by however many lenses you pick; the contest stage is
bounded by findings, which nothing caps. See the review loop's own sizing rules
in the Git Workflow section — that is this rule applied to review, not a
separate policy, and it is where the measured agent counts live.

### Sizing never lowers a correctness rule

Sizing is a budget decision, not a rigor decision. A cheaper delegate still owes
the same evidence: positive controls proving what it claims to have checked,
measurements rather than recollection, and paths and line numbers a reader can
chase. If a task cannot meet those bars on the cheap model, that is a signal to
size it UP, not to relax them.

The one thing a cheaper model changes is what you may delegate to it: give a
mechanical delegate a question with a checkable answer, not an open judgement
call it will answer confidently and wrongly.

### Routing table — per-harness primitives

Verify a cell before relying on it. **`unknown` means the sources named below do
not answer it** — a guess here would be indistinguishable from a fact, and the
whole point of the column is to tell you which control actually exists.

| Harness     | Delegate primitive                                                             | Per-delegate model                                                                             | Per-delegate effort                                                                        | Orchestration primitive                                                                                                     |
| ----------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| Claude Code | subagent, and `agent()` inside a workflow script                               | yes, per call — `agent()` takes `model`, documented as defaulting to the session model         | yes, per call — `agent()` takes `effort` (`low` … `max`)                                   | workflow scripts: `parallel()`, `pipeline()`, `phase()`, and a shared token `budget` that throws once spent                 |
| Codex       | native subagent tools; built-in roles and custom agents under `.codex/agents/` | yes — explicit spawn `model`; custom-agent `model`; `[agents].default_subagent_model` fallback | yes — spawn `reasoning_effort`; custom-agent `model_reasoning_effort`; `[agents]` fallback | prompt-driven spawn, follow-up/steer, wait/collect, inspect and interrupt/close; no separate workflow-script DSL documented |
| Copilot CLI | agent record emitted under `agents/`                                           | unknown — the record carries no model field                                                    | unknown — the record carries no effort field                                               | unknown                                                                                                                     |
| Kiro CLI    | workflow `step` agent, `orchestrate_subagent`, and static agent definitions    | yes — per-step `modelId` cascading step over workflow over session, and a per-agent `model`    | yes — per-step `effortLevel`, and a per-agent `effortLevel`                                | workflow JSON node types: `step`, `sequence`, `parallel`, `repeat`, `watch`                                                 |
| Kimchi      | none — its supported pools carry no agent surface                              | not applicable                                                                                 | not applicable                                                                             | none documented                                                                                                             |

Sources: `dev/references/claude-workflows.md` §2; the
[OpenAI Codex Subagents documentation](https://learn.chatgpt.com/docs/agent-configuration/subagents),
the live `spawn_agent` tool contract and
`packages/chatgpt-codex/lib/mkCodex.nix`;
`packages/copilot-cli/lib/mkCopilot.nix` and `lib/ai/agent.nix`;
`packages/kiro-cli/lib/mkKiro.nix` plus `dev/references/kiro-workflows.md` §10;
`packages/kimchi/lib/mkKimchi.nix` (`supportedPools`).

**The repo's portable agent core has no cross-harness sizing fields.**
`lib/ai/agent.nix` declares `codex`, `description`, `instructions` and `tools`;
there is no portable top-level model or effort. Native extensions CAN carry
them: a Codex record accepts `ai.agents.<name>.codex.model` and
`model_reasoning_effort`, while Kiro's separate native agent schema accepts
`model` and `effortLevel`. Launch-time overrides remain the right control for an
ad hoc delegate.

For Codex, resolution begins with an explicit spawn value, then the matching
`[agents]` default, then the parent value; a custom agent file's `model` or
`model_reasoning_effort` overrides that resolved value. In the live
`spawn_agent` contract, per-call model or effort overrides require
`fork_turns = "none"` or a bounded positive history. A full-history fork
inherits the parent and rejects those overrides.

Kiro's §10 also carries the only price this repo has actually MEASURED for this
rule: 27 mechanical workers moved from a 2.2× model to a 0.4× model is a **5.5×
cost reduction on work that runs one shell command.** It points at its own
counterweight in §7.3 — a step whose captured output the run depends on can come
back EMPTY under a model that is too cheap — which is why the rule above says
"cheapest CAPABLE" and not "cheapest".

**Where a harness has no per-delegate control, the sizing decision moves up to
the session.** Pick the session model and effort for the session's DOMINANT
work, and do the off-profile work inline rather than delegating it — a delegate
that cannot be sized down is not cheaper than doing it yourself, and it costs a
context round trip on top.

**Do not restate a harness's delegate API beyond this table.** Tool and option
descriptions are authoritative and they change; a fragment that copies them
becomes a confidently wrong second source. The table records WHICH control
exists and WHERE, and stops there.

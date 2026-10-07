# System prompt per delegate kind

What prompt each delegate kind gets, how an agent prompt relates to the vendor
base, which channels add text, and what one normalized option can promise. Pins,
marks and capture methods: [evidence.md](evidence.md).

**Kinds:** K1 main interactive · K2 headless · K3 protocol (SDK / app-server /
ACP) · K4 built-in sub-agents · K5 named sub-agents · K6 ephemeral sub-agents ·
K7 workflows · K8 other model turns (compaction, title, hooks, helpers).

## What "append" means

| Harness | Where extra text lands                                                                                       | Wire role                                                                                                       | Reaches sub-agents?                                                                              |
| ------- | ------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Claude  | Tail of the last system block (main); separate hidden flag for children                                      | system                                                                                                          | Fork: main append. Others: child channel, `-p` only (V)                                          |
| Codex   | `developer_instructions`: a developer message beside the base                                                | developer (lite models have no system slot)                                                                     | Inherited unless replaced                                                                        |
| Kiro    | Always-on steering file, placed **before** base/agent prompt                                                 | user (`history[0]`); main requests move it to a top-level `systemPrompt` when the account flag is on (V client) | Invoke children, orchestrate stages, workflow steps (file steering only) (V)                     |
| Kimchi  | Tail of the single system message, after the rebuilt Kimchi base; CLI or file, ACP `_meta`, hook, memory (V) | `developer` for reasoning models that support it, else `system` (V)                                             | Append-mode named agents only, inside `<inherited_system_prompt>` (V; `claude:sp-p01-print-all`) |

## Defaults per kind

Cell = vendor base · extra text reaches? · mark. Channel: Claude K1–K3/K8 main
append, K4–K7 sub-agent append; others as above.

| Kind | Claude                                                    | Codex                                                                  | Kiro                                                                                      | Kimchi                                                                                                                                                  |
| ---- | --------------------------------------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| K1   | Base (27.4k) · Yes · V                                    | Catalog base · Yes · V (`codex:T1`)                                    | KAS base · steering before base · A (TUI)                                                 | Kimchi base (rebuilt) · Yes · V RPC, I TUI (`claude:sp-p02-rpc-turns-compact`)                                                                          |
| K2   | Base, "Agent SDK" identity · Yes · V                      | Catalog base · Yes · V                                                 | KAS base · steering before base · V (`w-v3`, `pr-hl-invoke`)                              | Kimchi base (rebuilt) · Yes · V (`claude:sp-p01-print-all`)                                                                                             |
| K3   | Base · Yes if host sends no prompt field · V              | Catalog base · Yes if no RPC dev text · V                              | KAS base · file + inline steering · V (`k3-dup`, `pr-acp-invoke`)                         | Kimchi base · RPC as `-p`; ACP flag + `_meta`, never `APPEND_SYSTEM.md` · V                                                                             |
| K4   | None; own body + tail · sub-agent append Yes, main No · V | Parent's base · Yes, inherited · V/I                                   | Named built-in body · inherited steering · V; A (`codex:R3`, `codex:R6`)                  | None; replace header + persona · **No** · V (`claude:sp-p01-print-all`)                                                                                 |
| K5   | None; body replaces · sub-agent append Yes · V            | Parent base + role text · **No** if role has text · V                  | Body replaces · inherited steering · V (`a3-invoke`, `pr-hl-invoke`)                      | `prompt_mode` replace (default): **No**; append: Yes, inherited · V                                                                                     |
| K6   | None; general-purpose body · sub-agent append Yes · V     | Parent's base · Yes, inherited once · V                                | Inline body replaces · inherited steering · V (`claude:k-pins`)                           | None; General-Purpose replace body · **No** · V (`claude:sp-p01-print-all`)                                                                             |
| K7   | None; `workflow-subagent` body · sub-agent append Yes · V | No workflow kind; K4–K6 rules · I                                      | Step body replaces base · file steering only, no ACP inline · V (`pr-hl-wf`, `pr-acp-wf`) | In-session: parent prompt, Yes; background: rebuilt base, files Yes, flags **No** · V                                                                   |
| K8   | Compaction: parent system · Yes (copied) · V              | Local compaction: session base · Yes; remote V2: full prompt · Yes · V | Compaction keeps `history[0]` · Yes; title · No · V (`pr-hl-compact*`, `pr-acp-compact`)  | Fixed title / compaction / memory systems · **No** · V (`claude:sp-p01-print-all`, `claude:sp-p02-rpc-turns-compact`, `claude:sp-p17-rpc-memory-turns`) |

Title reach: Claude No (Vr; `codex:prompt-functions`); Codex config Yes, TUI
only (V; `codex:T1`); Kiro No (V; `pr-hl-compact`); Kimchi No (V;
`claude:sp-p01-print-all`). Exceptions are footnoted under each harness's
channel table.

## What one normalized option can promise

| Kind | Promise | Who fails                                                                            | Consequence                                                                                                                                                                                                                                          |
| ---- | ------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| K1   | **Yes** | None by default                                                                      | Claude `--resume` and Kiro resume re-send old text: a change needs a fresh session. Kiro text sits before the prompt                                                                                                                                 |
| K2   | **Yes** | None                                                                                 | Codex keeps only the top layer: the option must own it                                                                                                                                                                                               |
| K3   | Partial | Claude, Codex (host field overrides)                                                 | CLI/file channel works only while the host sends nothing; a host that appends drops the file (ACP `_meta.systemPrompt.append`, TS preset append); the Python SDK default replaces the base but keeps the file. Kimchi ACP ignores `APPEND_SYSTEM.md` |
| K4   | Partial | Kimchi (built-in personas get no parent text)                                        | Claude needs the sub-agent channel; Codex reaches unless `subagent_developer_instructions` set                                                                                                                                                       |
| K5   | Partial | Codex (role with own text), Kimchi (`prompt_mode: replace`, the default)             | Agent definition wins; reach depends on how each agent is written                                                                                                                                                                                    |
| K6   | Partial | Kimchi (General-Purpose replace body); Kiro v2 engine (not used by this config): N/A | Claude non-fork via sub-agent channel, fork via main; Codex inherited                                                                                                                                                                                |
| K7   | Partial | Kimchi background steps (flags; files reach) (V; `claude:sp-p15-workflow-steps`)     | Claude reaches; Kiro steps get file steering, not ACP inline (V); Codex uses K4–K6 rules                                                                                                                                                             |
| K8   | **No**  | Most titles; Kimchi compaction (fixed system)                                        | No universal guarantee; Codex config title/recap V (TUI); Kiro compaction keeps steering                                                                                                                                                             |

- **Claude needs two channels.** Main append reaches fork children (V). Non-fork
  children need the sub-agent channel (V), which works in `-p` only (V); it does
  not reach main (V).
- **Kiro text is never system-role** unless the account's
  `system_field_injection` flag is on. The client half is V (`mx-sysfield`); the
  flag was off for the one probed account (V LIVE); other accounts are U.
- **"Keep the vendor base" cannot be promised.** Claude and Kiro agent prompts
  replace it. Kimchi always rebuilds its own base over Pi's, and silently drops
  `--system-prompt` and `SYSTEM.md` (V; `claude:sp-p10-system-flag`,
  `claude:sp-p11-system-files`).

Open questions and settling steps: [evidence.md](evidence.md#open-unknowns).

## Channels per harness

"Twice" = the channel set twice or in two layers.

### Claude

| Channel                                                          | Effect                                                                                 | Twice                                                                                         | Reaches                                                                                    | Mark  |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ----- |
| `--append-system-prompt`; hidden `-file`                         | Adds at the end of the last system block; file first, then inline⁷                     | Last `-file` wins (a later user file replaces a wrapper's); file + inline combine, file first | K1–K3, K6 fork, K8 compaction¹ ²                                                           | V     |
| `--system-prompt[-file]`                                         | Replaces body, identity line kept; append too³                                         | Last wins; file + inline combine                                                              | K1–K3 main                                                                                 | V     |
| `--append-subagent-system-prompt[-file]` (hidden, `-p`)          | Adds after child tail                                                                  | Last wins; inline + file = **error rc 1**                                                     | K4, K5, K6 non-fork, K7, nested; not main or fork; no child in TUI, nor in `--bg` (I)⁴     | V     |
| SDK `initialize.appendSystemPrompt` / `.systemPrompt`            | Adds, **replacing** CLI append / replaces body and CLI `--system-prompt`               | —                                                                                             | K3 main                                                                                    | V     |
| SDK `initialize.appendSubagentSystemPrompt`                      | Adds, only with env gate⁵                                                              | —                                                                                             | K3 children                                                                                | V     |
| SDK repeated `initialize`                                        | Prompt slots unchanged                                                                 | First initialization kept                                                                     | K3                                                                                         | I     |
| Real SDK / ACP hosts                                             | What each sends by default⁸                                                            | —                                                                                             | K3 main                                                                                    | V     |
| Agent body / JSON `prompt`                                       | Replaces base; harness tail follows⁶                                                   | —                                                                                             | K1 `--agent`, K5, K7 `agentType`                                                           | V     |
| Plugin `prompt.compose` / `prompt.section` hooks                 | Compose adds sections before the CLI append; section rewrites or drops a named section | —                                                                                             | Main system; `env_info_model` (first user message) in main and children; not child systems | V     |
| Managed `policyHelper.appendSystemPrompt`                        | Adds after CLI file and inline, blank-line separated                                   | One helper, from the highest managed source (A)                                               | K2 (`claude:policy-helper`); K1 (I)                                                        | V     |
| CLAUDE.md, rules, output style, skills, hook `additionalContext` | **User message**, not system                                                           | Combine                                                                                       | Main + children (Explore/Plan drop CLAUDE.md); not hooks/title                             | V / I |

1. Lost when: host sends `initialize.appendSystemPrompt` (V); K1/K2 `--resume`
   with snapshot on (default) re-sends the first session's text (V), fixed by
   `--system-prompt-snapshot off` (V); K1 internal `overrideSystemPrompt` (I);
   hook `type:"prompt"` / `type:"agent"` (V); compaction fallback (I). Also
   reaches suggestions, memory and plugin `model.fork` as a copied parent system
   (I). `fork` (`CLAUDE_CODE_FORK_SUBAGENT=1`) copies the parent system: main
   append yes, sub-agent append no (V). Gated paths (V): coordinator `-p` main
   keeps the base and the main append, and its `worker` child gets the worker
   body and the sub-agent append (`claude:gated-coordinator`); a TUI in-process
   teammate gets the base with neither append (`claude:tui-team`); a `--bg` main
   gets the main append (`claude:bg-sysprompt`).
2. Only the Remote Control bridge sets the carrier
   (`CLAUDE_CODE_BRIDGE_PROMPT_SHA256`), from the server's session config (A). A
   matching digest keeps the file, a missing or mismatched one drops it, and
   carrier + inline append is rc 1 (V; `claude:carrier-cli`). A wrapper's append
   file never reaches that spawned child. The headless SDK-host lane instead
   appends the server text after the host's append (A).
3. With `--agent`: custom prompt wins, agent body dropped (V).
4. K4 isolated-context call: suppressed (Vr; `codex:prompt-functions`). The
   interactive REPL never passes the flag to children, with or without the env
   gate (V; `claude:tui-subagent`).
5. Silently dropped without `CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT=1` (V).
6. Empty main `--agent` body falls back to base (V); empty sub-agent body gives
   tail only (V). Agent-file `appendSystemPrompt` is not parsed, so no base +
   body (I). Built-in `--agent claude`: code base + body (V), capture base (I).
7. Cache (V; `claude:cache-layout`, `claude:cache-layout-1p`): every append form
   lands at the end of the last system block, the last system breakpoint. In the
   first-party layout the `scope: global` block is byte-identical with or
   without an append. Any append switches the `-p`/SDK identity line, which sits
   before that block. With `CLAUDE_CODE_REMOTE` and the first-party layout,
   `CLAUDE_CODE_APPEND_PROMPT_HEAD=v1:<len>:<sha256>` moves a verified head of
   the append into the global block; without the designator or without
   `CLAUDE_CODE_REMOTE` both stay in the last block (V; `claude:append-head`).
8. Python Agent SDK 0.2.163: default options send `--system-prompt ""` on argv
   (base dropped, wrapper append file kept); `initialize` never carries prompt
   fields (V; `claude:sdk-py`). claude-agent-acp 0.84.0: default sends no prompt
   field; `_meta.systemPrompt.append` becomes `initialize.appendSystemPrompt`
   and **drops** a wrapper's append file; a string replaces the base and keeps
   the file (V; `claude:acp-adapter`). TS Agent SDK 0.3.284 direct: default
   `initialize.systemPrompt:[""]`, same append/string behavior (V;
   `claude:sdk-ts`).

### Codex

| Channel                                                   | Effect                                                                   | Twice                                                   | Reaches                                                                                                      | Mark  |
| --------------------------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ----- |
| `developer_instructions` (config, `-c`, profile, project) | Adds dev message beside base                                             | Highest layer wins, no concat                           | K1–K6 unless RPC/role override, review, local and remote compaction¹                                         | V     |
| `features.multi_agent_v2.subagent_developer_instructions` | **Replaces** inherited extra in children                                 | Last wins                                               | K4, K6, K5 without own text; not root                                                                        | V     |
| Role `developer_instructions`                             | Beside parent base; replaces parent extra in child²                      | One per role                                            | That role's children                                                                                         | V     |
| `model_instructions_file` / `instructions`                | Replaces base (`instructions` empty clears it)                           | Last wins; file beats `instructions`; empty file errors | K1–K6; not review, Guardian, memory, Realtime                                                                | V     |
| app-server `baseInstructions` / `developerInstructions`   | Replaces base / **replaces** config extra³                               | Duplicate JSON key: last wins                           | K3 thread + children; a role with own text replaces the dev text, base kept (`codex:P4.rpc-dev`)             | V     |
| app-server `turn/start` `additionalContext`               | Adds dev msg (`application`) or user msg (`untrusted`)                   | Per-key map                                             | K3, that turn                                                                                                | V     |
| app-server `thread/inject_items`                          | Adds dev msg; system-role item accepted, dropped                         | Appends each                                            | K3 thread                                                                                                    | V     |
| Requirements `additional_developer_instructions`          | Adds its own `<managed_developer_instructions>` dev msg (~10k token cap) | One managed value                                       | Root, V1 and V2 children (once each); not Guardian (`codex:P1.req-adi`, `codex:P1.req-adi-v1`); side turns A | V; A  |
| Command hook `additionalContext`                          | Adds dev msg                                                             | Accumulates                                             | Session whose hook fired; root context reaches `fork_turns=all` children only⁴ (`codex:P1.req-adi`)          | V     |
| MCP hook `additionalContext`                              | Adds dev msg                                                             | Accumulates                                             | Root only; `fork_turns=all` children inherit its copies; V2 children's MCP hooks fail⁵                       | V     |
| AGENTS.md (global, then root→cwd)                         | Adds user msg                                                            | `AGENTS.override.md` replaces per dir; dirs concatenate | K1–K6, review, Guardian (`codex:P2.guardian`); skipped if project untrusted                                  | V / I |
| `compact_prompt` / `experimental_compact_prompt_file`     | Replaces summarize prompt (user msg)                                     | Last wins                                               | Local compaction only; not remote V2 (`codex:P5.compact-v2`)                                                 | V     |
| `root_agent_usage_hint_text` / `subagent_usage_hint_text` | Replaces `<multi_agent_role>` block                                      | Last wins                                               | Root (V) / children (I)                                                                                      | V / I |
| collaborationMode `settings.developer_instructions`       | Replaces mode block                                                      | Last wins                                               | Thread in that mode                                                                                          | I     |
| `include_*_instructions` toggles                          | Remove a block                                                           | Last wins                                               | Root                                                                                                         | V     |
| TUI `terminal_visualization_instructions` feature         | Appends to the extra string                                              | —                                                       | K1 main thread only; not title or recap (`codex:T1`)                                                         | V     |

1. Side turns (V): TUI title and `/recap` threads re-read `config.toml` and
   carry the extra, with no skills block (`codex:T1`); memory Phase 2
   consolidation carries it, Phase 1 extraction does not (`codex:M1`); Guardian
   (`auto_review`) carries no extra, managed text or hook context
   (`codex:P2.guardian`); the live catalog's template equals the bundled one and
   has no `extra_policy` slot, so `[auto_review] extra_policy` is dropped unless
   `guardian_policy_template` is set (V LIVE; `codex:L3.live-guardian`).
   Realtime (`thread/realtime/start`, websocket): one `session.update` carries
   the Realtime prompt and a `<startup_context>` (latest turns, recent work, a
   two-level `$HOME` tree), with no extra and no AGENTS.md (V;
   `codex:P6.realtime`); WebRTC not probed. A running thread keeps its extra
   after a `config.toml` edit; new threads read the edit (V; `codex:T1`). K6
   user role named `default` with fork none/N: role text replaces it (I).
2. Declared role with the key omitted inherits extra (V). Discovered role with
   the key missing is skipped (I). Blank role text is a load error (I). Role
   base-replacement keys are dropped; parent base remains (I). A role
   `personality` switch into or out of `none` re-renders the catalog base (V;
   `codex:P3.personality`), only when the base came from the model (A).
3. Set by `thread/start` `developerInstructions` (V). Resume of an
   already-loaded thread keeps the original; new overrides are ignored (V).
4. SubagentStart context lands in the child only; a child's own PostToolUse
   context in that child; UserPromptSubmit does not fire in V2 children (task
   arrives as an agent message) but does in V1 children (V; `codex:P1.req-adi`,
   `codex:P1.req-adi-v1`).
5. `type = "mcp_tool"` hooks (app-server): root SessionStart, UserPromptSubmit
   and PostToolUse context each lands as its own developer message. In V2
   children every MCP hook, SubagentStart included, fails with "MCP server … is
   not connected", so a child gets only what it inherits (V;
   `codex:P1.mcp-hook`).

TUI wire parity (V; `codex:T1`): with the same config, the TUI's first request
carries the same prompt messages as app-server and `exec`. It differs only in
`service_tier: "priority"`, and on the shared daemon in a longer code-mode tool
description (MCP resource declarations).

### Kiro

This map describes v3/KAS, selected by this configuration. The v2 engine (not
used by this config) remains covered by the replay cases. Launchers: headless
`chat --v3 --no-interactive`, ACP `acp --agent-engine v3`; a cell names one when
they differ.

| Channel                                                         | Effect                                                                                                                                                      | Twice                                                                                                          | Reaches                                                                                                                 | Mark |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ---- |
| Global steering `~/.kiro/steering/*.md`                         | Adds user text before base or agent body                                                                                                                    | Combined with workspace and inline rules; every copy kept¹                                                     | Main, invoke children, orchestrate stages, workflow steps (`w-v3`, `pr-*`)                                              | V    |
| Workspace steering `.kiro/steering/*.md`; root `AGENTS.md`      | Adds before base                                                                                                                                            | Combined with global and inline rules                                                                          | Main, invoke children, orchestrate stages, workflow steps (`w-v3`, `pr-*`)                                              | V    |
| `fileMatch` steering; nested `<dir>/AGENTS.md`                  | Joins the user message carrying a matching `read_file` result; stays in history                                                                             | —                                                                                                              | Main, both launchers (`mx-hl-steer`, `mx-acp-steer`)                                                                    | V    |
| `manual` steering                                               | A prompt starting `/<name>` injects it into that turn's message only                                                                                        | —                                                                                                              | Main, both launchers (`mx-hl-manual`, `mx-acp-steer`)                                                                   | V    |
| `auto` steering                                                 | Name and description in `disclose_context`; content only as its tool result                                                                                 | —                                                                                                              | Main (`mx-hl-steer`)                                                                                                    | V    |
| ACP `_meta.kiro.steering[]`                                     | Adds after file steering, before body; `manual`/`fileMatch` entries listed, never injected                                                                  | Same name across global/workspace/inline retained                                                              | ACP main, invoke children, orchestrate stages; **not** workflow steps (`k3-dup`, `pr-acp-orch`, `pr-acp-wf`)            | V    |
| Agent `prompt`, ACP `customAgents`                              | Replaces base; appended text follows the body                                                                                                               | Workspace beats global; `customAgents` beat both; user `vibe` never wins; `kiro_default` is an ordinary agent² | Main, invoke children, orchestrate stages, workflow steps; not the agent's own children (`pr-hl-named`, `pr-acp-named`) | V    |
| Agent `resources`                                               | `<steering-files>` block after the main agent's body                                                                                                        | —                                                                                                              | Main and every invoke child; a child agent's own resources not loaded (`mx-res`)                                        | V    |
| `invoke_sub_agent` `inlineAgent.systemPrompt`                   | Replaces body when inline agents enabled; only an ACP host can enable them³                                                                                 | —                                                                                                              | Invoke child (`claude:k-pins`, `codex:R3`); disabled gate leaves agent not found (`mx-hl-inline`)                       | V; A |
| `agentSpawn` hook stdout                                        | `[Session Start Hook Output]` at the `history[0]` tail                                                                                                      | —                                                                                                              | Main (ACP only with `_meta.kiro.hooks` enabled), workflow steps; never invoke/orchestrate children (`pr-*`)             | V    |
| `userPromptSubmit` hook stdout                                  | Exit 0: `<HOOK_INSTRUCTION>` after `<EnvironmentContext>` in the current message; exit 1/2: `Output:… Exit Code: N`, turn not blocked⁴                      | Every prompt                                                                                                   | Main, workflow steps; not children (`mx-ups`, `pr-acp-hooked`)                                                          | V    |
| Output style (`concise`; ACP prompt `_meta`, cli.json)          | Fixed instruction appended to that main turn's message; ids `default`/`concise` only                                                                        | Per prompt; not re-sent                                                                                        | Main only (`mx-host`, `mx-hl-style`)                                                                                    | V    |
| Mode (`modeId` spec / quick-spec / bug-fix / plan / autonomous) | spec family: classifier turn, then steering + base + mode text; plan replaces base, file steering moves to the current message; autonomous has its own base | —                                                                                                              | ACP main (`mx-modes`)                                                                                                   | V    |
| Workflow step agent (incl. built-in `wf-*`)                     | Body replaces base after file steering; step trailer; `<original_user_request>` in the current message                                                      | —                                                                                                              | Workflow steps; ACP `customAgents` rejected as step agents (`pr-hl-wf`, `pr-acp-wf`, `mx-wfagents`)                     | V    |
| Agent `preset`; prompt schema and dispatch                      | Selected preset replaces body                                                                                                                               | —                                                                                                              | Invoke dispatch (`codex:R6`)                                                                                            | A    |
| `README.md`, `CLAUDE.md`                                        | Never auto-included; only as agent resources                                                                                                                | —                                                                                                              | — (`mx-hl-steer`)                                                                                                       | V    |
| `systemPrompt` / `appendSystemPrompt` host fields               | Reach no request (initialize, session/new, session/prompt `_meta`)                                                                                          | —                                                                                                              | — (`mx-host`)                                                                                                           | V    |

1. The client sends no cache fields; steering sits at byte 0 of `history[0]` and
   duplicates are all kept (`pr-hl-dup*`). Children share the parent's steering
   prefix (1700 bytes headless, 2139 ACP); steps share 1700.
2. `pr-hl-collide`, `pr-acp-collide`, `pr-vibe*`, `pr-kdefault*`.
3. `clientCapabilities._meta.kiro.settings.inlineAgents` (A); headless cli.json
   and rollout env cannot (V; `mx-hl-inline`).
4. Agent-profile hooks; stdout wins over stderr (V). Workspace v2 hook registry
   block path: A.

Lifecycle (V): title turns carry a fixed template and no channel; compaction
keeps `history[0]` (headless byte-identical; the ACP summary request appends the
prior turn to it) and the next turn re-sends it unchanged (`pr-hl-compact*`,
`pr-acp-compact`). Resume (ACP `session/load`, headless `--resume`) replays the
persisted `history[0]`; steering, agent and inline edits made since do not reach
it (`mx-resume`). Workflow pause→resume keeps the step's snapshot; the next step
renders steering fresh (`mx-wf-snap`).

Workspace trust: an ACP session lists no `kiro-scope:untrusted-execution` rule,
and `shell` gets the default `ask` (V; `mx-trust`). Both KAS server constructors
(stdio `acp` and `serve`) pass `workspaceTrusted:!0`, so LSP and workspace
`.kiro/settings/mcp.json` are always on (A; `kas-trust`).

The account flag `system_field_injection` moves steering and base into a
top-level `systemPrompt` on main requests; invoke children stay user-role (V
client; `mx-sysfield`). The flag was off for the one probed account (V LIVE); a
server-side prompt exists (model-reported, not wire). Other accounts' values and
that prompt's text are U; see [Open UNKNOWNs](evidence.md#open-unknowns).

### Kimchi

Order of the main system message (V; `claude:sp-p01-print-all`): rebuilt Kimchi
base (`## Environment`, `## Project Guidelines`) → CLI append (or
`APPEND_SYSTEM.md`) → ACP `_meta` (ACP then adds a skill list) → SessionStart
hook text → memory. `before_provider_request` edits come last, on the wire only.
Launchers: `-p`, `--mode rpc`, `--mode acp`; a cell names one when they differ.

| Channel                                                  | Effect                                                                                       | Twice                                              | Reaches                                                                                                                    | Mark |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ---- |
| `--append-system-prompt TEXT\|PATH`                      | Adds at the tail; an existing file path is read; suppresses `APPEND_SYSTEM.md`               | Both kept, argv order                              | Main (`-p`, RPC, ACP), in-session step, append children; not replace/built-in, background step, K8                         | V    |
| `APPEND_SYSTEM.md`                                       | Adds at the tail; user `~/.config/kimchi/harness/`, project `<proj>/.config/kimchi/harness/` | One file: project shadows user when trusted        | Main `-p`/RPC; background steps; **never ACP** (`claude:sp-p05-acp-no-meta`–`claude:sp-p08-append-file-project-untrusted`) | V    |
| `SYSTEM.md` / `--system-prompt`                          | Silently dropped                                                                             | —                                                  | —                                                                                                                          | V    |
| ACP `_meta["kimchi.dev"].appendSystemPrompt`             | Adds after the CLI flag, per `session/new`; suppresses the file                              | —                                                  | ACP main, append children                                                                                                  | V    |
| AGENTS.md / CLAUDE.md (+ `.local`)                       | `## Project Guidelines` in the base: global AGENTS, then project root→cwd; not trust-gated   | Per dir AGENTS wins over CLAUDE; `.local` appended | Main; built-in children with context files get project files only; append children all                                     | V    |
| SessionStart hook (systemPrompt delivery)                | Adds after CLI and `_meta`; needs project trust; one-shot, back after compaction             | Joined with a blank line (A)                       | Main; append children spawned while present; background steps only with persisted trust                                    | V    |
| Claude-Code hooks, `systemMessage`, prompt-summary notes | User messages, never system; adapter off by default; summaries only in compaction input      | —                                                  | Main (`claude:sp-p16-rpc-claude-hooks`)                                                                                    | V; A |
| Extension `before_agent_start`                           | Main: discarded (rebuild runs after it); children: appended at the tail                      | Chained in load order (A)                          | Non-isolated children (`claude:sp-p01-print-all`)                                                                          | V    |
| Extension `before_provider_request`                      | Edits the final payload                                                                      | Chained in load order (A)                          | Main, non-isolated children, both step kinds; not title, compaction, memory helper                                         | V    |
| System-prompt blocks                                     | Internal only (todos, dap, behaviors); extensions cannot register                            | —                                                  | Main rebuilt prompt                                                                                                        | V    |
| Memory digest                                            | Off by default; digest + `## Memory` notice after hook text, every turn                      | —                                                  | Main, append children; not replace children (`claude:sp-p17-rpc-memory-turns`)                                             | V    |
| Agent `.md` body + `prompt_mode`                         | `replace` (default): header + env + tools + body; `append`: parent's final prompt + body     | —                                                  | That child; project agents need trust, else General-Purpose fallback (`claude:sp-p03b-acp-untrusted-agents`)               | V    |

K8 helpers (V): title uses a fixed 341-char `system` on `deepseek-v4-flash-0731`
(the real gateway answers that request 404; V LIVE, `claude:l2-live-effort-ab`);
compaction a fixed 310-char system on the session model; the memory capture
helper its own system on `deepseek-v4-flash-0731`. No channel reaches them.
Background workflow steps re-exec `process.execPath` (the ELF): a Nix wrapper's
body does not run again, its exported env is inherited
(`claude:sp-p19-wrapper-execpath`). Remote-Runner workers get the task as a user
prompt and no client system text (A); their server-side system is U.

## Replay

Scripts: `packages/delegate-routing/probes/delegates/<harness>/`.

| Harness | Case ids                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Claude  | `codex:P` (K1–K8); `p3-agent-named` (custom prompt wins); `snap1`, `snap2`, `snap3` (resume snapshot); `claude:cache-layout`, `claude:cache-layout-1p`, `claude:order-files`, `claude:carrier-cli`, `claude:sdk-py`, `claude:sdk-ts`, `claude:acp-adapter`, `claude:policy-helper`, `claude:append-head`, `claude:census-*`, `claude:gated-*`, `claude:tui-subagent`, `claude:tui-team`, `claude:bg-sysprompt` |
| Codex   | `codex:R4` (base), `claude:R10` (extra / child); `wireB` (`subagent_developer_instructions`), `piD6` (unknown trust); `codex:P1.req-adi`, `codex:P1.req-adi-v1`, `codex:P1.mcp-hook`, `codex:P2.guardian`, `codex:P3.personality`, `codex:P4.rpc-dev`, `codex:P5.compact-v2`, `codex:P6.realtime`, `codex:M1`, `codex:T1`; LIVE `codex:L3.live-guardian`                                                       |
| Kiro    | `codex:R8`; `w-v3`, `k3-dup`, `k3-hooked`, `a3-invoke`; `pr-*` (reach, collisions, compaction, cache); `mx-*` (steering modes, host fields, resources, hooks, modes, resume, `system_field_injection`)                                                                                                                                                                                                         |
| Kimchi  | `claude:sp-*` (LIVE `claude:sp-p20-live-wire` needs `--live`)                                                                                                                                                                                                                                                                                                                                                  |

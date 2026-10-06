# System prompt per delegate kind

What each delegate kind gets as its system prompt, how an agent's own prompt
relates to the vendor base, which channels add extra text, and what one
normalized option can promise.

Pins, marks and capture methods: [evidence.md](evidence.md).

**Kinds:** K1 main interactive · K2 headless · K3 protocol (SDK / app-server /
ACP) · K4 built-in sub-agents · K5 named sub-agents · K6 ephemeral sub-agents ·
K7 workflows · K8 other model turns (compaction, title, hooks, helpers).

## What "append" means

| Harness | Where extra text lands                                        | Wire role                                               | Reaches sub-agents?                      |
| ------- | ------------------------------------------------------------- | ------------------------------------------------------- | ---------------------------------------- |
| Claude  | Tail of `system[2]` (main); separate hidden flag for children | system                                                  | Fork: main append. Others: child channel |
| Codex   | `developer_instructions`: a developer message beside the base | developer (lite models have no system slot)             | Inherited unless replaced                |
| Kiro    | Always-on steering file, placed **before** base/agent prompt  | user (`history[0]`); system only if account flag on (U) | Yes for most kinds                       |
| Kimchi  | `--append-system-prompt`: tail of Kimchi's rebuilt prompt     | system (provider-wire serialization U)                  | Default replace mode: no                 |

## Defaults per kind

Cell = vendor base · extra text reaches? · mark. Channel: Claude K1–K3/K8 main
append, K4–K7 sub-agent append; Codex `developer_instructions`; Kiro steering;
Kimchi `--append-system-prompt`.

| Kind | Claude                                                    | Codex                                                 | Kiro                                                  | Kimchi                                              |
| ---- | --------------------------------------------------------- | ----------------------------------------------------- | ----------------------------------------------------- | --------------------------------------------------- |
| K1   | Base (27.6k) · Yes · V                                    | Catalog base · Yes · V rollout, I wire                | None; 231-byte `kiro_default` (v2) · Yes · V; I (TUI) | Main base · Yes, tail · V                           |
| K2   | Base, "Agent SDK" identity · Yes · V                      | Catalog base · Yes · V                                | As K1 v2 · Yes · V                                    | Main base, autonomous variant · Yes · V             |
| K3   | Base · Yes if host sends no prompt field · V              | Catalog base · Yes if no RPC dev text · V             | As v2 · steering file only; `_meta` ignored · V       | Main base · Yes, inline text only · V               |
| K4   | None; own body + tail · sub-agent append Yes, main No · V | Parent's base · Yes, inherited · V/I                  | None (v2 crew) · Yes · V                              | Child wrapper; persona replaces · **No** · V        |
| K5   | None; body replaces · sub-agent append Yes · V            | Parent base + role text · **No** if role has text · V | KAS: body replaces · Yes · V                          | Child wrapper; body replaces · **No** · V           |
| K6   | None; general-purpose body · sub-agent append Yes · V     | Parent's base · Yes, inherited once · V               | v2: N/A (`role` required) · V                         | Selected persona · follows persona · V              |
| K7   | None; `workflow-subagent` body · sub-agent append Yes · V | No workflow kind; K4–K6 rules · I                     | KAS only, gated; per K4/K5 · Yes · V                  | In-session: main base · persistent channels Yes · V |
| K8   | Compaction: parent system · Yes (copied) · V              | Local compaction: session base · Yes · V              | KAS compaction: kept · Yes · V                        | Fixed summarizer · **No** · V                       |

Title reach: Claude No (V); Codex config Yes, RPC overrides No (I); Kiro No (V);
Kimchi No (V).

### Breaks when

| Harness | Kind  | Condition                                                                          | Result                                       | Mark             |
| ------- | ----- | ---------------------------------------------------------------------------------- | -------------------------------------------- | ---------------- |
| Claude  | K1/K2 | `--resume`, snapshot on (default)                                                  | **No**: first session's text re-sent         | V                |
| Claude  | K1/K2 | `--resume --system-prompt-snapshot off`                                            | Yes                                          | V                |
| Claude  | K1    | Bridge carrier, `CLAUDE_CODE_BRIDGE_PROMPT_SHA256` missing/mismatch                | **No**: append file dropped                  | Vr               |
| Claude  | K1    | Internal `overrideSystemPrompt`                                                    | **No**: override drops append                | I                |
| Claude  | K3    | Host sends `initialize.appendSystemPrompt`                                         | **No**: host value replaces CLI append       | V                |
| Claude  | K3    | `appendSubagentSystemPrompt` without `CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT=1` | **No**: silently dropped                     | V                |
| Claude  | K4    | Parent has main append only                                                        | No                                           | V                |
| Claude  | K4    | Isolated-context call                                                              | No (suppressed)                              | Vr               |
| Claude  | K6    | `fork` (`CLAUDE_CODE_FORK_SUBAGENT=1`)                                             | Parent system copied: main Yes, sub-agent No | V                |
| Claude  | K8    | Hook `type:"prompt"` / `type:"agent"`                                              | No                                           | V                |
| Claude  | K8    | Compaction fallback                                                                | No                                           | I                |
| Codex   | K2    | Set in several config layers                                                       | Only the top layer's                         | V                |
| Codex   | K3    | `thread/start` with `developerInstructions`                                        | **No**: RPC value replaces config            | V                |
| Codex   | K3    | Resume of an already-loaded thread                                                 | Original only; new overrides ignored         | V                |
| Codex   | K4–K6 | `subagent_developer_instructions` set                                              | **No**: replaced in children                 | V                |
| Codex   | K6    | User role named `default`, fork none/N                                             | **No**: role text replaces                   | I                |
| Codex   | K8    | Memory extraction, Guardian, Realtime                                              | No                                           | I                |
| Kiro    | K1    | v3 resumed session                                                                 | Old snapshot only                            | V                |
| Kiro    | K1    | v3 untrusted workspace                                                             | Global steering only                         | V                |
| Kiro    | K2    | v2 `--agent X` headless                                                            | Steering yes; X's agentSpawn hook skipped    | V                |
| Kiro    | K3    | v3 `_meta[.kiro].systemPrompt` / `appendSystemPrompt`                              | No (ignored)                                 | V                |
| Kiro    | K4    | KAS `dispatchKind:"spec"`                                                          | Steering dropped                             | V; U full prompt |
| Kiro    | K6    | KAS `inlineAgent`, feature off (default)                                           | N/A: agent not found                         | V                |
| Kiro    | K7    | Resumed step                                                                       | Old prompt only                              | V                |
| Kiro    | K8    | v2 `/compact` checkpoint                                                           | No                                           | V                |
| Kiro    | K8    | KAS truncation / recap                                                             | No                                           | V                |
| Kiro    | K8    | KAS title                                                                          | No                                           | V                |
| Kimchi  | K1–K3 | `APPEND_SYSTEM.md` when any append flag is given                                   | File disabled                                | V                |
| Kimchi  | K3    | ACP `--append-system-prompt PATH`                                                  | Path string inserted literally               | V                |
| Kimchi  | K3    | ACP `APPEND_SYSTEM.md`                                                             | No                                           | V                |
| Kimchi  | K5    | `prompt_mode: append`                                                              | Yes, minus 4 stripped sections               | V                |
| Kimchi  | K7    | Background / isolated step                                                         | Files yes (I); parent flag/`_meta` no        | V argv / I       |
| Kimchi  | K7    | One-shot SessionStart hook text, in-session step                                   | Lost                                         | V                |

## Named prompt vs vendor base

| Harness | Situation                        | Prompt behavior                     | Mark |
| ------- | -------------------------------- | ----------------------------------- | ---- |
| Claude  | Main `--agent`                   | Replaces base; empty falls back     | V    |
| Claude  | Sub-agent body / JSON `prompt`   | Replaces base; harness tail follows | V    |
| Claude  | Empty sub-agent body             | Tail only                           | V    |
| Claude  | Agent-file `appendSystemPrompt`  | Not parsed; no base + body          | I    |
| Claude  | Built-in `--agent claude`        | Code: base + body; capture: base    | V/I  |
| Claude  | `--system-prompt` with `--agent` | Custom wins; agent body dropped     | V    |
| Codex   | Role developer text              | Beside parent base; replaces extra  | V    |
| Codex   | Declared role, key omitted       | Inherits extra                      | V    |
| Codex   | Discovered role, key missing     | Skipped                             | I    |
| Codex   | Blank role text                  | Load error                          | I    |
| Codex   | Role base-replacement keys       | Dropped; parent base remains        | I    |
| Kiro    | Non-empty agent `prompt`         | Replaces base                       | V    |
| Kiro    | Empty/missing v2 prompt          | No instruction                      | V    |
| Kiro    | Empty/missing v3 main prompt     | No base                             | V    |
| Kiro    | Empty/missing KAS child prompt   | Vendor fallback                     | V    |
| Kiro    | Empty/missing workflow prompt    | No base                             | V    |
| Kiro    | Empty/missing v2 crew prompt     | Preamble also lost                  | V    |
| Kiro    | v1 empty prompt                  | Rejected; `kiro_default`            | V    |
| Kimchi  | Replace mode (default)           | Body replaces; wrapper kept         | V    |
| Kimchi  | Empty replace body               | Wrapper only                        | V    |
| Kimchi  | Append mode                      | Parent prompt + agent body          | V    |
| Kimchi  | Append with empty parent         | `genericBase` fallback              | V    |

Replace channels: Claude `--system-prompt[-file]` (identity line kept) V · Codex
`model_instructions_file` / `instructions` / RPC `baseInstructions` V · Kiro
agent `prompt`, `preset`, `inlineAgent.systemPrompt` V · Kimchi
`--system-prompt` / `SYSTEM.md` have **no effect** V.

## Append channels

"Twice" = the channel set twice or in two layers.

### Claude

| Channel                                                          | Adds / replaces                         | Twice                                      | Reaches                                                        | Mark   |
| ---------------------------------------------------------------- | --------------------------------------- | ------------------------------------------ | -------------------------------------------------------------- | ------ |
| `--append-system-prompt`                                         | Adds, tail of `system[2]`               | Last wins; + file = combine, file first    | K1–K3 (unless host append), K6 fork, K8 compaction             | V      |
| Main append: other forks                                         | Copied parent system                    | —                                          | Suggestions, memory, plugin `model.fork`                       | I      |
| `--append-system-prompt-file` (hidden)                           | Adds; file first, then inline           | Last wins                                  | Same; dropped on bridge-hash mismatch                          | V / Vr |
| `--system-prompt[-file]`                                         | Replaces body; append still follows     | Last wins; file + inline combine           | K1–K3 main                                                     | V      |
| `--append-subagent-system-prompt[-file]` (hidden, `-p`)          | Adds after child tail                   | Last wins; inline + file = **error, rc 1** | K4, K5, K6 non-fork, K7, nested. Not main, not fork            | V      |
| SDK `initialize.appendSystemPrompt`                              | Adds; **replaces** CLI append           | —                                          | K3 main                                                        | V      |
| SDK `initialize.systemPrompt`                                    | Replaces body and CLI `--system-prompt` | —                                          | K3 main                                                        | V      |
| SDK `initialize.appendSubagentSystemPrompt`                      | Adds, only with env gate                | —                                          | K3 children                                                    | V      |
| SDK repeated `initialize`                                        | Prompt slots unchanged                  | First initialization retained              | K3                                                             | I      |
| Agent body / JSON `prompt`                                       | Replaces base                           | —                                          | K1 `--agent`, K5, K7 `agentType`                               | V      |
| Managed `policyHelper.appendSystemPrompt`                        | Adds after CLI append                   | U                                          | K1/K2                                                          | I      |
| CLAUDE.md, rules, output style, skills, hook `additionalContext` | **User message**, not system            | Combine                                    | Main + children (Explore/Plan drop CLAUDE.md). Not hooks/title | V / I  |

### Codex

| Channel                                                   | Adds / replaces                                        | Twice                                                   | Reaches                                                | Mark  |
| --------------------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------- | ------------------------------------------------------ | ----- |
| `developer_instructions` (config, `-c`, profile, project) | Adds dev message beside base                           | Highest layer wins, no concat                           | K1–K6 (no RPC/role override), review, local compaction | V     |
| Config extra: side turns                                  | Config inherited                                       | —                                                       | Consolidation, title/recap; not RPC overrides          | I     |
| `features.multi_agent_v2.subagent_developer_instructions` | Replaces inherited extra in children                   | Last wins                                               | K4, K6, K5 without own text. Not root                  | V     |
| Role `developer_instructions`                             | Replaces parent extra in that child                    | One per role                                            | That role's children                                   | V     |
| `model_instructions_file` / `instructions`                | Replaces base (`instructions` empty clears it)         | Last wins; file beats `instructions`; empty file errors | K1–K6. Not review, Guardian, memory, Realtime          | V     |
| app-server `baseInstructions`                             | Replaces base                                          | Duplicate JSON key: last wins                           | K3 thread (+ children I)                               | V     |
| app-server `developerInstructions`                        | Replaces config extra                                  | Duplicate JSON key: last wins                           | K3 thread (+ children I)                               | V     |
| app-server `turn/start` `additionalContext`               | Adds dev msg (`application`) or user msg (`untrusted`) | Per-key map                                             | K3, that turn                                          | V     |
| app-server `thread/inject_items`                          | Adds dev msg; system-role item accepted, dropped       | Appends each                                            | K3 thread                                              | V     |
| Requirements `additional_developer_instructions`          | Adds separate managed dev msg (~10k token cap)         | One managed value                                       | All non-Guardian sessions (I); children U              | I / U |
| Command/MCP hook `additionalContext`                      | Adds dev msg                                           | Accumulates                                             | Session whose hook fired                               | I     |
| AGENTS.md (global, then root→cwd)                         | Adds user msg                                          | `AGENTS.override.md` replaces per dir; dirs concatenate | K1–K6, review; skipped if project untrusted            | V / I |
| `compact_prompt` / `experimental_compact_prompt_file`     | Replaces summarize prompt (user msg)                   | Last wins                                               | Local compaction only                                  | V     |
| `root_agent_usage_hint_text` / `subagent_usage_hint_text` | Replaces `<multi_agent_role>` block                    | Last wins                                               | Root (V) / children (I)                                | V / I |
| collaborationMode `settings.developer_instructions`       | Replaces mode block                                    | Last wins                                               | Thread in that mode                                    | I     |
| `include_*_instructions` toggles                          | Remove a block                                         | Last wins                                               | Root                                                   | V     |
| TUI `terminal_visualization_instructions` feature         | Appends to the extra string                            | —                                                       | K1 only                                                | I     |

### Kiro

| Channel                                                           | Adds / replaces                       | Twice                                                      | Reaches                                                                              | Mark |
| ----------------------------------------------------------------- | ------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------ | ---- |
| Global steering `~/.kiro/steering/*.md` (always / no frontmatter) | Adds, user role, before base          | Combine; same name across global/workspace/inline all kept | K1–K3, all engines                                                                   | V    |
| Global steering: reach                                            | —                                     | —                                                          | KAS K4–K7 children                                                                   | V    |
| Global steering: reach                                            | —                                     | —                                                          | v2 crew                                                                              | V    |
| Global steering: reach                                            | —                                     | —                                                          | v1 subagent                                                                          | V    |
| Global steering: reach                                            | —                                     | —                                                          | KAS normal compaction                                                                | V    |
| Global steering: reach                                            | —                                     | —                                                          | Not v2 checkpoint                                                                    | V    |
| Global steering: reach                                            | —                                     | —                                                          | Not KAS truncation                                                                   | V    |
| Global steering: reach                                            | —                                     | —                                                          | Not title                                                                            | V    |
| Workspace steering `.kiro/steering/*.md`                          | Adds                                  | Combine                                                    | As global; dropped in untrusted workspace (KAS)                                      | V    |
| Root `AGENTS.md` (nested = fileMatch only)                        | Adds                                  | —                                                          | As workspace steering                                                                | V    |
| `README.md`                                                       | Adds                                  | —                                                          | v1/v2 every agent; KAS only via `resources`                                          | V    |
| Agent `resources.files`                                           | Adds                                  | Same doc id: later wins                                    | KAS main (not KAS children); v1/v2 agents                                            | V    |
| ACP `_meta.kiro.steering[]`                                       | Adds after file steering, before base | Same name in one batch: first kept                         | K3 v3 main + `invoke_sub_agent` children. v2 ignores; TUI/chat never send it         | V    |
| Agent `prompt` (JSON / MD / `file://` / ACP `customAgents`)       | **Replaces** base                     | Profile id collision: later wins; ACP batch: first wins    | Selected agent, K1–K5, K7 steps                                                      | V    |
| `invoke_sub_agent` `preset`                                       | Replaces                              | —                                                          | KAS K4/K5 children                                                                   | V    |
| `inlineAgent.systemPrompt`                                        | Replaces                              | —                                                          | KAS K6 (gated)                                                                       | V    |
| `agentSpawn` / SessionStart hook stdout                           | Adds, `history[0]` after base         | Combine per hook                                           | Main K1–K3 (v2: not with headless `--agent`), v2 crew, v1 subagent. Not KAS children | V    |
| `userPromptSubmit` stdout                                         | Adds to each user turn                | Combine                                                    | As agentSpawn                                                                        | V    |
| Output style                                                      | Adds user text                        | —                                                          | KAS main                                                                             | V    |
| Workflow lifecycle text                                           | Adds (system + user)                  | —                                                          | K7 dedicated steps                                                                   | V    |
| `systemPrompt` / `appendSystemPrompt` (flag, setting, `_meta`)    | Does not exist / ignored              | —                                                          | None                                                                                 | V    |

### Kimchi

| Channel                                                  | Adds / replaces                  | Twice                                                   | Reaches                                                      | Mark  |
| -------------------------------------------------------- | -------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------ | ----- |
| `--append-system-prompt TEXT\|PATH`                      | Adds at tail                     | Combine in order; disables `APPEND_SYSTEM.md`           | K1, K2, K3 RPC, K3 ACP (text only), K5 append, K7 in-session | V     |
| `APPEND_SYSTEM.md` (global harness dir, trusted project) | Adds at tail                     | One file; project shadows global                        | K1, K2, K3 RPC, K5 append, K7 (background I). Not ACP        | V     |
| `SYSTEM.md` / `--system-prompt`                          | Replaces Pi base, then discarded | Last wins                                               | None                                                         | V     |
| ACP `_meta["kimchi.dev"].appendSystemPrompt`             | Adds after CLI entries           | One string per session; arrays ignored                  | K3 ACP (+ K5 append children I)                              | V     |
| AGENTS.md / CLAUDE.md (+ `.local`)                       | Adds in Project Guidelines       | Global + ancestors combine; per dir AGENTS beats CLAUDE | K1–K3, K5-append, K7                                         | V     |
| Instruction files: GP/Plan                               | Project-only                     | —                                                       | K4                                                           | V     |
| Instruction files: replace custom                        | Adds context                     | —                                                       | K5 with `include_context_files`                              | V     |
| SessionStart hook (systemPrompt delivery)                | Adds                             | Combine, no dedup                                       | First prompt after start/compaction only                     | I     |
| Claude-Code hooks, `systemMessage`, prompt-summary notes | User message                     | —                                                       | Not system                                                   | V     |
| Extension `before_agent_start`                           | Replaces (chained)               | Each sees previous                                      | Clobbered in K1–K3; K4/K5 child U                            | V / U |
| Extension `before_provider_request`                      | Rewrites payload                 | Chained                                                 | Main-loop requests                                           | V     |
| Payload extension: side turns                            | —                                | —                                                       | Not K8                                                       | I     |
| Child-loaded payload extension                           | Rewrites payload                 | Chained                                                 | Children loading the extension                               | I     |
| System-prompt blocks                                     | Adds builder section, sorted     | Same id replaces                                        | K1–K3; Kimchi-internal API                                   | I     |
| Memory digest                                            | Adds                             | Stable until compaction                                 | K1–K3                                                        | V     |
| Agent `.md` body + `prompt_mode`                         | Replace (default) / append       | Same name: later layer replaces whole                   | K5; K4 by name override; K6 by selection                     | V     |

## What one normalized option can promise

| Kind | Promise | Who fails                                                       | Consequence                                                                                         |
| ---- | ------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| K1   | **Yes** | None by default                                                 | Claude `--resume` re-sends old text: change needs a fresh session. Kiro text sits before the prompt |
| K2   | **Yes** | None                                                            | Codex keeps only the top layer: the option must own it                                              |
| K3   | Partial | Claude, Codex (host field overrides); Kiro v2 (`_meta` ignored) | CLI/file channel works only while the host sends nothing. Kimchi ACP needs inline text              |
| K4   | Partial | Kimchi                                                          | Claude needs the sub-agent channel; Codex reaches unless `subagent_developer_instructions` set      |
| K5   | Partial | Codex (role with own text), Kimchi (replace mode)               | Agent definition wins; reach depends on how each agent is written                                   |
| K6   | Partial | Kimchi (follows persona); Kiro v2 N/A                           | Claude non-fork via sub-agent channel, fork via main; Codex inherited                               |
| K7   | Partial | Kimchi background steps (flag not forwarded)                    | Claude, Kiro (gated) reach; Codex uses K4–K6 rules                                                  |
| K8   | **No**  | Most titles; Kimchi / Kiro v2 compaction                        | No universal guarantee; Codex config title/recap I; compaction reach above                          |

Holds across kinds:

- **Claude needs two channels.** Main append reaches fork children (V). Non-fork
  children need the sub-agent channel (V); that channel does not reach main (V).
- **Kiro text is never system-role** unless the account's
  `system_field_injection` flag is on (U).
- **"Keep the vendor base" cannot be promised.** Kiro v2 has none; Claude and
  Kiro agent prompts replace it; Kimchi children replace it.

Open questions and settling steps: [evidence.md](evidence.md#open-unknowns).

## Replay

Scripts live in `packages/delegate-routing/probes/delegates/<harness>/`.

| Harness | Case ids                                                                                                                                   |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Claude  | `codex:P` (K1–K7); `p3-agent-named` (custom prompt wins); `snap1`, `snap2`, `snap3` (resume snapshot)                                      |
| Codex   | `codex:R4` (base), `claude:R10` (extra / child); `wireB` (`subagent_developer_instructions`), `piD6` (unknown trust)                       |
| Kiro    | `codex:R8`; `w-v3` (steering before base), `k3-dup` (duplicate steering), `k3-hooked` (KAS agentSpawn), `a3-invoke` (no hooks in children) |
| Kimchi  | `codex:S`                                                                                                                                  |

# System prompt per delegate kind

What prompt each delegate kind gets, how an agent prompt relates to the vendor
base, which channels add text, and what one normalized option can promise. Pins,
marks and capture methods: [evidence.md](evidence.md).

**Kinds:** K1 main interactive · K2 headless · K3 protocol (SDK / app-server /
ACP) · K4 built-in sub-agents · K5 named sub-agents · K6 ephemeral sub-agents ·
K7 workflows · K8 other model turns (compaction, title, hooks, helpers).

## What "append" means

| Harness | Where extra text lands                                        | Wire role                                               | Reaches sub-agents?                      |
| ------- | ------------------------------------------------------------- | ------------------------------------------------------- | ---------------------------------------- |
| Claude  | Tail of `system[2]` (main); separate hidden flag for children | system                                                  | Fork: main append. Others: child channel |
| Codex   | `developer_instructions`: a developer message beside the base | developer (lite models have no system slot)             | Inherited unless replaced                |
| Kiro    | Always-on steering file, placed **before** base/agent prompt  | user (`history[0]`); system only if account flag on (U) | Invoke children (V); workflow steps U    |
| Kimchi  | not re-verified at 1.5.1 (U)                                  | not re-verified at 1.5.1 (U)                            | not re-verified at 1.5.1 (U)             |

## Defaults per kind

Cell = vendor base · extra text reaches? · mark. Channel: Claude K1–K3/K8 main
append, K4–K7 sub-agent append; others as above.

| Kind | Claude                                                    | Codex                                                 | Kiro                                                            | Kimchi                       |
| ---- | --------------------------------------------------------- | ----------------------------------------------------- | --------------------------------------------------------------- | ---------------------------- |
| K1   | Base (27.4k) · Yes · V                                    | Catalog base · Yes · V rollout, I wire                | KAS base · steering before base · A (TUI)                       | not re-verified at 1.5.1 · U |
| K2   | Base, "Agent SDK" identity · Yes · V                      | Catalog base · Yes · V                                | KAS base · steering before base · V (`w-v3`)                    | not re-verified at 1.5.1 · U |
| K3   | Base · Yes if host sends no prompt field · V              | Catalog base · Yes if no RPC dev text · V             | KAS base · file + inline steering · V (`k3-dup`)                | not re-verified at 1.5.1 · U |
| K4   | None; own body + tail · sub-agent append Yes, main No · V | Parent's base · Yes, inherited · V/I                  | Named built-in body · inherited steering · V; A (`codex:R3/R6`) | not re-verified at 1.5.1 · U |
| K5   | None; body replaces · sub-agent append Yes · V            | Parent base + role text · **No** if role has text · V | Body replaces · inherited steering · V (`a3-invoke`)            | not re-verified at 1.5.1 · U |
| K6   | None; general-purpose body · sub-agent append Yes · V     | Parent's base · Yes, inherited once · V               | Inline body replaces · inherited steering · V (`claude:k-pins`) | not re-verified at 1.5.1 · U |
| K7   | None; `workflow-subagent` body · sub-agent append Yes · V | No workflow kind; K4–K6 rules · I                     | Step body · steering reach not re-verified at 2.28.0 · U        | not re-verified at 1.5.1 · U |
| K8   | Compaction: parent system · Yes (copied) · V              | Local compaction: session base · Yes · V              | not re-verified at 2.28.0 · U                                   | not re-verified at 1.5.1 · U |

Title reach: Claude No (Vr; `codex:prompt-functions`); Codex config Yes, RPC
overrides No (I); Kiro not re-verified at 2.28.0 (U); Kimchi not re-verified at
1.5.1 (U). Exceptions are footnoted under each harness's channel table.

## What one normalized option can promise

| Kind | Promise | Who fails                                                                                       | Consequence                                                                                         |
| ---- | ------- | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| K1   | **Yes** | None by default                                                                                 | Claude `--resume` re-sends old text: change needs a fresh session. Kiro text sits before the prompt |
| K2   | **Yes** | None                                                                                            | Codex keeps only the top layer: the option must own it                                              |
| K3   | Partial | Claude, Codex (host field overrides); Kiro v2 engine (not used by this config): `_meta` reach U | CLI/file channel works only while the host sends nothing. Kimchi ACP prompt reach is U at 1.5.1     |
| K4   | Partial | Kimchi (not re-verified at 1.5.1; U)                                                            | Claude needs the sub-agent channel; Codex reaches unless `subagent_developer_instructions` set      |
| K5   | Partial | Codex (role with own text), Kimchi (not re-verified at 1.5.1; U)                                | Agent definition wins; reach depends on how each agent is written                                   |
| K6   | Partial | Kimchi (not re-verified at 1.5.1; U); Kiro v2 engine (not used by this config): N/A             | Claude non-fork via sub-agent channel, fork via main; Codex inherited                               |
| K7   | Partial | Kimchi background steps (V argv; `codex:W`)                                                     | Claude reaches; Kiro workflow steering not re-verified at 2.28.0 (U); Codex uses K4–K6 rules        |
| K8   | **No**  | Most titles; Kimchi / Kiro compaction (U)                                                       | No universal guarantee; Codex config title/recap I; compaction reach above                          |

- **Claude needs two channels.** Main append reaches fork children (V). Non-fork
  children need the sub-agent channel (V); it does not reach main (V).
- **Kiro text is never system-role** unless the account's
  `system_field_injection` flag is on (U).
- **"Keep the vendor base" cannot be promised.** Claude and Kiro agent prompts
  replace it; Kimchi prompt composition is U at 1.5.1.

Open questions and settling steps: [evidence.md](evidence.md#open-unknowns).

## Channels per harness

"Twice" = the channel set twice or in two layers.

### Claude

| Channel                                                          | Effect                                                                   | Twice                                        | Reaches                                                        | Mark  |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------ | -------------------------------------------- | -------------------------------------------------------------- | ----- |
| `--append-system-prompt`; hidden `-file`                         | Adds, tail of `system[2]`; file first, then inline                       | Last wins; file + inline combine, file first | K1–K3, K6 fork, K8 compaction¹ ²                               | V     |
| `--system-prompt[-file]`                                         | Replaces body, identity line kept; append too³                           | Last wins; file + inline combine             | K1–K3 main                                                     | V     |
| `--append-subagent-system-prompt[-file]` (hidden, `-p`)          | Adds after child tail                                                    | Last wins; inline + file = **error rc 1**    | K4, K5, K6 non-fork, K7, nested; not main or fork⁴             | V     |
| SDK `initialize.appendSystemPrompt` / `.systemPrompt`            | Adds, **replacing** CLI append / replaces body and CLI `--system-prompt` | —                                            | K3 main                                                        | V     |
| SDK `initialize.appendSubagentSystemPrompt`                      | Adds, only with env gate⁵                                                | —                                            | K3 children                                                    | V     |
| SDK repeated `initialize`                                        | Prompt slots unchanged                                                   | First initialization kept                    | K3                                                             | I     |
| Agent body / JSON `prompt`                                       | Replaces base; harness tail follows⁶                                     | —                                            | K1 `--agent`, K5, K7 `agentType`                               | V     |
| Managed `policyHelper.appendSystemPrompt`                        | Adds after CLI append                                                    | U                                            | K1/K2                                                          | I     |
| CLAUDE.md, rules, output style, skills, hook `additionalContext` | **User message**, not system                                             | Combine                                      | Main + children (Explore/Plan drop CLAUDE.md); not hooks/title | V / I |

1. Lost when: host sends `initialize.appendSystemPrompt` (V); K1/K2 `--resume`
   with snapshot on (default) re-sends the first session's text (V), fixed by
   `--system-prompt-snapshot off` (V); K1 internal `overrideSystemPrompt` (I);
   hook `type:"prompt"` / `type:"agent"` (V); compaction fallback (I). Also
   reaches suggestions, memory and plugin `model.fork` as a copied parent system
   (I). `fork` (`CLAUDE_CODE_FORK_SUBAGENT=1`) copies the parent system: main
   append yes, sub-agent append no (V).
2. K1 bridge carrier with `CLAUDE_CODE_BRIDGE_PROMPT_SHA256` missing or
   mismatched drops the file (Vr; `codex:prompt-functions`).
3. With `--agent`: custom prompt wins, agent body dropped (V).
4. K4 isolated-context call: suppressed (Vr; `codex:prompt-functions`).
5. Silently dropped without `CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT=1` (V).
6. Empty main `--agent` body falls back to base (V); empty sub-agent body gives
   tail only (V). Agent-file `appendSystemPrompt` is not parsed, so no base +
   body (I). Built-in `--agent claude`: code base + body (V), capture base (I).

### Codex

| Channel                                                   | Effect                                                 | Twice                                                   | Reaches                                                   | Mark  |
| --------------------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------- | --------------------------------------------------------- | ----- |
| `developer_instructions` (config, `-c`, profile, project) | Adds dev message beside base                           | Highest layer wins, no concat                           | K1–K6 unless RPC/role override, review, local compaction¹ | V     |
| `features.multi_agent_v2.subagent_developer_instructions` | **Replaces** inherited extra in children               | Last wins                                               | K4, K6, K5 without own text; not root                     | V     |
| Role `developer_instructions`                             | Beside parent base; replaces parent extra in child²    | One per role                                            | That role's children                                      | V     |
| `model_instructions_file` / `instructions`                | Replaces base (`instructions` empty clears it)         | Last wins; file beats `instructions`; empty file errors | K1–K6; not review, Guardian, memory, Realtime             | V     |
| app-server `baseInstructions` / `developerInstructions`   | Replaces base / **replaces** config extra³             | Duplicate JSON key: last wins                           | K3 thread (+ children I)                                  | V     |
| app-server `turn/start` `additionalContext`               | Adds dev msg (`application`) or user msg (`untrusted`) | Per-key map                                             | K3, that turn                                             | V     |
| app-server `thread/inject_items`                          | Adds dev msg; system-role item accepted, dropped       | Appends each                                            | K3 thread                                                 | V     |
| Requirements `additional_developer_instructions`          | Adds separate managed dev msg (~10k token cap)         | One managed value                                       | All non-Guardian sessions (I); children U                 | I / U |
| Command/MCP hook `additionalContext`                      | Adds dev msg                                           | Accumulates                                             | Session whose hook fired                                  | I     |
| AGENTS.md (global, then root→cwd)                         | Adds user msg                                          | `AGENTS.override.md` replaces per dir; dirs concatenate | K1–K6, review; skipped if project untrusted               | V / I |
| `compact_prompt` / `experimental_compact_prompt_file`     | Replaces summarize prompt (user msg)                   | Last wins                                               | Local compaction only                                     | V     |
| `root_agent_usage_hint_text` / `subagent_usage_hint_text` | Replaces `<multi_agent_role>` block                    | Last wins                                               | Root (V) / children (I)                                   | V / I |
| collaborationMode `settings.developer_instructions`       | Replaces mode block                                    | Last wins                                               | Thread in that mode                                       | I     |
| `include_*_instructions` toggles                          | Remove a block                                         | Last wins                                               | Root                                                      | V     |
| TUI `terminal_visualization_instructions` feature         | Appends to the extra string                            | —                                                       | K1 only                                                   | I     |

1. Side turns inherit config: consolidation, title/recap; not RPC overrides (I).
   Not memory extraction, Guardian or Realtime (I). K6 user role named `default`
   with fork none/N: role text replaces it (I).
2. Declared role with the key omitted inherits extra (V). Discovered role with
   the key missing is skipped (I). Blank role text is a load error (I). Role
   base-replacement keys are dropped; parent base remains (I).
3. Set by `thread/start` `developerInstructions` (V). Resume of an
   already-loaded thread keeps the original; new overrides are ignored (V).

### Kiro

This map describes v3/KAS, selected by this configuration. The v2 engine (not
used by this config) remains covered by the replay cases.

| Channel                                                                      | Effect                                   | Twice                                                 | Reaches                                                                          | Mark  |
| ---------------------------------------------------------------------------- | ---------------------------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------- | ----- |
| Global steering `~/.kiro/steering/*.md`                                      | Adds user text before base or agent body | Combined with workspace and inline rules              | Main and invoke children (`w-v3`, `a3-invoke`)                                   | V     |
| Workspace steering `.kiro/steering/*.md`; root `AGENTS.md`                   | Adds before base                         | Combined with global and inline rules                 | Main and invoke children (`w-v3`, `a3-invoke`)                                   | V     |
| ACP `_meta.kiro.steering[]`                                                  | Adds after file steering, before body    | Same name across global/workspace/inline retained     | ACP main (`k3-dup`); invoke child (`a3-invoke`)                                  | V     |
| Agent `prompt`, ACP `customAgents`                                           | Replaces base                            | Profile collision rules not re-verified at 2.28.0 (U) | Main (`k3-hooked`) and named invoke children (`a3-invoke`)                       | V / U |
| `invoke_sub_agent` `inlineAgent.systemPrompt`                                | Replaces body when inline agents enabled | —                                                     | Invoke child (`claude:k-pins`, `codex:R3`); disabled gate leaves agent not found | V     |
| `agentSpawn` hook stdout                                                     | Adds after body in `history[0]`          | —                                                     | Main (`k3-hooked`); absent in hooked invoke child (`a3-invoke`)                  | V     |
| Agent `preset`; prompt schema and dispatch                                   | Selected preset replaces body            | —                                                     | Invoke dispatch (`codex:R6`)                                                     | A     |
| `README.md`, agent resources, output style, manual/file-match steering       | not re-verified at 2.28.0                | not re-verified at 2.28.0                             | not re-verified at 2.28.0                                                        | U     |
| Workflow steering; compaction/title; resume prompt snapshot                  | not re-verified at 2.28.0                | —                                                     | not re-verified at 2.28.0                                                        | U     |
| `systemPrompt` / `appendSystemPrompt` host fields; `userPromptSubmit` stdout | not re-verified at 2.28.0                | —                                                     | not re-verified at 2.28.0                                                        | U     |

The capture backend proves client payloads. The account-controlled
`system_field_injection` and server-side prompt are not re-verified at 2.28.0
(U); see [Open UNKNOWNs](evidence.md#open-unknowns).

### Kimchi

`codex:S` has no replay script in this tree. Prompt composition, channel
precedence and reach are not re-verified at 1.5.1 (U); see the Open UNKNOWNs.
Workflow background argv is separately verified by `codex:W`: parent
system-prompt flags are not forwarded.

| Channel                                                  | Result at pin            | Mark |
| -------------------------------------------------------- | ------------------------ | ---- |
| `--append-system-prompt TEXT\|PATH`                      | not re-verified at 1.5.1 | U    |
| `APPEND_SYSTEM.md`                                       | not re-verified at 1.5.1 | U    |
| `SYSTEM.md` / `--system-prompt`                          | not re-verified at 1.5.1 | U    |
| ACP `_meta["kimchi.dev"].appendSystemPrompt`             | not re-verified at 1.5.1 | U    |
| AGENTS.md / CLAUDE.md (+ `.local`)                       | not re-verified at 1.5.1 | U    |
| SessionStart hook (systemPrompt delivery)                | not re-verified at 1.5.1 | U    |
| Claude-Code hooks, `systemMessage`, prompt-summary notes | not re-verified at 1.5.1 | U    |
| Extension `before_agent_start`                           | not re-verified at 1.5.1 | U    |
| Extension `before_provider_request`                      | not re-verified at 1.5.1 | U    |
| System-prompt blocks                                     | not re-verified at 1.5.1 | U    |
| Memory digest                                            | not re-verified at 1.5.1 | U    |
| Agent `.md` body + `prompt_mode`                         | not re-verified at 1.5.1 | U    |

## Replay

Scripts: `packages/delegate-routing/probes/delegates/<harness>/`.

| Harness | Case ids                                                                                                                                   |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Claude  | `codex:P` (K1–K7); `p3-agent-named` (custom prompt wins); `snap1`, `snap2`, `snap3` (resume snapshot)                                      |
| Codex   | `codex:R4` (base), `claude:R10` (extra / child); `wireB` (`subagent_developer_instructions`), `piD6` (unknown trust)                       |
| Kiro    | `codex:R8`; `w-v3` (steering before base), `k3-dup` (duplicate steering), `k3-hooked` (KAS agentSpawn), `a3-invoke` (no hooks in children) |
| Kimchi  | `codex:S`                                                                                                                                  |

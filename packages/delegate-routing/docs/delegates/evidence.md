# Evidence and reverification

How every cell in this reference set was established, how to rerun it, and when
it goes stale. Scope: Claude Code, Codex, Kiro, Kimchi. No cell in any harness
is SPLIT.

## Evidence marks

| Mark  | Meaning                                                                 | Strength |
| ----- | ----------------------------------------------------------------------- | -------- |
| V     | Executed: wire capture, transcript/rollout, or binary output            | highest  |
| Vr    | Executed the extracted bundle function, not the CLI (Claude prompt map) | high     |
| A     | Read from AST / pinned source, not executed                             | medium   |
| I     | Inferred from code or a vendor unit test, not executed                  | medium   |
| G     | Grep of help text, strings or source                                    | low      |
| U     | Unknown; see [Open UNKNOWNs](#open-unknowns)                            | none     |
| SPLIT | Sides disagree, unsettled (none currently)                              | —        |

Combined marks (`V; A`, `V/G`, `V list; A factory`) apply left to right to the
parts of the cell. `V help` proves syntax exposure only.

## Pinned versions

| Harness     | Component          | Version                | Pin                                               |
| ----------- | ------------------ | ---------------------- | ------------------------------------------------- |
| Claude Code | CLI                | 2.1.289                | `packages/claude-code/sources.json`               |
| Codex       | CLI (source build) | 0.160.0                | `packages/chatgpt-codex/sources.json`             |
| Kiro        | CLI                | 2.27.1                 | `packages/kiro-cli/sources.json`                  |
| Kiro        | KAS (v3 engine)    | 0.66.22                | bundled in the kiro-cli 2.27.1 release            |
| Kimchi      | CLI                | 1.5.1                  | `packages/kimchi/sources.json`                    |
| Kimchi      | Pi (patched)       | 0.85.1                 | `packages/kimchi/sources.json` (`extraction.pi*`) |
| Kimchi      | kimchi-workflows   | 0.0.9 (rev `7a6765cc`) | `packages/kimchi/workflows-sources.json`          |

Kiro engine context: v2 is the default for `chat` and `acp`; v3/KAS rows need
`--v3`, `--agent-engine v3` or `chat.agentEngine` (V).

## Methods per harness

Case ids carry the side that produced them: `claude:`, `codex:` (the two
independent investigators) and `judge:` (re-runs that settled disagreements).

| Harness | Method                                                          | Yields | Example cases                                           |
| ------- | --------------------------------------------------------------- | ------ | ------------------------------------------------------- |
| Claude  | `-p` / stream-json / `mcp serve` against a local capture mock   | V      | `claude:depth`, `claude:ctl`, `claude:mcp_serve_agent`  |
| Claude  | TUI under tmux against the capture mock                         | V      | prompt map K1                                           |
| Claude  | Extracted bundle-function replay                                | Vr     | prompt map (main-thread agent body)                     |
| Claude  | Transcript replay (`jq` over session JSONL)                     | V      | prompt map snapshot records                             |
| Claude  | AST / source read; help and binary grep                         | A, G   | `codex:A`, `codex:H`, `codex:P`                         |
| Codex   | Wire capture against a fake provider (`CODEX_HOME` scratch)     | V      | `claude:R2`, `codex:R1.v2-lifecycle`                    |
| Codex   | `codex app-server` JSON-RPC driver                              | V      | `claude:R6`, `claude:R7`, `codex:R2`                    |
| Codex   | Rollout files; binary `--help` / schema output                  | V      | `codex:R1.exec-resume-fork`, `claude:R0`                |
| Codex   | Pinned source AST, vendor unit tests                            | A, I   | `codex:R0`, `judge:J2`                                  |
| Kiro    | Wire / recorder capture of the pinned binary                    | V      | `claude:k-pins`, `claude:h2-effort`                     |
| Kiro    | ACP driver (v2 and v3 sessions, callbacks)                      | V      | `judge:k-steer`, `judge:j-a2-cancel-cfg`                |
| Kiro    | KAS 0.66.22 bundle-function replay                              | V      | `codex:R3`, `codex:R5`                                  |
| Kiro    | AST / strings of the bundle; help                               | A, G   | `codex:R6`, `codex:R1`                                  |
| Kimchi  | `-p`, RPC and ACP runs against a fake model provider (`fake-a`) | V      | `claude:s1-fg-pins`, `claude:s2-rpc-bg`, `judge:J1`     |
| Kimchi  | Workflow runs (in-session and background steps)                 | V      | `claude:w1-workflow`, `claude:w3b-workflow-cancel-late` |
| Kimchi  | Fixture replay (prompt map)                                     | V      | prompt map memory worker                                |
| Kimchi  | Pinned v1.5.1 source read (file:line)                           | A      | `codex:N`, `codex:P`, `judge:J4`                        |
| Kimchi  | Resource / tool inventory                                       | V      | `claude:inv`                                            |

## Rerun

Each harness directory holds the ported probe scripts. Its `README.md` maps
every case id used in the reference tables to the exact command, what the case
shows, and the expected output excerpt. There is no single runner; run cases
from those READMEs. Settling a U marked "Operator? yes" needs an account or
privileged setup.

| Harness | Case index                                                                     | Model backend               | Extra setup                                        |
| ------- | ------------------------------------------------------------------------------ | --------------------------- | -------------------------------------------------- |
| Claude  | [`probes/delegates/claude/README.md`](../../probes/delegates/claude/README.md) | capture mock                | none (one LIVE case costs quota)                   |
| Codex   | [`probes/delegates/codex/README.md`](../../probes/delegates/codex/README.md)   | fake provider               | none                                               |
| Kiro    | [`probes/delegates/kiro/README.md`](../../probes/delegates/kiro/README.md)     | recorder; KAS bundle replay | `KIRO_BASE_HOME`: a home with a fake fixture login |
| Kimchi  | [`probes/delegates/kimchi/README.md`](../../probes/delegates/kimchi/README.md) | fake provider (`fake-a`)    | none                                               |

Authenticated, account-backed observations use
`packages/delegate-routing/probes/run.py` instead (see its README).

## Committed observation fixtures

Fixtures in `packages/delegate-routing/fixtures/capabilities/` record one
runtime, technique and mode each. Where the fixture says `unknown` and the
reference says V, the fixture lags the reference: promote it with a sanitized
extract under `fixtures/capabilities/evidence/`.

| Fixture                            | Reference rows it overlaps               | Fixture result                              | Reference                                               |
| ---------------------------------- | ---------------------------------------- | ------------------------------------------- | ------------------------------------------------------- |
| `claude-print-headless.json`       | Claude T1 `claude -p`                    | available supported; pins unknown           | V; child pins V (`claude:model_effort`)                 |
| `claude-workflow-headless.json`    | Claude T1 `Workflow`; T3 Workflow on/off | available unknown (P7)                      | V: `-p` default denies (`claude:wf_default`)            |
| `claude-workflow-interactive.json` | Claude T1 `Workflow` nodes               | all unknown; version unknown                | node model/effort V (`claude:wf_allowed`)               |
| `codex-exec-headless.json`         | Codex T1 `codex exec`                    | available, linked-worktree commit supported | V                                                       |
| `codex-spawn-agent-headless.json`  | Codex T1 V2 `spawn_agent`                | all unknown                                 | V (`claude:R2`, `codex:R1.v2-nested-depth-zero`)        |
| `kimchi-agent-headless.json`       | Kimchi T1 `Agent`; T3 nesting depth      | runsOwnSubagents unsupported; pins unknown  | depth 1 V; child model/thinking V (`claude:s1-fg-pins`) |
| `kiro-invoke-sub-agent-acp.json`   | Kiro T1 `invoke_sub_agent`; T3 depth     | depth 5 supported; pins unknown             | depth V (`codex:R5`); pins V (`claude:k-pins`)          |
| `kiro-run-workflow-headless.json`  | Kiro T1 `run_workflow`                   | available supported; pins unknown           | V (`claude:k-wfpins`, `codex:R4`)                       |
| `copilot-fleet-headless.json`      | none (Copilot is outside this reference) | —                                           | —                                                       |

## When to reverify

| Trigger                                                                       | Action                                                                                                     |
| ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `version` changes in a harness's `sources.json` (or `workflows-sources.json`) | Run that harness's case-index commands; re-mark every changed cell; bump its pin above                     |
| kiro-cli bump                                                                 | Also recheck the bundled KAS version; v3 rows depend on it                                                 |
| A U cell is settled                                                           | Run its settling step below; replace U with the new mark and case id                                       |
| A SPLIT appears                                                               | Judge re-run as a new `judge:` case before the cell is published                                           |
| A fixture lags its reference row                                              | Commit a sanitized extract; update the fixture result                                                      |
| Server-side gate suspected changed (I)                                        | Rerun the gated cases: Claude depth (`tengu_hazel_trellis`), Kiro `workflows` rollout, Codex model catalog |

## Open UNKNOWNs

Area: `delegate` = delegate tables (T1–T3), `prompt` = system-prompt map. Rank =
impact rank in the cross-harness prompt map (1 = could change the option most).

| Harness | Area     | Rank | Unknown                                                                                                               | Settles it                                                                         | Operator?                      |
| ------- | -------- | ---- | --------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------ |
| Claude  | prompt   | 1    | What real SDK/ACP hosts send in `initialize` (append file dropped if they append)                                     | Run each host against the capture mock                                             | yes: pick hosts                |
| Claude  | prompt   | 5    | When the bridge carrier is active (`CLAUDE_CODE_BRIDGE_PROMPT_SHA256`)                                                | Trace the setter; capture one Remote Control session                               | yes, if login needed           |
| Claude  | prompt   | 9    | Sub-agent append from interactive TUI                                                                                 | tmux + mock, flag set, spawn a child                                               | no                             |
| Claude  | prompt   | —    | Gated paths: `--bg`, teammates, coordinator, policyHelper order, remote isolation                                     | Enable each gate under the mock                                                    | yes: scope remote out          |
| Claude  | prompt   | —    | Census gaps: other built-in agents, prompt-section resolver / plugin middleware                                       | AST inventory + one mock capture each                                              | no                             |
| Claude  | delegate | —    | Running child after `set_model` / `apply_flag_settings`; env vs `agent()` effort                                      | Mock 2-turn child, switch between turns; node `effort` + env                       | no                             |
| Claude  | delegate | —    | Frontmatter `bypassPermissions` ignored under default parent: cause                                                   | Trace `ensureAgentsBypassConsent`; mock with consent-seeded config                 | no                             |
| Claude  | delegate | —    | Workflow `budget.total` setter from `-p` / SDK                                                                        | Locate directive parser; interactive tmux run                                      | no                             |
| Claude  | delegate | —    | `mcp serve` lifecycle (TaskStop, SendMessage, `tools/call` cancel)                                                    | Extend `claude:mcp_serve_agent` / `claude:mcp_serve_wf`                            | no                             |
| Claude  | delegate | —    | Remote / cloud / `--bg` daemon / teams / ACP behavior                                                                 | Gated account or daemon run; pick an external ACP adapter                          | yes: scope + account           |
| Claude  | delegate | —    | Skill `context: fork`, plugin `model.fork`, hook-agent depth, `Monitor` gate                                          | One mock case each against the fake provider                                       | no                             |
| Codex   | prompt   | 4    | Requirements `additional_developer_instructions`, hook `additionalContext` in children                                | Fake provider + `/etc/codex/requirements.toml` + SubagentStart hook                | yes: root `/etc` or bind-mount |
| Codex   | prompt   | 8    | TUI wire parity incl. shared daemon; `config.toml` reload                                                             | pty TUI against fake-provider `CODEX_HOME`, daemon on/off                          | no                             |
| Codex   | prompt   | —    | Guardian wire request: extra really absent?                                                                           | Fake provider + `approvals_reviewer` auto-review + approval-needing shell          | no                             |
| Codex   | prompt   | —    | Remote V2 compaction, memory phases, title/recap payloads                                                             | Fake provider advertising remote compaction; memories + title on                   | no                             |
| Codex   | prompt   | —    | Role `personality` change re-renders the base?                                                                        | Fake-provider spawn of a role with `personality="none"`                            | no                             |
| Codex   | delegate | —    | Live catalog parity (V2 per model)                                                                                    | One live `codex exec` spawn                                                        | no (exec slot)                 |
| Codex   | delegate | —    | `exec` root end with live children; signal cascade                                                                    | Fake provider + `codex exec --json` slow child                                     | no                             |
| Codex   | delegate | —    | Cloud task model, limits, cancel                                                                                      | Live account run                                                                   | yes                            |
| Codex   | delegate | —    | TUI / daemon / remote lifecycle                                                                                       | Scratch `CODEX_HOME` daemon, unwrapped binary                                      | no                             |
| Codex   | delegate | —    | Unanswered approval deadline; auto-review in children                                                                 | `R9` variant with `approvals_reviewer=auto_review`                                 | no                             |
| Codex   | delegate | —    | V1 close cascade at runtime; V2 tree after restart                                                                    | Depth-2 close; app-server restart replay                                           | no                             |
| Kiro    | prompt   | 2    | Server-side prompt; account `system_field_injection` value                                                            | Debug `kiro.log` `[QChat] request` from a live session                             | yes: work account              |
| Kiro    | prompt   | 7    | Inline ACP steering into `orchestrate_subagent` children / workflow steps; hooks in `custom-agent` children           | ACP driver as non-interactive client + MD agent with `dispatchKind:"custom-agent"` | no                             |
| Kiro    | prompt   | —    | `userPromptSubmit` exit codes 1 vs 2                                                                                  | Wire capture with hooks exiting 1 and 2                                            | no                             |
| Kiro    | prompt   | —    | v2 post-compaction turn: does `history[0]` return?                                                                    | Rerun `a2-compact3` with a delay before the third prompt                           | no                             |
| Kiro    | prompt   | —    | Unmapped prompts: spec / quick-spec / bug-fix / plan modes, `wf-*`, untrusted workspace, `inlineAgents` user-settable | Same wire harness with `modeId`, valid `.workflow.json`, trust revoked             | no                             |
| Kiro    | delegate | —    | Backend honors delegate model/effort                                                                                  | Debug `kiro.log` request from a real session                                       | yes                            |
| Kiro    | delegate | —    | v2 crew concurrency cap; `api.subagentTimeout` effect                                                                 | Offline 8-stage delayed crew, with and without the setting                         | no                             |
| Kiro    | delegate | —    | v2 parent prompt hang after child-id cancel (n=1)                                                                     | Rerun `claude:a2-cancelchild` with T=300 + second prompt                           | no                             |
| Kiro    | delegate | —    | Unanswered ACP permission callback; workflow-step perms headless                                                      | Callback-omission probe; `claude:k-wfpins` with reject policy, no `-a`             | no                             |
| Kiro    | delegate | —    | KAS child transcript after the fact; child `user_input`                                                               | ACP history/export by `subExecutionId`; rule calling `user_input`                  | no                             |
| Kiro    | delegate | —    | Cloud, `serve`, downloaded Crew behavior                                                                              | Account cloud session; local WS / Crew install inspection                          | yes (cloud)                    |
| Kimchi  | prompt   | 3    | Final provider-wire system (role serialization; handlers after `before_agent_start`)                                  | One `kimchi -p` against a local fake OpenAI endpoint with sentinels                | yes: live run                  |
| Kimchi  | prompt   | 6    | Background workflow child's full system; does `process.execPath` skip the Nix wrapper                                 | Background step with `KIMCHI_DEBUG_SESSION` + export                               | yes: live run                  |
| Kimchi  | prompt   | 10   | Can a file-based extension in a K4/K5 child append?                                                                   | Fixture replay with a child-visible extension; read `child.systemPrompt`           | no                             |
| Kimchi  | prompt   | —    | Can a user extension register system-prompt blocks?                                                                   | Check `createSystemPromptBlocks` reachability in the compiled binary               | no                             |
| Kimchi  | prompt   | —    | Remote-Runner and `/agents` generated prompts                                                                         | Read the remote ACP worker path and `agents/index.ts:2813`                         | no                             |
| Kimchi  | delegate | —    | `modelRoles` / multi-model routing of children in RPC, ACP, TUI (`-p`: no effect)                                     | Rerun `claude:s10-multimodel` over RPC and ACP; trace `getMultiModelEnabled`       | no                             |
| Kimchi  | delegate | —    | Real gateway honors model and `reasoning_effort` as sent                                                              | One live headless `Agent` call; read the usage record                              | yes: account                   |
| Kimchi  | delegate | —    | `--deny-tool` / `--allow-tool` without `--yolo`; deny on `Agent` blocks delegation                                    | Rerun s9-deny without `--yolo` and with `--deny-tool Agent`                        | no                             |
| Kimchi  | delegate | —    | Remote worker: model, effort, permissions, descendant cancel                                                          | Live remote run with worker logs captured                                          | yes: account                   |
| Kimchi  | delegate | —    | ACP client receives the parent turn a background completion starts?                                                   | Extend `claude:a2-acp-default-perm`: wait longer, send another prompt              | no                             |
| Kimchi  | delegate | —    | Child commit in a linked worktree (fixture `linkedWorktreeCommit`)                                                    | Disposable repo + linked worktree, s9-style child `git commit`                     | no                             |

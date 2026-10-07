# Evidence and reverification

How every cell in this reference set was established, how to rerun it, and when
it goes stale. Scope: Claude Code, Codex, Kiro, Kimchi. No cell in any harness
is SPLIT.

## Evidence marks

| Mark  | Meaning                                                      | Strength |
| ----- | ------------------------------------------------------------ | -------- |
| V     | Executed: wire capture, transcript/rollout, or binary output | highest  |
| Vr    | Executed the extracted bundle function, not the CLI          | high     |
| A     | Read from AST / pinned source, not executed                  | medium   |
| I     | Inferred from code or a vendor unit test, not executed       | medium   |
| G     | Grep of help text, strings or source                         | low      |
| U     | Unknown; see [Open UNKNOWNs](#open-unknowns)                 | none     |
| SPLIT | Sides disagree, unsettled (none currently)                   | —        |

Combined marks (`V; A`, `V/G`, `V list; A factory`) apply left to right to the
parts of the cell. `V help` proves syntax exposure only.

## Pinned versions

| Harness     | Component          | Version                | Pin                                               |
| ----------- | ------------------ | ---------------------- | ------------------------------------------------- |
| Claude Code | CLI                | 2.1.292                | `packages/claude-code/sources.json`               |
| Codex       | CLI (source build) | 0.160.1                | `packages/chatgpt-codex/sources.json`             |
| Kiro        | CLI                | 2.28.0                 | `packages/kiro-cli/sources.json`                  |
| Kiro        | KAS (v3 engine)    | 0.66.26                | bundled in the kiro-cli 2.28.0 release            |
| Kimchi      | CLI                | 1.5.1                  | `packages/kimchi/sources.json`                    |
| Kimchi      | Pi (patched)       | 0.85.1                 | `packages/kimchi/sources.json` (`extraction.pi*`) |
| Kimchi      | kimchi-workflows   | 0.0.9 (rev `7a6765cc`) | `packages/kimchi/workflows-sources.json`          |

Kiro engine context: this configuration selects v3/KAS. The binary defaults
`chat` and `acp` to the v2 engine (not used by this config); replay cases select
the engine explicitly (V; codex:R1).

Kiro evidence uses the pinned x86_64-linux unwrapped build. The native binary
sha256 is `94c656bf317607ba1cca17e010e98fc5829d8e7c864f44bdedd8c4f4ad446c4d`;
the KAS and TUI bundle hashes are checked by `bundles.py` (codex:R1). All
indexed offline captures, bundle-function replays and AST/string probes were
re-run at this pin. The `pr-*` and `mx-*` families (`pr-replay.sh`,
`mx-replay.sh`) capture prompt reach and delegate control offline in both
launchers, headless `chat --v3` and `acp --agent-engine v3`; `mx-sysfield`
simulates the account flag. Headless v3 offers `invoke_sub_agent`, including
child and grandchild execution (codex:R3 `v3-headless`); the h3 orchestration
calls return `Tool "orchestrate_subagent" is not available.`. Parent
cancellation aborts the child and the next turn carries
`Sub-agent execution was cancelled` (claude:k-cancel). AST selectors and replay
dependencies target KAS 0.66.26. Only results at the flake's current pin belong
in this map and its probe index.

Claude evidence uses the pinned x86_64-linux `claude-code` build. The pin moved
from 2.1.291 to 2.1.292 with #2288; the cases added for the open unknowns
(`dmu_*`, cache, carrier, census, gated, host and TUI captures) ran at 2.1.292,
and the older indexed cases were last run at 2.1.291. Host replays use
python3Packages.claude-agent-sdk 0.2.163 and claude-agent-acp 0.84.0 (TS SDK
0.3.284) from this flake's nixpkgs. The login-backed `claude:live_resume`
capture also resumes the completed child with its earlier Bash tool result.
Depth defaults to 3, excess spawns at the 20-agent cap are refused, and workflow
nodes withhold Agent/Workflow. The depth resolver reads a valid cached
`tengu_hazel_trellis` value before the feature client fallback; explicit
environment depth still wins (`codex:A`). Only current-pin results belong in the
map and the probe index.

Kimchi evidence uses the pinned x86_64-linux source build (1.5.1), patched Pi
0.85.1 and kimchi-workflows 0.0.9 (`7a6765cc`). All indexed runnable offline
scenarios, four tool inventories, extracted-source AST probes and VM replays
were re-run with fake keys and local providers. Background steering reaches the
next child request (`claude:s2-rpc-bg`). The system-prompt map (`claude:sp-*`,
20 offline cases) replaces `codex:S`. Two LIVE cases (`claude:sp-p20-live-wire`,
`claude:l1-live-agent-model-effort`) reach the real gateway through
`live/recproxy.py` with the apiKey leaf of the operator's existing config; no
login flow and no remote worker were used. Only results at the current flake pin
belong in this map and probe index.

## Methods per harness

Codex evidence uses the pinned x86_64-linux source build (0.160.1). All indexed
offline cases were re-run with fresh homes, a fake provider, and the bundled
model catalog. `codex:R0` extracted 104 Rust files (2,665 declarations, zero
parse errors) and 28 SDK files (402 declarations); `claude:R1` emitted 104
regular and 167 experimental RPC methods, with 63 experimental-only methods.
`claude:R11` enables the message board and V2 explicitly for the
`disable_direct_message` variant, which withholds send/follow-up while retaining
spawn. Requirements cases mount a probe's `etc-codex/` at `/etc/codex` in an
unprivileged `bwrap` overlay, without root. One LIVE case
(`codex:L3.live-parity`) used the operator's ChatGPT login for one short turn:
the live catalog's `multi_agent_version` matches the bundled one per model.
Cloud execution is U.

Case ids carry the side that produced them: `claude:`, `codex:` (the two
independent investigators) and `judge:` (re-runs that settled disagreements).

| Harness | Method                                                          | Yields | Example cases                                           |
| ------- | --------------------------------------------------------------- | ------ | ------------------------------------------------------- |
| Claude  | `-p` / stream-json / `mcp serve` against a local capture mock   | V      | `claude:depth`, `claude:ctl`, `claude:mcp_serve_agent`  |
| Claude  | TUI under tmux against the capture mock                         | V      | prompt map K1                                           |
| Claude  | Extracted bundle-function replay                                | Vr     | `codex:prompt-functions` (carrier and isolated child)   |
| Claude  | Transcript replay (`jq` over session JSONL)                     | V      | prompt map snapshot records                             |
| Claude  | AST / source read; help and binary grep                         | A, G   | `codex:A`, `codex:H`, `codex:P`                         |
| Claude  | Real hosts against the capture mock (Python SDK, ACP adapter)   | V      | `claude:sdk-py`, `claude:acp-adapter`                   |
| Codex   | Wire capture against a fake provider (`CODEX_HOME` scratch)     | V      | `claude:R2`, `codex:R1.v2-lifecycle`                    |
| Codex   | `codex app-server` JSON-RPC driver                              | V      | `claude:R6`, `claude:R7`, `codex:R2`                    |
| Codex   | Rollout files; binary `--help` / schema output                  | V      | `codex:R1.exec-resume-fork`, `claude:R0`                |
| Codex   | Pinned source AST, vendor unit tests                            | A, I   | `codex:R0`, `judge:J2`                                  |
| Codex   | TUI under tmux; shared daemon over a Unix WebSocket             | V      | `codex:T1`, `codex:L2.daemon-detach`                    |
| Kiro    | Wire / recorder capture of the pinned binary                    | V      | `claude:k-pins`, `claude:h2-effort`                     |
| Kiro    | ACP driver (v3; v2 engine (not used by this config))            | V      | `judge:k-steer`, `judge:j-a2-cancel-cfg`                |
| Kiro    | KAS 0.66.26 bundle-function replay                              | Vr     | `codex:R5`                                              |
| Kiro    | AST / strings of the bundle; help                               | A, G   | `codex:R6`, `codex:R1`                                  |
| Kiro    | `reach.py` offsets per request (`pr-replay.sh`, `mx-replay.sh`) | V      | `pr-acp-orch`, `mx-resume`                              |
| Kimchi  | `-p`, RPC and ACP runs against a fake model provider (`fake-a`) | V      | `claude:s1-fg-pins`, `claude:s2-rpc-bg`, `judge:J1`     |
| Kimchi  | Workflow runs (in-session and background steps)                 | V      | `claude:w1-workflow`, `claude:w3b-workflow-cancel-late` |
| Kimchi  | Pinned v1.5.1 source read (file:line)                           | A      | `codex:N`, `codex:P`, `judge:J4`                        |
| Kimchi  | Resource / tool inventory                                       | V      | `claude:inv`                                            |
| Kimchi  | Full-wire prompt map (`live/prompt_map.py`, `sysprompt.py`)     | V      | `claude:sp-p01`, `claude:sp-p15`                        |

## Rerun

Each harness directory holds the ported probe scripts. Its `README.md` maps
every case id used in the reference tables to the exact command, what the case
shows, and the expected output excerpt. `probes/delegates/run.py` runs cases
straight from those tables: `--list` shows every case and whether it runs,
`--only=<harness>/<id>` (or a bare id, or a `prefix*`) selects, and each case
prints MATCH, MISMATCH or SKIP; the exit code is the MISMATCH count. LIVE cases
run only with `--live`. The case-table format is in the `run.py` docstring;
older rows with no backtick excerpt or a `<placeholder>` command show as SKIP.
Settling a U marked "Operator? yes" needs an account or privileged setup.

| Harness | Case index                                                                     | Model backend               | Extra setup                                        |
| ------- | ------------------------------------------------------------------------------ | --------------------------- | -------------------------------------------------- |
| Claude  | [`probes/delegates/claude/README.md`](../../probes/delegates/claude/README.md) | capture mock                | none (one LIVE case costs quota)                   |
| Codex   | [`probes/delegates/codex/README.md`](../../probes/delegates/codex/README.md)   | fake provider               | none                                               |
| Kiro    | [`probes/delegates/kiro/README.md`](../../probes/delegates/kiro/README.md)     | recorder; KAS bundle replay | `KIRO_BASE_HOME`: a home with a fake fixture login |
| Kimchi  | [`probes/delegates/kimchi/README.md`](../../probes/delegates/kimchi/README.md) | fake provider (`fake-a`)    | none                                               |

## When to reverify

| Trigger                                                                       | Action                                                                                                     |
| ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `version` changes in a harness's `sources.json` (or `workflows-sources.json`) | Run that harness's case-index commands; re-mark every changed cell; bump its pin above                     |
| kiro-cli bump                                                                 | Also recheck the bundled KAS version; v3 rows depend on it                                                 |
| A U cell is settled                                                           | Run its settling step below; replace U with the new mark and case id                                       |
| A SPLIT appears                                                               | Judge re-run as a new `judge:` case before the cell is published                                           |
| Server-side gate suspected changed (I)                                        | Rerun the gated cases: Claude depth (`tengu_hazel_trellis`), Kiro `workflows` rollout, Codex model catalog |

## Open UNKNOWNs

Area: `delegate` = delegate tables (T1–T3), `prompt` = system-prompt map. Rank =
impact rank in the cross-harness prompt map (1 = could change the option most).

| Harness | Area     | Rank | Unknown                                                                                                                        | Settles it                                                                              | Operator?                       |
| ------- | -------- | ---- | ------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------- | ------------------------------- |
| Claude  | prompt   | 1    | Other hosts' `initialize`: IDE ACP clients' `_meta` defaults (Zed, JetBrains), desktop app. Python SDK, ACP adapter, TS SDK: V | Point each host's CLI path at `host/sdk-recorder.sh` against the capture mock           | yes: pick hosts                 |
| Claude  | prompt   | —    | Real CCR / teleport / remote-session launch env and argv (the append-head designator is V)                                     | Account with Claude Code on the web; capture through the live proxy                     | yes: scope + account            |
| Claude  | prompt   | —    | Replay scripts for verify-run facts: TS SDK direct host, `policyHelper` under bwrap, append-head designator                    | Add `host/sdk-ts.sh`, `sysprompt/policy-helper.sh` and a `capture.sh` case              | no                              |
| Claude  | delegate | —    | Remote / cloud: `isolation:"remote"`, `--cloud`, `--remote-control`, `--teleport`, `RemoteTrigger`                             | One cloud session and one remote Agent call on an account                               | yes: scope + account            |
| Claude  | delegate | —    | Agent teams behavior: idle/wake, messaging, `TaskStop`, concurrency (not attempted)                                            | Extend `sysprompt/tui-subagent.py team` under tmux + mock                               | no                              |
| Claude  | delegate | —    | Delegate lifecycle through `claude-agent-acp`: `session/cancel` during a child, child permission callbacks                     | Extend `host/acp-adapter.sh` offline                                                    | yes: confirm the adapter to map |
| Claude  | delegate | —    | `Monitor` reach in `-p` with the account flag on (the gate is A; the first live run's listing was not saved)                   | Rerun `claude:live_monitor`                                                             | no (LIVE quota)                 |
| Claude  | delegate | —    | `--bg` session depth and concurrency; `respawn`, `attach`                                                                      | Extend `claude:dmu_bg_daemon`                                                           | no                              |
| Codex   | prompt   | —    | Realtime startup context: config `developer_instructions` or AGENTS.md on the wire? (instructions omit them, A)                | Local WebSocket mock via `experimental_realtime_ws_base_url`; trace the default context | no                              |
| Codex   | prompt   | —    | MCP-type hook `additionalContext` reach (command hooks are V)                                                                  | `codex:P1` with an MCP hook                                                             | no                              |
| Codex   | prompt   | —    | Live catalog auto-review template: an `extra_policy` slot? (bundled has none, so `guardian_extra_policy` is dropped)           | Keep the catalog `codex:L3.live-parity` fetches; grep its templates                     | no (LIVE quota)                 |
| Codex   | delegate | —    | Cloud task: server-side model, limits, web cancel (client sends no model/effort and has no cancel, A)                          | Live account run on a throwaway environment                                             | yes: account + environment      |
| Codex   | delegate | —    | Internal worker limits: review, compaction, memory (guardian is V)                                                             | Fake provider: held stream and malformed output per worker                              | no                              |
| Kiro    | prompt   | 2    | Account `system_field_injection` value; server-side prompt (client half V, `mx-sysfield`)                                      | One live turn through a recorder; read the flag at key `2baac882…c7a03a`                | yes: work account               |
| Kiro    | delegate | —    | Backend honors delegate model/effort (client wire V)                                                                           | Live `claude:k-pins` fixtures with a debug log                                          | yes: work account               |
| Kiro    | delegate | —    | `--cloud --repo` behavior                                                                                                      | One account cloud session with logs                                                     | yes: account + scope            |
| Kiro    | delegate | —    | Downloaded `kiro-cli crew` behavior                                                                                            | Install in a scratch HOME (network) and capture its delegate surface                    | yes: scope (network download)   |
| Kiro    | delegate | —    | Global cap of host `_kiro/workflow/*` runs; `kiro-cli acp` session cap (not attempted)                                         | N parallel runs or sessions against `capserver2.py` with delayed rules                  | no                              |
| Kimchi  | prompt   | —    | Remote worker's server-side system (the client sends none, A)                                                                  | One authorized remote run; capture the worker's wire                                    | yes: account                    |
| Kimchi  | delegate | —    | Real gateway applies `reasoning_effort` (model as sent: V LIVE)                                                                | LIVE A/B of `claude:l1-live-agent-model-effort`, child thinking low vs high             | no (LIVE quota)                 |
| Kimchi  | delegate | —    | Remote worker: actual model, effort, descendant cancel (client forces `yolo`, sends no model/effort, A)                        | Remote run with worker logs; Ctrl+X during a child                                      | yes: account + workspace        |
| Kimchi  | delegate | —    | Multi-model child routing with a non-`kimchi-dev` orchestrator                                                                 | `claude:s10e-multimodel-acp` with `modelRoles.orchestrator` on another provider         | no                              |

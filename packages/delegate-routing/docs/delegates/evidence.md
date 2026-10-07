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
re-run at this pin; all 19 runnable older wire2 rows (`claude:*`, `judge:*`)
replay as MATCH, and `judge:send-dir` checks the hash-verified bundle through
`kas_sites.py` without `KIRO_BUNDLES`. `kiro/*` replays 67 MATCH, 0 MISMATCH, 12
SKIP. The `pr-*` and `mx-*` families (`pr-replay.sh`, `mx-replay.sh`) capture
prompt reach and delegate control offline in both launchers, headless
`chat --v3` and `acp --agent-engine v3`; `mx-sysfield` simulates the account
flag. Headless v3 offers `invoke_sub_agent`, including child and grandchild
execution (codex:R3 `v3-headless`); the h3 orchestration calls return
`Tool "orchestrate_subagent" is not available.`. Parent cancellation aborts the
child and the next turn carries `Sub-agent execution was cancelled`
(claude:k-cancel). AST selectors and replay dependencies target KAS 0.66.26.

Claude evidence uses the pinned x86_64-linux `claude-code` build. The pin moved
from 2.1.291 to 2.1.292 with #2288. The cases added for the open unknowns
(`claude:dmu_*`, cache, carrier, census, gated, host and TUI captures) match
their excerpts at 2.1.292, and so do the older indexed cases: `claude/*` replays
76 MATCH, 0 MISMATCH, 26 SKIP. `claude:steer_bg` sends its follow-up only after
the completion notification (`claude/cases.py:223`). Offline, the resumed child
carries either its full history or only its original prompt plus the follow-up,
later turns dropped; it varies by run and the cause is not established. The LIVE
`claude:live_resume` (n=1, 2.1.292) resumed the completed child with its full
history, earlier `ALPHA_7731` Bash tool result included. Host replays use
python3Packages.claude-agent-sdk 0.2.163 and claude-agent-acp 0.84.0 (TS SDK
0.3.284) from this flake's nixpkgs. Depth defaults to 3, excess spawns at the
20-agent cap are refused, and workflow nodes withhold Agent/Workflow. The depth
resolver reads a valid cached `tengu_hazel_trellis` value before the feature
client fallback; explicit environment depth still wins (`codex:A`).

Kimchi evidence uses the pinned x86_64-linux source build (1.5.1), patched Pi
0.85.1 and kimchi-workflows 0.0.9 (`7a6765cc`). All indexed runnable offline
scenarios, four tool inventories, extracted-source AST probes and VM replays
were re-run with fake keys and local providers. Background steering reaches the
next child request (`claude:s2-rpc-bg`). The system-prompt map (`claude:sp-*`,
20 offline cases) replaces `codex:S`. Three LIVE cases
(`claude:sp-p20-live-wire`, `claude:l1-live-agent-model-effort`,
`claude:l2-live-effort-ab`) reach the real gateway through `live/recproxy.py`
with the apiKey leaf of the operator's existing config; no login flow and no
remote worker were used. `kimchi/*` replays 54 MATCH, 0 MISMATCH, 15 SKIP. A
5-per-arm `claude:l2-live-effort-ab` (`--thinking minimal` vs `max`, scenarios
in `live/sc/`, each answered 200 by the model sent) showed no detectable effect
of effort on `reasoning_tokens` at n=5 on a one-turn prompt (V LIVE): minimax-m3
means 253 vs 231, glm-5.3 71 vs 92, arms overlapping on both models.

## Methods per harness

Codex evidence uses the pinned x86_64-linux source build (0.160.1). All indexed
offline cases were re-run with fresh homes, a fake provider, and the bundled
model catalog; `codex/*` replays 54 MATCH, 0 MISMATCH, 9 SKIP. `codex:R0`
extracted 104 Rust files (2,665 declarations, zero parse errors) and 28 SDK
files (402 declarations); `claude:R1` emitted 104 regular and 167 experimental
RPC methods, with 63 experimental-only methods. `claude:R11` enables the message
board and V2 explicitly for the `disable_direct_message` variant, which
withholds send/follow-up while retaining spawn. Requirements cases mount a
probe's `etc-codex/` at `/etc/codex` in an unprivileged `bwrap` overlay, without
root. Two LIVE cases used the operator's ChatGPT login for one short turn each:
`codex:L3.live-parity` found the live catalog's `multi_agent_version` equal to
the bundled one for every model both list; `codex:L3.live-guardian` found its
auto-review template equal too. Cloud execution is out of scope.

Case ids carry the side that produced them: `claude:`, `codex:` (the two
independent investigators) and `judge:` (re-runs that settled disagreements).

| Harness | Method                                                          | Yields | Example cases                                                       |
| ------- | --------------------------------------------------------------- | ------ | ------------------------------------------------------------------- |
| Claude  | `-p` / stream-json / `mcp serve` against a local capture mock   | V      | `claude:ctl`, `claude:dmu_mcp_lifecycle`, `claude:dmu_mcp_wf_alone` |
| Claude  | TUI under tmux against the capture mock                         | V      | prompt map K1, `claude:dmu_team_tui`                                |
| Claude  | Extracted bundle-function replay                                | Vr     | `codex:prompt-functions` (carrier and isolated child)               |
| Claude  | Transcript replay (`jq` over session JSONL)                     | V      | prompt map snapshot records                                         |
| Claude  | AST / source read; help and binary grep                         | A, G   | `codex:A`, `codex:H`, `codex:P`                                     |
| Claude  | Real hosts against the capture mock (Python, TS SDK; ACP)       | V      | `claude:sdk-py`, `claude:sdk-ts`, `claude:acp-adapter`              |
| Codex   | Wire capture against a fake provider (`CODEX_HOME` scratch)     | V      | `codex:R4`, `claude:R14`                                            |
| Codex   | `codex app-server` JSON-RPC driver                              | V      | `codex:L5.v2-restart`, `codex:R1.v2-interrupt-tree`                 |
| Codex   | Rollout files; binary `--help` / schema output                  | V      | `codex:M1`                                                          |
| Codex   | Pinned source AST, vendor unit tests                            | A, I   | `codex:R0`, `judge:J2`                                              |
| Codex   | TUI under tmux; shared daemon over a Unix WebSocket             | V      | `codex:T1`, `codex:L2.daemon-detach`                                |
| Kiro    | Wire / recorder capture of the pinned binary                    | V      | `mx-hl-steer`, `mx-ups`                                             |
| Kiro    | ACP driver (v3; v2 engine (not used by this config))            | V      | `claude:k-cancel`, `judge:k-wfctl`                                  |
| Kiro    | KAS 0.66.26 bundle-function replay                              | Vr     | `codex:R5`                                                          |
| Kiro    | AST / strings of the bundle; help                               | A, G   | `codex:R6`, `codex:R1`                                              |
| Kiro    | `reach.py` offsets per request (`pr-replay.sh`, `mx-replay.sh`) | V      | `pr-acp-orch`, `mx-resume`                                          |
| Kimchi  | `-p`, RPC and ACP runs against a fake model provider (`fake-a`) | V      | `claude:s1-fg-pins`, `claude:s2-rpc-bg`, `claude:a1-acp-cancel-fg`  |
| Kimchi  | Workflow runs (in-session and background steps)                 | V      | `claude:w1-workflow`, `claude:w3b-workflow-cancel-late`             |
| Kimchi  | Pinned v1.5.1 source read (file:line)                           | A      | `codex:N`, `codex:P`, `judge:J4`                                    |
| Kimchi  | Resource / tool inventory                                       | V      | `claude:inv`                                                        |
| Kimchi  | Full-wire prompt map (`live/prompt_map.py`, `sysprompt.py`)     | V      | `claude:sp-p01-print-all`, `claude:sp-p15-workflow-steps`           |

## Rerun

Each harness directory holds the ported probe scripts. Its `README.md` maps
every case id used in the reference tables to the exact command, what the case
shows, and the expected output excerpt. `probes/delegates/run.py` runs cases
straight from those tables: `--list` shows every case and whether it runs,
`--only=<harness>/<id>` (or a bare id, or a `prefix*`) selects (an entry that
matches nothing exits 2); each case prints MATCH, MISMATCH or SKIP; the exit
code is the MISMATCH count. LIVE cases run only with `--live`. The case-table
format is in the `run.py` docstring; older rows with no backtick excerpt or a
`<placeholder>` command show as SKIP. Settling a U marked "Operator? yes" needs
an account or privileged setup.

| Harness | Case index                                                                     | Model backend               | Extra setup                                                                      |
| ------- | ------------------------------------------------------------------------------ | --------------------------- | -------------------------------------------------------------------------------- |
| Claude  | [`probes/delegates/claude/README.md`](../../probes/delegates/claude/README.md) | capture mock                | none (one LIVE case costs quota)                                                 |
| Codex   | [`probes/delegates/codex/README.md`](../../probes/delegates/codex/README.md)   | fake provider               | none                                                                             |
| Kiro    | [`probes/delegates/kiro/README.md`](../../probes/delegates/kiro/README.md)     | recorder; KAS bundle replay | `KIRO_BASE_HOME`: a home with a fake fixture login; `KIRO_BUNDLES` for AST cases |
| Kimchi  | [`probes/delegates/kimchi/README.md`](../../probes/delegates/kimchi/README.md) | fake provider (`fake-a`)    | none                                                                             |

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

| Harness | Area     | Rank | Unknown                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Settles it                                                                                   | Operator?    |
| ------- | -------- | ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------ |
| Kiro    | prompt   | 2    | Server-side prompt text: one exists (model-reported, not wire: the model reproduced safety/tone policy text absent from the client request, identically across sessions, typo included). `system_field_injection` is off for the probed account (V LIVE: base and steering stayed in `history[0]` across 7 sessions; the debug log drops some top-level fields, so this rests on `history[0]`, not on an absent field); other accounts U. Client half V, `mx-sysfield` | Text: not client-observable (vendor only). Flag: read key `2baac882…c7a03a` per account      | yes: account |
| Kiro    | delegate | —    | Backend honors delegate effort. Model: honored (V LIVE: `assistantResponseEvent.modelId` echoes the pinned child model); client wire V                                                                                                                                                                                                                                                                                                                                 | A TLS recorder on the live request body (the debug log drops `additionalModelRequestFields`) | yes: account |
| Kimchi  | delegate | —    | Effort reaches the model: does the gateway forward `reasoning_effort`, or does the model ignore it? Sent and answered 200 (V LIVE); no detectable effect at n=5 on a one-turn prompt (`claude:l2-live-effort-ab`)                                                                                                                                                                                                                                                      | Gateway-side view of the forwarded request, or a larger A/B on a multi-step prompt           | yes: account |

Out of scope (operator decision 2026-10-07); their cells stay U and are not
pursued:

- Claude remote / CCR / teleport / cloud (`isolation:"remote"`, `--cloud`,
  `--remote-control`, `--teleport`, `RemoteTrigger`): remote and cloud workers
  are out of scope.
- Claude other `initialize` hosts (IDE ACP clients, desktop app) and the
  delegate lifecycle through `claude-agent-acp`: the map covers the Claude CLI
  only.
- Codex cloud tasks: remote and cloud workers are out of scope.
- Kimchi remote worker (server-side system; model, effort, descendant cancel):
  remote and cloud workers are out of scope.
- Kiro `--cloud --repo`: remote and cloud workers are out of scope.
- Kiro Crew (`kiro-cli crew`): Kiro Crew is a separate harness
  (kirodotdev/kirocrew) that wraps kiro-cli, with its own TypeScript workflow
  engine; deferred.

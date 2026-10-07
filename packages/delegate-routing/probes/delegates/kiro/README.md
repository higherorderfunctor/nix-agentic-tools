# Kiro CLI delegate replays

Pins, evidence marks and case-prefix meanings:
[evidence guide](../../../docs/delegates/evidence.md).

Every script runs the repository's pinned `kiro-cli` unwrapped binary (built on
demand from `.#ciPackages.<system>.kiro-cli.unwrapped`; `KIRO_PKG=<store path>`
skips the build). Scratch output goes to `$PROBE_OUT/<name>` when set, otherwise
to a fresh temp dir that the script prints.

All cases are **OFFLINE**: the binary runs in an empty network namespace
(`unshare -rn`, loopback only) and every service endpoint points at a local
capture server that serves two fixture models and scripted event streams.

When `KIRO_BASE_HOME` is unset, both runners create a fresh HOME beneath their
run directory with `fixture_home.py`. The stdlib-only generator builds the
SQLite schema from scratch and seeds a **fake** builder-id token expiring in
2099; all four service endpoints point at `http://127.0.0.1:18765`. It never
opens or copies a real credential store. The runner's empty network namespace
confines every request to the fake server.

To create an explicit fixture home, run `python3 fixture_home.py <new-home>` and
set `KIRO_BASE_HOME=<new-home>`. The generator refuses to overwrite an existing
database. Only supply a fake fixture home to these offline probes.

## Harness

| File                                | Role                                                                                                                                                                                                                                                                                                                         |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wire2.sh <case> -- <args>`         | Runner. Env: `KIRO_BASE_HOME` (optional fake fixture home), `T` (timeout, default 60), `SETTINGS` (cli.json keys), `CASE_ENV` (`K=V …`). Uses `cases/<case>/rules.json` (else `cases/x.rules.json`), drives ACP with `acpctl.py` when `cases/<case>/script.json` exists, overlays `home-overlay/`, `ws/` and the case's own. |
| `fixture_home.py <new-home>`        | Create a throwaway fake login and local service settings without reading any credentials.                                                                                                                                                                                                                                    |
| `rules.py [--check]`                | Regenerate the h2 variants from shared bases and case deltas, or compare all 14 family paths byte-for-byte with `diff`.                                                                                                                                                                                                      |
| `capserver2.py`                     | Capture and scripted model server; writes `run/wire.jsonl` with timestamps.                                                                                                                                                                                                                                                  |
| `acpctl.py`                         | ACP stdio driver with timed steps (async prompt, cancel, steer, child id, extension calls); writes `run/acp.log`.                                                                                                                                                                                                            |
| `wiresum.py <wire.jsonl> [marker…]` | One line per model request: conversation, model, effort, tool count, markers.                                                                                                                                                                                                                                                |
| `toolres.py <wire.jsonl> [rule]`    | Tool uses and tool results seen in recorded requests.                                                                                                                                                                                                                                                                        |
| `bundles.py <dir>`                  | Extracts `kas.js` and `tui.js` from the pinned binary and checks their sha256.                                                                                                                                                                                                                                               |
| `lit.cjs`                           | acorn AST helper: string literal → enclosing node.                                                                                                                                                                                                                                                                           |
| `codex-side/`                       | `offline.py <case>` (cases in `codex-side/cases/`), `driver.py`, `capserver.py`, AST scripts over `$KIRO_BUNDLES/kas.js`, `help.sh`, `native_strings.py`.                                                                                                                                                                    |

The AST scripts need acorn and acorn-walk on `NODE_PATH` (not in nixpkgs):

```bash
d=$(mktemp -d) && npm install --prefix "$d" acorn@8 acorn-walk@8 && export NODE_PATH="$d/node_modules"
export KIRO_BUNDLES=$(mktemp -d) && python3 bundles.py "$KIRO_BUNDLES"
```

Read a run with `python3 wiresum.py <run>/wire.jsonl <markers>` and
`<run>/out.txt`; `wire2.sh` prints `<run>`.

## Cases

`ACP3` below stands for `-- acp --agent-engine v3 --auth-method cli`; `K` for
`"MAIN_KICKOFF USER_SENTINEL_1"`.

| Case id               | Command                                                                                                                                                                                                                                                       | What it shows                                                                                                  | Expected excerpt                                                                                               |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| claude:a2-cancelchild | `T=120 ./wire2.sh a2-cancelchild -- acp -a`                                                                                                                                                                                                                   | v2 `session/cancel` with the child id                                                                          | child `terminated`, its HTTP call dropped; parent prompt not back within 60 s (n=1)                            |
| claude:a2-steerchild  | `T=120 ./wire2.sh a2-steerchild -- acp -a`                                                                                                                                                                                                                    | `_session/steer` to the child id (from `_kiro.dev/subagent/list_update`) reaches only the child                | steer text in the child's next request only                                                                    |
| claude:g-agent-nosub  | `SETTINGS='{"chat.defaultAgent":"onlyread"}' ./wire2.sh g-agent-nosub -- chat --v2 --no-interactive hi`                                                                                                                                                       | agent `tools:["read"]` leaves only `read`                                                                      | `wiresum.py -v`: tools = `read`, no `subagent`                                                                 |
| claude:g-sub-off      | `SETTINGS='{"chat.enableSubagent":false}' ./wire2.sh g-sub-off -- chat --v2 --no-interactive hi`                                                                                                                                                              | the v2 tool list ignores `chat.enableSubagent`                                                                 | `subagent` still offered                                                                                       |
| claude:g-v1-deleg     | `SETTINGS='{"chat.enableDelegate":true}' ./wire2.sh g-v1-deleg -- chat --agent-engine v1 --no-interactive --model claude-sonnet-4 hi`                                                                                                                         | v1 gains `delegate` next to `use_subagent`                                                                     | `run/chat.log` lists `delegate` (launch/status)                                                                |
| claude:g-v2-effort    | `./wire2.sh g-v2-effort -- chat --v2 --no-interactive --effort low hi`                                                                                                                                                                                        | v2 sends effort only when asked                                                                                | `extra={"additionalModelRequestFields": {"output_config": {"effort": "low"}}}`                                 |
| claude:h2-agentpin    | `T=120 ./wire2.sh h2-agentpin -- chat --v2 --no-interactive -a K`                                                                                                                                                                                             | role agent `model` pins the crew child; agent `effortLevel` not sent                                           | child on `claude-haiku-4.5`, no effort field                                                                   |
| claude:h2-all         | `T=120 ./wire2.sh h2-all -- chat --v2 --no-interactive -a K`                                                                                                                                                                                                  | with `-a` the crew child's shell runs                                                                          | child shell output in the next request                                                                         |
| claude:h2-effort      | `T=120 ./wire2.sh h2-effort -- chat --v2 --no-interactive -a --effort low K`                                                                                                                                                                                  | parent sends effort low; crew children send none                                                               | parent `effort: low`; child rows no effort                                                                     |
| claude:h2-hookblock   | `SETTINGS='{"chat.defaultAgent":"gate"}' T=120 ./wire2.sh h2-hookblock -- chat --v2 --no-interactive -a K`                                                                                                                                                    | `preToolUse` hook exit 2 blocks `subagent`                                                                     | tool result carries the hook's block; no child request                                                         |
| claude:h2-trustdel    | `T=120 ./wire2.sh h2-trustdel -- chat --v2 --no-interactive --trust-tools=subagent K`                                                                                                                                                                         | trusting `subagent` lets the child run; the child's `shell` is still refused                                   | `tool permission approval is not supported in non-interactive mode`                                            |
| claude:h3-all         | `T=120 ./wire2.sh h3-all -- chat --v3 --no-interactive -a K`                                                                                                                                                                                                  | with `-a` the KAS child's shell runs                                                                           | child shell output in the next request                                                                         |
| claude:h3-hookblock   | `SETTINGS='{"chat.defaultAgent":"gate"}' T=120 ./wire2.sh h3-hookblock -- chat --v3 --no-interactive -a K`                                                                                                                                                    | `preToolUse` hook exit 2 blocks `orchestrate_subagent`                                                         | tool result carries the hook's block                                                                           |
| claude:h3-perm        | `T=120 ./wire2.sh h3-perm -- chat --v3 --no-interactive K`                                                                                                                                                                                                    | no trust: the stage fails and no child request is sent                                                         | stage `FAILED`                                                                                                 |
| claude:h3-trustdel2   | `T=120 ./wire2.sh h3-trustdel2 -- chat --v3 --no-interactive --trust-tools=orchestrate_subagent,invoke_sub_agent K`                                                                                                                                           | both tools trusted: the child runs; its untrusted `execute_bash` is rejected                                   | child request present; bash rejected                                                                           |
| claude:k-cancel       | `T=240 ./wire2.sh k-cancel ACP3`                                                                                                                                                                                                                              | v3 prompt cancel during a child call                                                                           | prompt `cancelled`; next turn "The tool invoke was aborted by the user."                                       |
| claude:k-perm         | `T=240 ./wire2.sh k-perm ACP3`                                                                                                                                                                                                                                | `invoke_sub_agent` asks `session/request_permission`; the child's `execute_bash` is rejected                   | "Sub-agent: custom"; "The user rejected this tool call."                                                       |
| claude:k-pins         | `T=240 ./wire2.sh k-pins ACP3`                                                                                                                                                                                                                                | child model/effort: pinned agent, inline agent, unpinned custom                                                | `wiresum.py … CHILD_PINNED CHILD_INLINE CHILD_CUSTOM`: haiku/low, haiku/medium, sonnet/high                    |
| claude:k-stall        | `CASE_ENV="KIRO_SUBAGENT_DEADLINE_MS=3000" T=120 ./wire2.sh k-stall ACP3`                                                                                                                                                                                     | sub-agent deadline                                                                                             | `toolres.py`: "Sub-agent 'custom' timed out after 3000ms and was aborted…"                                     |
| claude:k-wfpins       | `SETTINGS='{"chat.enableWorkflows":true}' CASE_ENV="KIRO_ENABLED_FEATURES=workflows KIRO_ROLLOUT_FEATURES=workflows" T=240 ./wire2.sh k-wfpins ACP3`                                                                                                          | workflow step model/effort resolution; `run_workflow` returns at once                                          | step default sonnet/high; step `modelId/effortLevel` haiku/medium; workflow-level haiku/max; "Status: running" |
| judge:j-a2-cancel-cfg | `T=120 ./wire2.sh j-a2-cancel-cfg -- acp -a`                                                                                                                                                                                                                  | v2: `session/set_config_option` unsupported; parent cancel does not stop the crew child                        | −32601; parent `cancelled` ≈5.8 s; two later child requests carry `CHILD_BASH_RAN`                             |
| judge:k-steer         | `T=240 ./wire2.sh k-steer ACP3`                                                                                                                                                                                                                               | v3 `_session/steer` on the parent reaches the in-flight child too                                              | `{"queued":true}`; `STEER_SENTINEL` in the child's and the parent's next requests                              |
| judge:k-wfctl         | `SETTINGS='{"chat.enableWorkflows":true}' CASE_ENV="KIRO_ENABLED_FEATURES=workflows KIRO_ROLLOUT_FEATURES=workflows" T=240 ./wire2.sh k-wfctl ACP3`                                                                                                           | parent `session/cancel` leaves workflows running; `_kiro/workflow/cancel` aborts one                           | `{"ok":true,"previousStatus":"running"}`; final list wfB `completed`, wfA `aborted`                            |
| judge:send-dir        | `node lit.cjs "$KIRO_BUNDLES/kas.js" '^parent$' function 400 40`                                                                                                                                                                                              | workflow `send_message` sender is `parent` or `step` (bidirectional)                                           | `function YMc(e,t,r){if(e)return{sender:"parent",severity:t};…return{sender:"step",severity:t}}`               |
| codex:R1              | `codex-side/help.sh`; `python3 bundles.py <dir>`                                                                                                                                                                                                              | CLI surface; v2 is the default engine for chat/ACP; bundle provenance                                          | `bundles.py` prints the two sha256 values `79a1a743…`, `3fe9ded8…`                                             |
| codex:R2              | `python3 codex-side/offline.py v2-flags`; `… v2-headless`; `… v2-controls`                                                                                                                                                                                    | v2 offers `subagent` (crew) whatever the subagent settings; child on haiku; child shell denied; ACP controls   | `approval is not supported in non-interactive mode`; `session/set_config_option` −32601                        |
| codex:R3              | `python3 codex-side/offline.py v3-deny`; `… v3-controls`; `… v3-inline`; `… v3-nested`                                                                                                                                                                        | KAS tools, inline pins (`_meta.kiro.settings.inlineAgents={enabled:true}`), nesting, cancel, consent           | `v3-inline`: child on `claude-haiku-4.5`, `INLINE_RESULT`; `v3-deny`: no child request                         |
| codex:R4              | `python3 codex-side/offline.py v3-workflow-ungated`; `… v3-workflow`; `… v3-pause`                                                                                                                                                                            | KAS workflow host RPCs, step model, pause/cancel/retry/output                                                  | `capturedOutputs.one = WORKFLOW_RETRY_DONE`; pause → `paused` → resume completes                               |
| codex:R5              | `cd <dir> && node codex-side/replay.cjs`                                                                                                                                                                                                                      | unchanged bundle functions in a VM: depth 5, per-execution semaphore 5, effort fallback, abort reach, deadline | `replay-results.json` assertions pass                                                                          |
| codex:R6              | `cd <dir> && node codex-side/extract.cjs delegate bCc wCc Wji sEt Lwe Fwe line:15957 line:15924 line:15930` and the other `extract.cjs`, `surfaces.cjs`, `acp.cjs`, `workflow.cjs`, `runner.cjs`, `tui.cjs`, `tui-gates.cjs`, `refs.cjs`, `inspect.cjs` calls | AST nodes for schemas, factories, ACP methods, workflow runner, TUI gates                                      | one `<label>.json` per call in `<dir>`                                                                         |
| codex:R7              | `cd <dir> && python3 codex-side/native_strings.py`                                                                                                                                                                                                            | string leads in the native binary (G only)                                                                     | `G string matches N`                                                                                           |
| codex:R8              | pointer only: the prior system-prompt study                                                                                                                                                                                                                   | steering, replacement prompts, default engines, hooks, child prompt inheritance                                | not re-run (see the system-prompt reference)                                                                   |
| codex:R9              | `python3 codex-side/summarize.py <kiro-codex work>`                                                                                                                                                                                                           | wire summary and assertions over the R2–R4 runs                                                                | `wire-summary.json`; assertions pass                                                                           |

Run every `.cjs` from an empty directory: they write their JSON to the current
directory. The full R6 call list:

```bash
node codex-side/extract.cjs delegate bCc wCc Wji sEt Lwe Fwe line:15957 line:15924 line:15930
node codex-side/extract.cjs schemas ZRr XRr dEt Yji pEt Xji oRc line:16494 line:16633
node codex-side/surfaces.cjs
node codex-side/acp.cjs
node codex-side/extract.cjs factories line:16876 line:17302 line:12162 Wze CGt GMr E5r x5r b5r
node codex-side/extract.cjs wrappers sIr
node codex-side/extract.cjs wrapper-class oIr
node codex-side/extract.cjs workflow-shape wy
node codex-side/extract.cjs workflow-schemas iW
node codex-side/extract.cjs workflow-controls LAr JU Mie Jve ZAr yT line:12416 line:12485
node codex-side/extract.cjs gates wl yf dE 'U$' YZe yGt FJt Uve t3e
node codex-side/extract.cjs timeout yU
node codex-side/workflow.cjs
node codex-side/runner.cjs
node codex-side/tui.cjs
node codex-side/tui-gates.cjs
node codex-side/refs.cjs inlineAgentsEnabled inlineAgents registerActiveChild activeChildren enableMainAgentSubagentTool enableDelegate enableSubagent
node codex-side/refs.cjs subagentOrchestration inlineAgents effortLevel concurrency maxConcurrency subagent_ registerActiveChild activeChildExecutions
node codex-side/inspect.cjs session/new session/cancel session/set_mode session/set_model session/fork _kiro/workflow _kiro/steer modelId effortLevel inlineAgentsEnabled enableMainAgentSubagentTool
```

Names such as `bCc` are minified identifiers of this exact bundle; `bundles.py`
refuses any other bundle.

### Prompt-map captures

These commands use the same common fixtures as the delegate cases. `k3-dup` and
`a3-invoke` add the original study's case-specific ACP data. Inspect
`wire.jsonl` with `wiresum.py`; request numbers can change between runs.

| Case id   | Command                                                                                             | Expected excerpt                                                             |
| --------- | --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| w-v3      | `T=90 ./wire2.sh w-v3 -- chat --v3 --no-interactive -a "hello USER_SENTINEL_1"`                     | Steering sentinels before the KAS base                                       |
| k3-dup    | `T=120 ./wire2.sh k3-dup -- acp --agent-engine v3 --auth-method cli`                                | `GLOBAL_DUP_SENTINEL`, `WS_DUP_SENTINEL`, `INLINE_DUP_SENTINEL` all retained |
| k3-hooked | `T=90 ./wire2.sh k3-hooked -- chat --v3 --no-interactive -a --agent hooked "hello USER_SENTINEL_1"` | `[Session Start Hook Output]`, `HOOK_AGENTSPAWN_SENTINEL`                    |
| a3-invoke | `T=240 ./wire2.sh a3-invoke -- acp --agent-engine v3 --auth-method cli`                             | Hooked child: `HOOKED_PROMPT_SENTINEL`; no hook-output sentinel              |

### Shared rules

The a2, h2, h3 and codex-side inline families use `rules/<family>.json` as their
base. Identical `cases/<case>/rules.json` paths are symlinks to that base, as is
`codex-side/cases/v3-inline.json`; `h2-agentpin`, `h2-effort` and
`v3-inline-ignored` are committed outputs of the small deltas in `rules.py`.
Every original cited case path still resolves. After editing a base or delta,
run `python3 rules.py`, then `python3 rules.py --check`. The check renders every
family member into a temporary directory and requires `diff` exit 0 against its
case path. All 14 paths were checked before replacing any duplicate with a link.

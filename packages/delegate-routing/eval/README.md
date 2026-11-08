# Acceptance suite

> **Last verified:** 2026-11-08 — helper-backed cases execute fake Readers
> through the delivered helper during offline dry-run and preserve receipts.
> Harness compliance remains unmeasured.

One manual suite of real sessions on Claude, Codex, Kiro and Kimchi. Each case
checks what the delivered delegate-routing configuration makes an agent do with
a real task. A human starts it; it spends real model turns on the operator's
logins. No Nix check or CI job runs a session.

## Baseline

The root runs at the operator's normal strong-tier medium so delegation choices
come from a realistic orchestrator. `ROOT_BASELINES` in `suite.py` owns these
pins; delegate models remain the agent's choice.

| Harness | Root model             | Root effort       | Controls                                                 |
| ------- | ---------------------- | ----------------- | -------------------------------------------------------- |
| Claude  | `opus`                 | `medium`          | `--model opus --effort medium`                           |
| Codex   | `gpt-6.1-sol`          | `medium`          | `--model gpt-6.1-sol -c model_reasoning_effort="medium"` |
| Kimchi  | `kimi-k3`              | `medium` thinking | `--model kimi-k3 --thinking medium`                      |
| Kiro    | newest `claude-opus-*` | `medium`          | `--model <id> --effort medium`                           |

Kiro resolves `.models[].model_id` from `kiro-cli chat --list-models -f json` at
run time, comparing version segments numerically; dry runs print the pattern
without querying the CLI. Codex does not copy `model` or
`model_reasoning_effort`; Kiro does not copy `chat.defaultModel`. Other
carried-over settings remain intact.

Each result and the PASS/FAIL table show requested and observed model/effort
separately. Observations use Claude's root init, Codex turn/session events
(including the matching root rollout), Kiro's request records in `chat.log` when
exposed by the engine, and Kimchi's `agent_start`/`agent_end`. Missing fields
read `not exposed`; requested settings are never substituted for observations.
Kimchi's `agent_start` carries no model and no event carries the thinking level,
so both read `not exposed` although assistant messages name the model; using
those needs proof that child messages never reach the parent stream.

## Cases

`cases.nix` evaluates repository delivery (`dev/ai.nix`) with explicit suite
runtime and delegate-routing settings, then applies each case's switches and
exports every delivered file. Personal `devenv.local.nix` is outside this
fixture configuration. Legacy prompts contain the task plus synthetic usage
numbers. Helper-backed prompts instead request helper and plan artifacts and
permit Reader execution.

| Cases                                                                                                                           | Switch or shape                                                                                       | Assertion                |
| ------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ------------------------ |
| `claude-reminder-on`, `claude-reminder-off`, `codex-reminder-on`, `codex-reminder-off`, `kiro-reminder-on`, `kiro-reminder-off` | `ai.programs.delegate-routing.reminder.enable`                                                        | `delegate`               |
| `claude-orchestrator-design`                                                                                                    | investigate `task_source.py` and design a setting; orchestrator enabled, only native Claude delegates | `workflow-before-source` |
| `codex-single`, `kimchi-single`, `kiro-single`                                                                                  | one task                                                                                              | `one-delegate`           |
| `codex-dependent`, `kimchi-dependent`, `kiro-dependent`                                                                         | dependent chain                                                                                       | `workflow`               |

The reminder cases are on/off pairs: the switch is the only difference.

Codex's delegation behavior under the reminder, and whether it has a delegation
clamp, remain unmeasured. Run both Codex reminder cases and inspect their
verdicts and root logs before claiming an effect.

The design case is a headless surrogate for interactive policy with a complete
brief supplied in the task; it does not exercise pre-handoff board/issue triage.
It does not measure human-turn latency, overlap of quick facts with a running
delegate, external launch order, or source-access order on Codex, Kimchi and
Kiro. The allowlist rejects unrecognized harmless preparatory tools as well as
source access; it accepts only exact listed usage-reader commands and does not
interpret shell programs. Offline events match Claude's assistant tool-use
envelopes and exclude child calls as production does. Hook payload checks cover
entry gating on supported delivery paths.

Legacy fixture prompts supply synthetic usage and tell the agent not to run
usage helpers, unlike production's live usage reads. This hides reader
execution, authentication and pool freshness; the offline ordering test
separately accepts a routing Skill load and listed usage reads before launch,
and rejects usage commands combined with source reads.

Assertions read the session's own event log. A delegate call is a tool call
named after a `subagent` or `workflow` technique of the case's runtime, or a
shell command that starts an `external` technique of any runtime (`claude -p`,
`codex exec`, `kimchi -p`, `kiro-cli chat`). The technique names come from the
evaluated `ai.programs.delegate-routing.runtimes.<runtime>.techniques`, the same
table the skill renders. Claude excludes calls made inside a delegate using
`parent_tool_use_id`. Codex reads only the root rollout (its `session_meta.id`
equals `thread.started`); a child's rollout is a separate file whose source is
`subagent.thread_spawn`, so it is never scanned, and `exec --json` emits no
spawn item (V; probe `codex:L1.exec-root-ends`). Child-event exclusion for
Kimchi and Kiro is unverified.

| Assertion                | Passes when the log shows                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `codex-lane`             | an external `codex exec` launch                                                                                                                                                                                                                                                                                                                                                             |
| `delegate`               | at least one delegate call                                                                                                                                                                                                                                                                                                                                                                  |
| `observe`                | nothing more: it records the delegates once the run answers                                                                                                                                                                                                                                                                                                                                 |
| `one-delegate`           | exactly one subagent or external delegate, and no workflow                                                                                                                                                                                                                                                                                                                                  |
| `workflow`               | a workflow technique, or at least two delegates                                                                                                                                                                                                                                                                                                                                             |
| `workflow-before-source` | a native Claude workflow precedes task-source access; before launch, allow only the routing Skill, Read of delivered skill/agent Markdown, exact enabled usage-reader commands from the delivered technique configuration, and `TaskCreate`, `TaskGet`, `TaskList`, `TaskUpdate`, `TodoRead`, `TodoWrite`; source Read, other shell commands and broad search fail; reads after launch pass |

Add a case when a real routing problem shows up, not to fill a matrix.

## Helper-backed cases

Live helper-backed cases are opt-in:
`python3 packages/delegate-routing/eval/suite.py --helper-backed --only='codex-helper-*'`.
This command starts real sessions and spends model turns; it requires operator
authorization. `--dry-run` includes these cases automatically and starts no
harness.

The two `codex-helper-*` cases are `independent-wave` and `routing-controls`.
Both assert cross-runtime Reader execution, outside-before-session selection and
under-tier reviewer exclusion; `independent-wave` additionally checks
independent units. Their separate `eval/helper-fixture.nix` module registers
three fake Readers: outside and session on Codex, and cross-runtime on Kiro
outside the automatic launch set. Reader output deliberately names a different
`.pool`; registry keys remain authoritative. The session has less headroom than
the outside pool; a mid-tier family is available to writers but excluded from
review. Native delegate commands remain real, with no launch stubs. The
independent task owns `words.py` and `square.py` separately and checks their
saved plan for a shared disjoint wave.

Offline preparation invokes the absolute helper command read from the delivered
skill with explicit launch evidence. `logs/setup-helper.json` records argv, exit
code and helper JSON; `logs/setup-reader-receipts.jsonl` records executed Reader
identities. It checks all three Readers, outside-before-session selection and
the under-tier exclusion. The independent case also records successful helper
`--check-plan` validation of a hand-authored two-unit wave and rubric-bearing
briefs in `logs/setup-plan-validation.json`. These receipts prove fixture
wiring, not agent behavior. The Python regression invokes the helper source with
child Reader processes and mutates each expected control to prove the assertions
reject it.

Live sessions write separate `logs/session-reader-receipts.jsonl` receipts. The
runner archives the requested `routing-evidence.json` and `routing-plan.json` as
`logs/routing-artifacts.json` before cleanup and reports missing or inconsistent
evidence as FAIL. Reader receipts and saved wave shape alone do not prove
organic planner compliance, concurrent execution, review independence,
authentication or live budget freshness; inspect actual helper and launch calls
before making those claims. No live helper-backed sessions have been measured.

The standalone default `--dry-run` may realize generated Nix inputs, including
the packaged helper and fake Readers. In environments prohibiting builds, use an
already realized `--fixtures` export or report that limitation; Python
regressions need no Nix realization.

## Running

Run from the repository root. Without `--fixtures` the runner evaluates the
cases with Nix and realizes the generated files they point at.

```bash
eval=packages/delegate-routing/eval/suite.py
python3 "$eval" --dry-run                                  # validate, print every launch, start nothing
python3 "$eval" --list                                     # case ids, harness and assertion
python3 "$eval" --case codex-single                        # one case
python3 "$eval" --only='kimchi-*,codex-single'             # ids, or a prefix ending in *
python3 "$eval" --harness kiro                             # one harness
python3 "$eval" --claude-token-file ~/.config/delegate-suite/claude-token  # the whole suite
```

The run prints one row per case: `PASS`, `FAIL` or `ERROR`. It exits non-zero
only when a case is `ERROR`, meaning it could not reach an answer: a missing
binary or login, a cap hit, a crash, no completion event, a leak, or the
fixture's routing skill missing from the startup record, or delegates seen by
the hook but missed by the event extractor. A `FAIL` is a real answer that broke
the assertion. Each case keeps `logs/` (events, stderr, hook log, harness logs,
`verdict.json`); `summary.json` holds every row.

`--dry-run` renders each fixture and scratch configuration and prints the exact
argv, environment and files per case. Secrets show where they come from, never
their value. `checks.x86_64-linux.delegate-routing-eval-structure` runs the same
dry run in the sandbox, with no harness on `PATH` and no login.

## Isolation

Every case gets `<out>/<case>/repo`, a fresh git repository holding the
delivered files (store symlinks, as devenv delivers them), and
`<out>/<case>/home`, a scratch `HOME`. The process starts with only an
allowlisted environment: `HOME`, `PATH`, `LANG`, `TERM`, `USER`, `TMPDIR`, the
`XDG_*` directories inside the scratch home, `DEVENV_ROOT`, and the harness's
own variables. For Kiro, `XDG_DATA_HOME` and `KIRO_DATA_DIR` stay real to share
the login database (decision 3); other per-user state in that database is
unverified until a live chat log is captured. Memory, user MCP servers, user
skills, plugins and user instructions all live under the real home, so the
scratch home drops them. `--keep` keeps the fixture and scratch home; by default
only the logs stay.

The default run directory is `/var/tmp/delegate-routing-suite/<UTC time>`. A
live run refuses a directory under `~` or `/tmp`, or one with an `AGENTS.md` or
`CLAUDE.md` above it: Kimchi and Claude load ancestor context files, and Codex
refuses helper binaries under a temporary directory.

| Harness | Launch                                                                                                                                                                                                          | Login                                                                                                                                                 | Normal-session settings carried over                                                                         |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Claude  | `claude -p --setting-sources project`, overlay `--settings`, `--model opus --effort medium --permission-mode auto`, scratch `CLAUDE_CONFIG_DIR`, memory, org memory, policy skills and claude.ai connectors off | `CLAUDE_CODE_OAUTH_TOKEN` from a `claude setup-token` token (`--claude-token-file` or the variable). `~/.claude` credentials are never read or copied | `enableWorkflows`, `ultracode`; the fixture's `.mcp.json` servers are enabled                                |
| Codex   | `codex exec --json` with apps, plugins, remote plugins and memories disabled; scratch `CODEX_HOME`                                                                                                              | `auth.json` symlinked, never copied: Codex rewrites it in place, so a refresh reaches the real file                                                   | `default_permissions`, `permissions`, `features`, `agents`; the fixture trusted in the scratch `config.toml` |
| Kimchi  | `kimchi -p --mode json --approve --auto -- <task>`                                                                                                                                                              | `KIMCHI_API_KEY` from `~/.config/kimchi/config.json`, session-only                                                                                    | `harness/settings.json` with the memory extension forced off                                                 |
| Kiro    | `kiro-cli chat --v3 --no-interactive --trust-all-tools --output-format stream-json` through the operator's wrapper                                                                                              | the real data dir (`KIRO_DATA_DIR`), shared, so a refresh lands in the database the operator already uses                                             | `chat.enableCheckpoint`, `chat.enableTangentMode`, `chat.enableWorkflows`                                    |

Vendor-bundled skills and system prompts are kept: they are vendor surface.
Claude and Kiro also get a log-only `PreToolUse` hook that appends each request
to `logs/hook-calls.jsonl` and always exits 0; it is a second record, not
counted. A `claude` binary must resolve inside `/nix/store` (`~/.local/bin`
holds a stale native install); `--bin NAME=PATH` overrides any harness binary.
Each case first runs the binary's `--version` in the fixture; a non-zero exit is
an `ERROR` naming its output. With Kimchi enabled in personal
`devenv.local.nix`, the devenv shell puts the project Kimchi wrapper first on
`PATH`; it refuses any other directory. From that shell, pass
`--bin kimchi=<path>` for a binary that can launch in the fixture (for example
the profile's pinned `kimchi`).

**Caps.** 600 s wall clock per case, then the whole process group gets SIGTERM
and, 30 s later, SIGKILL; delegates still running when the session ends are
killed with it. Claude adds `--max-turns 40 --max-budget-usd 5` (the budget is a
list-price tripwire under OAuth). Kiro has no turn flag, so the runner stops it
after 40 tool calls. Codex and Kimchi have no turn or spend cap.

**Nested CLI delegates** inherit the session's environment. Same-runtime
children ARE logged in and can run and spend inside the 600 s process-group cap:
Claude and Kimchi inherit tokens, Codex shares the auth symlink, and Kiro shares
the real data directory. Cross-runtime children without a supplied login fail,
and the attempt is still logged. No PATH shim blocks nested children.

## Leak and delivery checks

A case is `ERROR` when either check fails, because its answer would not measure
the delivered configuration.

- **Leak:** personal configuration paths under the real home still fail in any
  log. Startup checks attribute skills and MCP entries by source, never by a
  bare name in arbitrary prose. Codex expands skill-root aliases in
  `prompt-input.json` and checks both recorded paths and resolved targets
  against personal skill roots; the log path scan covers user MCP configuration
  paths. Claude requires plugins to be builtin, MCP servers to have
  `source: project`, and agents to be builtin or fixture-delivered. Its debug
  log reports skill scope counts rather than individual paths: every disk skill
  must be project-delivered, with exactly the fixture count and zero managed,
  user, additional, legacy or plugin skills. Only after those checks is the init
  remainder attributed to vendor bundles. A missing or changed source record
  fails closed. Kiro's skill metadata carries origin and root.
- **Delivery:** Claude's init `skills` list must contain `delegate-routing`.
  Codex must include the fixture skill's whitespace-normalized frontmatter
  description in the startup record. Kiro's `available_commands_update` must
  list the skill with workspace origin and the fixture root. Kimchi stays
  unverified because its JSON stream exposes no loaded-skill catalog.

| Harness | Startup record                                                                   |
| ------- | -------------------------------------------------------------------------------- |
| Claude  | `system`/`init` plus `--debug-file` loader scope evidence                        |
| Codex   | `codex debug prompt-input` with the same flags, run first (no model call)        |
| Kiro    | stream `sessionUpdate.data.update.availableCommands`, with skill source metadata |
| Kimchi  | none: its JSON stream starts with a session header, so delivery is unverified    |

The Kiro CLI wraps ACP updates in `data`, and completes with `runFinished`,
rather than raw ACP `params`/`result`. Tool ids live in `_meta.kiro.toolId`.
Codex's stream can omit native `spawn_agent` calls; the runner reads native
delegates from the matching root rollout, retaining stream commands for external
launches and excluding child rollouts. Kimchi forwards extension flags to pi:
`--auto` followed by task text consumes that text as a flag value, so the launch
separates the task with `--`. Its scratch `config.json` is mode 600. A Kimchi
`agent_settled` record starts a 30 s exit grace period: a process still alive
afterward is terminated, with that cleanup recorded separately from an
unanswered wall timeout. An answer requires a final assistant message with
`stopReason: stop`.

`python3 packages/delegate-routing/eval/test_suite.py` runs offline regressions
for name collisions, real personal skills, foreign sources, resolved paths, and
CLI event schemas. The structure check runs these tests before rendering dry-run
fixtures.

These cannot be isolated, and are recorded rather than removed: work-account
managed settings (Claude, Codex), organization hooks, steering and MCP servers
(Kiro), and server-side prompt injection (Kiro).

## Operator steps before the first live run

1. Create a Claude token once on the account the suite should use, and store it
   outside the repository: `claude setup-token`, then save the printed token to
   a file such as `~/.config/delegate-suite/claude-token` with mode 600.
2. Check the Kimchi key in `~/.config/kimchi/config.json` belongs to that
   account, and that `codex login status` and `kiro-cli whoami` show it too.
3. `python3 packages/delegate-routing/eval/suite.py --dry-run` and read the
   launches.
4. One trivial run per available harness case to prove the login and the checks:
   `--case codex-single`, `--case kimchi-single`, `--case kiro-single`.
5. The whole suite once. Every case must end `PASS` or `FAIL`.

Open decisions:

- Binaries resolve from `PATH`, not the repository pins (the first smoke ran
  claude 2.1.289, codex 0.160.0, kiro 2.27.1). Decide whether each harness
  defaults to its `ciPackages` pin or warns on a version mismatch.
- Live Kimchi does not exit within 30 s after `agent_settled`; the suite records
  it as cleanup, not ERROR. Offline, a stdio MCP server that `--approve` trusts
  keeps Kimchi alive and the gateway does not
  (`kimchi/claude:x1-print-exit-after-settle`, with a stub server); that the
  fixture's agnix server is the live cause is inferred (rerun live without
  `.mcp.json` to settle). Decide whether `kimchi_setup` sets `plugins.mcp-apps`
  false when MCP is not under test, or the Kimchi fixture drops its stdio
  entries. Whether a connected HTTP MCP server also blocks exit is untested
  (needs network).

Kiro fixtures set the isolated global `chat.enableWorkflows` from the enabled
technique inventory. They never depend on or modify the operator's global
workflow preference. The inventory and rendered skill use the same effective
technique selection; disabled nodes are excluded.

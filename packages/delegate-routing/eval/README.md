# Acceptance suite

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
(including the matching root rollout), Kiro's request records in `chat.log`, and
Kimchi's `agent_start`/`agent_end`. Missing fields read `not exposed`; requested
settings are never substituted for observations.

## Cases

`cases.nix` evaluates this repository's own delivery (`dev/ai.nix`) through the
devenv module harness, with only the case's switches changed, and exports every
delivered file. The prompt is the task plus synthetic usage numbers; the
expected behavior never enters it.

| Cases                                                   | Switch or shape                                        | Assertion      |
| ------------------------------------------------------- | ------------------------------------------------------ | -------------- |
| `claude-clamp-off`, `claude-clamp-on`                   | `ai.claude.delegationClampMitigation.enable`           | `delegate`     |
| `claude-ultracode-drain-off`                            | ultracode on, clamp on, `Pool drain` routing entry off | `observe`      |
| `claude-ultracode-drain-on`                             | ultracode on, clamp on, `Pool drain` routing entry on  | `codex-lane`   |
| `codex-single`, `kimchi-single`, `kiro-single`          | one task                                               | `one-delegate` |
| `codex-dependent`, `kimchi-dependent`, `kiro-dependent` | dependent chain                                        | `workflow`     |

The two Claude pairs are on/off pairs: the switch is the only difference. The
drain cases supply more Codex headroom than Claude headroom.

Assertions read the session's own event log. A delegate call is a tool call
named after a `subagent` or `workflow` technique of the case's runtime, or a
shell command that starts an `external` technique of any runtime (`claude -p`,
`codex exec`, `kimchi -p`, `kiro-cli chat`). The technique names come from the
evaluated `ai.programs.delegate-routing.runtimes.<runtime>.techniques`, the same
table the skill renders. Claude excludes calls made inside a delegate using
`parent_tool_use_id`; child-event exclusion for Codex, Kimchi and Kiro is
unverified until the first live run.

| Assertion      | Passes when the log shows                                   |
| -------------- | ----------------------------------------------------------- |
| `codex-lane`   | an external `codex exec` launch                             |
| `delegate`     | at least one delegate call                                  |
| `observe`      | nothing more: it records the delegates once the run answers |
| `one-delegate` | exactly one subagent or external delegate, and no workflow  |
| `workflow`     | a workflow technique, or at least two delegates             |

Add a case when a real routing problem shows up, not to fill a matrix.

## Running

Run from the repository root. Without `--fixtures` the runner evaluates the
cases with Nix and realizes the generated files they point at.

```bash
eval=packages/delegate-routing/eval/suite.py
python3 "$eval" --dry-run                                  # validate, print every launch, start nothing
python3 "$eval" --case codex-single                        # one case
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

| Harness | Launch                                                                                                                                                                                                          | Login                                                                                                                                                 | Normal-session settings carried over                                                                                 |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Claude  | `claude -p --setting-sources project`, overlay `--settings`, `--model opus --effort medium --permission-mode auto`, scratch `CLAUDE_CONFIG_DIR`, memory, org memory, policy skills and claude.ai connectors off | `CLAUDE_CODE_OAUTH_TOKEN` from a `claude setup-token` token (`--claude-token-file` or the variable). `~/.claude` credentials are never read or copied | `enableWorkflows`, `ultracode`; the fixture's `.mcp.json` servers are enabled; the clamp hook comes from the fixture |
| Codex   | `codex exec --json` with apps, plugins, remote plugins and memories disabled; scratch `CODEX_HOME`                                                                                                              | `auth.json` symlinked, never copied: Codex rewrites it in place, so a refresh reaches the real file                                                   | `default_permissions`, `permissions`, `features`, `agents`; the fixture trusted in the scratch `config.toml`         |
| Kimchi  | `kimchi -p --mode json --approve --auto`                                                                                                                                                                        | `KIMCHI_API_KEY` from `~/.config/kimchi/config.json`, session-only                                                                                    | `harness/settings.json` with the memory extension forced off                                                         |
| Kiro    | `kiro-cli chat --v3 --no-interactive --trust-all-tools --output-format stream-json` through the operator's wrapper                                                                                              | the real data dir (`KIRO_DATA_DIR`), shared, so a refresh lands in the database the operator already uses                                             | `chat.enableCheckpoint`, `chat.enableTangentMode`, `chat.enableWorkflows`                                            |

Vendor-bundled skills and system prompts are kept: they are vendor surface.
Claude and Kiro also get a log-only `PreToolUse` hook that appends each request
to `logs/hook-calls.jsonl` and always exits 0; it is a second record, not
counted. A `claude` binary must resolve inside `/nix/store` (`~/.local/bin`
holds a stale native install); `--bin NAME=PATH` overrides any harness binary.

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

- **Leak:** any personal configuration path under the real home (`~/.claude`,
  `~/.claude.json`, `~/.agents`, `~/.codex`, `~/.kiro`, `~/.config/kiro`,
  `~/.config/kimchi`, `~/.pi`) in any log; or a personal skill, MCP server,
  plugin or agent name that the fixture does not ship in the harness's startup
  record. Claude compares init lists by equality and exempts only delivered path
  components, Markdown/JSON stems and fixture `.mcp.json` server keys. Codex and
  Kiro use prose records: names mentioned anywhere in fixture text are exempt,
  so leaks of those names cannot be detected by the name scan. The personal-path
  scan still runs.
- **Delivery:** Claude's init `skills` list must contain `delegate-routing`.
  Codex and Kiro must include the fixture skill's whitespace-normalized
  frontmatter description in their whitespace-normalized startup record. Missing
  descriptions fail closed as `ERROR`; whether these records carry descriptions
  is unverified until the first live run. Kimchi stays unverified.

| Harness | Startup record                                                                |
| ------- | ----------------------------------------------------------------------------- |
| Claude  | the `system`/`init` stream event                                              |
| Codex   | `codex debug prompt-input` with the same flags, run first (no model call)     |
| Kiro    | `KIRO_CHAT_LOG_FILE` at debug level                                           |
| Kimchi  | none: its JSON stream starts with a session header, so delivery is unverified |

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
4. One trivial run per harness to prove the login and the checks:
   `--case claude-clamp-off --claude-token-file <file>`, then
   `--case codex-single`, `--case kimchi-single`, `--case kiro-single`.
5. The whole suite once. Every case must end `PASS` or `FAIL`.

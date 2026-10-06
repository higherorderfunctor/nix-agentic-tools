# Manual capability probes

Observations describe one runtime, technique and mode in one version/config
context. Run probes from the intended launcher directory. Never infer effective
model/effort from an accepted argument, a nonce or a child self-report. Source
and help evidence must say so. A successful read-only child does not prove
linked-worktree write access. Historical records retain their original dates and
unknown versions.

`run.py` is opt-in, uses only the Python standard library and never runs from a
Nix check. Schema collection is auth-free. Other cases require
`--authenticated`, `--model` and `--effort`; they consume a model turn and use
existing permissions. No trust or permission bypass is added. Output is a new
JSON file, with exact argv, version, date and result metadata; existing files
are refused. Authenticated stdout/stderr are retained beside the output as
`<output>.events.stdout` and `<output>.events.stderr`, operator-held and not for
commit. A timeout kills the process group and leaves the execution result
unknown. Effective controls and native execution stay unknown until an operator
inspects authoritative tool events.

## Automated headless cases

Run `python3 packages/delegate-routing/probes/run.py --help` for the options.
These exact invocations use Codex as an example; choose `--runtime claude`,
`copilot`, `kimchi` or `kiro` to use that runtime's launcher. Replace model and
effort with IDs accepted by the installed runtime. Output paths must be fresh.

```bash
python3 packages/delegate-routing/probes/run.py --runtime codex --case schema --output /tmp/codex-schema-observation.json
python3 packages/delegate-routing/probes/run.py --runtime codex --case child --technique spawn_agent --authenticated --model gpt-6-luna --effort medium --output /tmp/codex-child-observation.json
python3 packages/delegate-routing/probes/run.py --runtime codex --case nested --authenticated --model gpt-6-luna --effort medium --output /tmp/codex-nested-observation.json
python3 packages/delegate-routing/probes/run.py --runtime codex --case workflow --authenticated --model gpt-6.1-sol --effort medium --output /tmp/codex-workflow-observation.json
```

The child case records the named native technique; other cases record the
external launcher. CLI help proves syntax exposure only. Authenticated cases ask
the runtime to use its native tools and forbid writes, commits and account
queries. A missing tool or failed permission is evidence about that exact
context, not all clients. Native claims stay unknown until the publishing rule
below is satisfied. A root's native children and a child's grandchildren are
separate results.

## Probe cases and operator steps

The following cases correspond to the approved design's minimal probe table. CI
cases validate static artifacts; authenticated and interactive cases are manual.
HITL means a person must service permissions or inspect and fill the
observation, rather than treating a model's answer as telemetry.

| Case                                       | Exact replay steps                                                                                                                                                                                                                                                                                                                                                                                     | HITL                                                                                                           |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| Fixture validation and rendering           | Evaluate `nix eval --raw .#checks.x86_64-linux.module-delegate-routing-capabilities.drvPath`; build that individual check. Inspect `nix eval --raw .#delegate-routing-content.skills.claude.text` for the Runs own subagents column; no evidence text belongs there.                                                                                                                                   | No authentication.                                                                                             |
| Module cases                               | List checks with `nix eval --json .#checks.x86_64-linux --apply builtins.attrNames`; select every `module-delegate-routing-*` name and build each individually. These cover named entries, runtime replacement, backend parity and technique evidence.                                                                                                                                                 | No authentication.                                                                                             |
| Usage parsers                              | Inspect the existing usage helpers and their registered checks using `git grep -n 'usage' -- packages/delegate-routing/checks`; run the relevant individual checks on sanitized success, missing-field and error inputs. This change adds no live account query or parser claim.                                                                                                                       | Auth only for a separately requested live usage sample; parser coverage remains unknown where no check exists. |
| CLI help/schema collection                 | Run `run.py --runtime codex --case schema --output /tmp/codex-schema-observation.json` as above. Inspect version and replay commands. Repeat separately for each runtime; retain schema declarations as declarations.                                                                                                                                                                                  | No auth; operator reviews before publishing.                                                                   |
| One native child, then a two-stage task    | Run the child command above. In the same authenticated session request a producer child returning a fresh nonce, then a second child consuming it. Record both tool calls and terminal completion. Compare requested controls with worker metadata, not child prose.                                                                                                                                   | Auth required; interactive permissions and final observation review need a person.                             |
| Child to grandchild and follow-up          | Run the nested command above. Capture the child's actual grandchild tool call and grandchild terminal event. Then send a follow-up to the original child asking for its original nonce without repeating it. Record whether the same child context continued. A two-level success does not establish a maximum depth.                                                                                  | Auth required; final trace review and interactive permissions need a person.                                   |
| One workflow node, then a small dependency | Run the workflow command above. In an interactive session request `agent(prompt, {model: "opus", effort: "medium"})` through Claude Workflow, then a producer/consumer dependency. Inspect resolved worker controls. Separately request an invalid model and effort and record rejection, fallback or clamping and terminal status. Do not equate a `running` return with completion.                  | Auth required; interactive run and pin/error classification need a person.                                     |
| Kiro ACP callback trace                    | Start `kiro-cli acp --agent-engine v3 --auth-method cli` in an ACP client that services permission/auth callbacks. Initialize a session, inspect `_kiro/config/template` and the actual offered tool list, invoke one bounded child, and inspect until terminal completion. Record client identity, gates, callbacks and resolved worker controls. Do not substitute `chat --no-interactive` evidence. | Auth and callback handling; a person responds when the client cannot.                                          |
| Disposable linked-worktree commit          | In a disposable repository outside this project, initialize a base commit, add a linked worktree, and launch the exact runtime there. Ask one delegate to create a nonce file, stage it and commit. Inspect `git show HEAD:<nonce-file>` and common git-dir permissions. Record launcher/config and the actual command events. Never perform this case in the project repository.                      | Explicit local authorization and inspection required; runner never performs commits.                           |

Prefix each individual check build with
`NIX_CONFIG=$'max-jobs = 1\ncores = 2' nix build --no-link .#checks.x86_64-linux.<name>`.
Run one build at a time. These probes never run `nix flake check` or build a
package output.

## Publishing an observation

Every source, context, replay and evidence string must cite public primary
evidence: a repo-relative committed file, a version-pinned public vendor
artifact with a content identity and relative paths/lines, or a command with
fixed output for a pinned public version. Operator-specific paths,
session/worker identifiers, unpublished notes, model self-reports and circular
citations to the technique declaration are not evidence.

To promote a native claim, commit a sanitized extract of terminal tool events
under `fixtures/capabilities/evidence/` and cite its repo-relative path.
Otherwise the claim stays unknown. Before relying on `--json`, confirm the
events file actually contains the child tool call. Whether Codex JSON emits
collaboration items is unknown; its session rollout under `$CODEX_HOME/sessions`
is a possible primary that still needs verification.

Without a publishable primary, retain the claim as unknown with a one-line
evidence note: "Historical report (date, version if known): what was claimed,
including requested/resolved values; raw events not publishable." Set requested
and observed controls to null, moving their historical values into that note,
and keep only re-run steps in replay.

The fixture schema is enforced by `lib/capabilities.nix`. Copy one existing
fixture as a template, then fill runtime/version/date, mode, technique, client
and permission context, source, exact replay, requested controls and observed
controls. Observed values are null unless authoritative metadata records them.
For each capability, keep a result of supported, unsupported or unknown plus the
evidence note. `nestingDepth` also has `value`: the cap the evidence names, else
the deepest level observed; null when unknown. A source limit must identify the
source and say it was not exercised. Commit ability is independent of spawning.

Interactive/HITL steps end with the operator filling a fixture file and
reviewing its sanitized evidence. Add new files with `git add -N <file>` before
flake evaluation, then run `treefmt <file>`. The loader rejects two records for
the same runtime/technique/mode; review and explicitly replace that record when
refreshing it, retaining historical provenance in the evidence note. Consumer
techniques without observations and changed shipped launch contracts render
unknown. A recorded custom identity joins normally. Neither evaluation nor
rendering performs a live refresh.

# Delegate routing package

> **Last verified:** 2026-11-06 — routing ships an always-on "Pool drain" entry,
> the usage helpers share one schema with UTC reset times, portable pools
> resolve usage readers and label family reaches on both backends,
> proxy-accounted-usage reads a Manager+ accounted monthly budget, and the
> always-on stub names the source for steering its rules.
>
> **Settled — do not relitigate.** Per-turn chosen over once-per-session
> (operator, 2026-10-08): accepts cumulative `additionalContext` history growth
> for one stateless hook on every harness, with no marker or PreCompact re-arm.
> Earlier design:
> `git show be765e0e:packages/claude-code/docs/heron-brook-clamp.md`.
>
> **Settled, do not relitigate** (2026-11-03): a budget spent through the proxy
> on an Anthropic API key is accounted by CPA Manager+, never by Anthropic's own
> endpoints. Anthropic's usage, cost and analytics endpoints are Admin API, and
> the Admin API is unavailable for individual Console accounts
> (https://platform.claude.com/docs/en/manage-claude/usage-cost-api and
> https://platform.claude.com/docs/en/manage-claude/usage-cost-analytics-api);
> an org:admin OAuth token and a workspace-less key both fail on such an
> account, and converting it to an organization risks the monthly API credit
> grant. Every other pool reads the provider's own endpoint; this reader is the
> one exception and reports itself as estimated.

`ai.programs.delegate-routing` exposes portable `families`, `pools`, `routing`
and `workflows`. Runtime controls live under `runtimes.<runtime>` for Claude,
Codex, Kimchi and Kiro. Both Home Manager and devenv import `modules/common.nix`
and expose the same surface.

## Named guidance

`routing.<name>` has `enable`, `always`, `before`, `after` and either `text` or
`source`. Names become headings. The package ships the always-on "Load
delegate-routing" stub and five enabled entries: "Follow the user's request",
"Size the work", "Choose execution", "Pool drain" and "Validate the result".
"Pool drain" and "Validate the result" are always-on too. The "Orchestrator
session" catalog entry ships disabled. Policy belongs in these entries rather
than renderer string literals.

`workflows.<name>` has the same fields plus `steps.<name>`. Each step has the
routing entry fields except `always`; the workflow's `always` places its steps.
The package ships one enabled workflow, "Work and review", with the steps
Rubric, Subtractive, Work, Describe, Review and Loop chained by `after`. The
rubric is a saved file, pasted verbatim into the worker's and every reviewer's
brief. Review embeds the checks; they are not separate steps. Add, replace,
disable or reorder a step by key. "Choose execution" and the Review step
reference the Rubric step's Size row; a consumer who disables that step moves or
restates the size rule with it. A workflow can have introductory text or only
steps; an enabled step needs content.

**Breaking migration:** remove overrides of `steps.Prosecute`, `steps.Defend`
and `steps.Judge`, and move their review policy into `steps.Review.text`
(including runtime-specific overrides). Those keys no longer name shipped steps:
setting them creates new consumer steps, and ordering against them no longer
anchors to a shipped step. There are no compatibility aliases.

Entries with `always = true` render through the existing per-runtime `ai.rules`
fan-out. Other entries render in the generated skill. A workflow's `always`
selects the destination for its header and numbered steps together; steps retain
their order within that workflow. The always-on stub tells the agent to load the
skill in each turn that delegates and names the source for steering these rules:
the package's fragments, or for a consumer its `ai.programs.delegate-routing`
routing and workflows entries. When the always-on render is empty, no router
rule is emitted. Keep model tables and harness details in the skill.

Within one scope, named submodules merge by key and package fields use
`mkDefault`. An ordinary consumer definition overrides a shipped field while
retaining its siblings. An explicit `enable = false` wins over content. `text`
uses a non-concatenating string type: different same-priority definitions
conflict. Use `mkForce` only when intentionally resolving such a conflict.
Explicit non-empty `text` and `source` at the same priority conflict.
Higher-priority content wins across those fields, so consumer text can replace a
shipped source and consumer source can replace shipped text.

Portable and runtime maps compose by key. An absent runtime key inherits; a
present runtime entry replaces that portable entry atomically; different keys
add. A disabled runtime entry suppresses the inherited entry. This is separate
from Nix priority merging within one scope. A runtime replacement that needs the
portable wording must supply that wording explicitly; do not copy evaluated
records with internal fields. A runtime workflow record that sets text replaces
the portable header; one that sets no text keeps it. Portable and runtime step
maps compose separately by step name. A runtime step replaces its portable step
atomically; sibling steps remain. Workflow content is required after these step
maps compose: a runtime can enable a catalog workflow without introductory text
or local steps when enabled inherited steps provide content. An enabled workflow
with no effective introductory text or enabled steps fails with a named error.

`before` and `after` name ordering anchors in the same map. Topological sorting
honors both forms among enabled entries. Edges to absent or disabled entries are
ignored; cycles, including self-cycles, fail with the involved names. Ties have
no promised order. Ordering controls prose only, not override priority or
executable first-match routing. Workflow steps have their own ordering map. To
keep a terminal step last when inserting a new step, give the new step a
`before` edge to that terminal step.

Repository runtime and skill ownership is documented in
`dev/fragments/pipeline/generation-architecture.md`.

## Families and runtime capabilities

`families.<vendor>.<family>` is the portable decision table. Each record has a
capability tier, task and effort guidance, an optional orchestration mark
("default orchestrator" or "hard work"), and a required normalized live-model
pattern; an optional `example` names the family's concrete current id, which
launch routes prefer over the pattern. Package fields use `mkDefault`, so
consumers can override a field or add a family. `lib/families.nix` carries the
package families without concrete model versions or Kimchi-served vendors.
Consumers selecting Kimchi models declare the corresponding vendor families in
their delegate-routing configuration.

Each runtime chooses families through `runtimes.<runtime>.models`. Selectors are
alternatives; within a selector every non-empty field must match the vendor,
tier and family name. Claude defaults to Anthropic, Codex to OpenAI, and Kimchi
and Kiro to no selection. Empty selectors fail assertions. Vendor, tier and
family selectors use dynamic enums from configured families; selector tiers
include only used tiers. Family names must be unique across vendors.

An enabled program on an enabled runtime must select at least one family. Its
`extraRuntimes` and `manualExternalDelegates` targets also need a selection.
`extraRuntimes` adds automatic external candidates and requires the target
runtime to be enabled. `manualExternalDelegates` requires an explicit user
request and also requires the target runtime to be enabled. Disabled targets in
either list fail evaluation with a message naming the list and runtime.
Manual-only wins if a target occurs in both lists. Selected families appear once
per tier, each reach naming its harness, the technique that pins both model and
effort, the id spelling it takes and any bound pool.

Resolve concrete models at launch time: inspect the runtime's live list, compare
version segments to find the highest version matching the family pattern, and
use that runtime's spelling. Claude's Agent tool takes aliases such as `opus`;
Workflow `agent()` takes full model ids from configured model-picker rows,
including ids published by the operator's proxy routes.

`runtimes.<runtime>.techniques` is a keyed set of workflow, subagent, external,
introspect and usage nodes. Delegate nodes describe model and effort pinning,
and mode availability; `modelArg` names the model value spelling a delegate
technique passes (such as "full model id", "slug" or "enum alias") and is
required non-empty for techniques that pin model and effort, because family
launch routes compose it with the family's `example` id or `match` pattern. From
another harness only an external technique can launch, so external reaches name
external techniques only. Modes describe usual availability, not session-mode
detection; use only tools present in the current session and external commands
on PATH. Introspection and usage nodes describe how to obtain live evidence.
Usage commands remain part of the existing technique catalog. Each package field
uses `mkDefault`; consumers can override fields, add nodes or disable a node.

`runsOwnSubagents` fills the technique table's "Runs own subagents" column,
which "Choose execution" points readers at. It is a hand-declared string,
`"unknown"` by default; a shipped value names the mode it was seen in, such as
`"supported (headless)"`, and a one-line comment in `lib/techniques.nix` cites
the map row and case id that executed it. Change a value only with a map row
behind it.

Kimchi's Agent tool pins model and thinking. An omitted `thinking` falls back to
the persona default, so pass it explicitly. Kimchi's `/workflow` is a slash
command without a model tool; `dev/ai.nix` configures its interactive resource
for local activation (see `dev/fragments/pipeline/generation-architecture.md`).
External and manual runtime sections include external, introspect and usage
nodes. Kimchi has no usage node because no command reads usage without a model
turn. Shared table rendering escapes cells once.

### Pools

A pool is a budget shared by model reaches. It is not a runtime.
`pools.<name>.description` describes it in the skill's Pools table, before the
family tiers. The drain rule reads this table to find the budgets and readers.

Set `usage.runtime` and `usage.technique` to read a measured pool through an
existing technique. The runtime must be enabled. The technique must be enabled,
have kind `usage`, and have a non-empty command. The table resolves that command
from the technique catalog. Reader metadata follows the reader's runtime even
when it is not a delegate target.

For a budget without a reader, set `window.limit`, `window.unit` and
`window.resetDay`. This declares an allowance per calendar month in UTC, with a
reset day from 1 through 28. Current use stays unknown. A pool needs `usage` or
`window`; both default to null. If both are set, the measured reader takes
precedence. The description defaults to an empty string.

Bind a family through `families.<vendor>.<family>.pools.<runtime> = "<pool>"`.
The key names the target harness that launches the model. Each native, external
or manual reach shows its binding. Several families or harnesses can share one
pool. A null binding means no pool is known for that reach. Unknown pool names
fail evaluation. Two accounts for one family on one harness are out of scope;
route and instance reaches are not represented.

The pool registry and family bindings default to `{}`. A consumer with one
vendor and one harness writes nothing extra. Without pools, the skill text stays
byte-identical. The package does not infer budgets from vendors or add account
names to its defaults.

## Delivery and previews

When an enabled runtime reaches Kiro, as the session runtime or through
`extraRuntimes` or `manualExternalDelegates`, the program changes Kiro's
configuration only as below. Kiro's managed wrapper always launches the v3
engine, which the skill's Kiro evidence covers. Every reached runtime must be
enabled. A consumer without the Kiro module is untouched.

The reach test defaults `cli.tweaks.relativeFileCheckPaths` and
`cli.tweaks.stripVendorWorktreeSteering` to true only when
`cli.workflows.enable` is true and the CLI package is managed. Explicit false
wins.

Kiro's `run_workflow` appears only with `cli.workflows.enable` and no explicit
false for `cli.native.settings.chat.enableWorkflows`. Devenv's null setting
leaves the external global prerequisite to its shell-entry warning. A raw
rollout request alone does not opt into advertising the technique. The effective
rendering view applies this gate even over an explicit technique enable; the
acceptance inventory uses the same helper in `lib/select-families.nix` and
excludes disabled nodes. Workflow modes are interactive, headless and ACP, with
map-case comments beside each Kiro modes value. Introspection has no modes
field.

Kiro takes `trustedMcpTools` only as `permissions.yaml` rules: Home Manager
merges them into `~/.kiro/settings/permissions.yaml` and drops bare tokens such
as `use_aws`, while devenv has no such option: it cannot place the file under
`~/.kiro` and defines no root of its own.

The backend modules pass `"hm"` or `"devenv"` to the common module, which
imports `mkSkillPackageModule` once for the supported runtimes. The factory
checks rule delivery capability on that backend before contributing package
rules. Per-runtime program enable inherits portable enable through the factory's
null-as-inherit rule. Skills and router rules contribute to per-runtime pools,
never the portable pools. Runtime-only controls are not declared at portable
scope. Copilot is excluded from this program.

The Kimchi skill lands in devenv `.kimchi/skills` or Home Manager
`harness/skills`. Project skills take precedence over config paths and harness
skills. Both project-scoped roots load only when Kimchi trusts the project. A
trusted project's `.claude/skills/delegate-routing` can override the Home
Manager harness copy through default config paths.

The always-on routing rule uses the existing native Claude rules and AGENTS.md
delivery for Codex, Kimchi and Kiro. Under Home Manager, Kimchi's copy lands in
its user harness AGENTS.md. Byte-identical contributions deduplicate. The
content package injects packaged usage helper paths into technique defaults. The
helpers share a proxy backend; Codex also needs the consumer's Codex CLI for its
direct read. `zai-usage claude|codex` selects the route whose GLM pool it reads;
consumers attach it to a runtime through that runtime's usage techniques.

Usage helpers print one JSON document per account with `pool`, `account`
(`auth_index`, `name`, `plan`), `windows`, `balances` and `bonuses`. Each window
has `usedPercent`, `remainingPercent`, a UTC RFC 3339 `resetsAt` (null only for
an unstarted window at 0%, which z.ai reports without a reset time), `status`
and `windowSeconds`; names derive from the duration (`5h`, `7d`, otherwise
`<seconds>s`, with `:<model>` for scoped windows); missing windows are absent,
and balances and bonuses are arrays. Codex reset credits carry expiry dates when
available; if the extra proxy request fails, the helper still reports their
count.

### Proxy accounted usage

`proxy-accounted-usage` reads a monthly budget that CPA Manager+ accounts for
one upstream credential, such as an Anthropic API key spent through the proxy.
Manager+ collects the proxy usage queue into SQLite and prices it at read time,
so the reported cost is its priced estimate; the output is the shared usage
schema with one `monthly` window carrying status `"estimated"` and a
`windowSeconds` that is the real calendar length in the configured zone. The
package ships no technique default and no pool for it: a consumer declares the
technique with this command under
`ai.programs.delegate-routing.runtimes.<runtime>.techniques` and a pool whose
`usage` names it.

The command takes `--provider` and `--base-url` for credential discovery through
Manager+ (zero or several matches are errors naming the count), `--auth-index`,
repeatable, to pin indices through key rotation, `--limit` (a finite positive
USD amount; Manager+ prices in USD only), `--reset-day` (1 through 28) and
`--time-zone` (an IANA name, UTC by default) for the calendar window, `--pool`
and `--account-name` for the output, and `--now-ms` to fix the clock for replay
and tests. `MANAGER_URL` and `MANAGER_KEY_FILE` carry the Manager+ endpoint and
its admin key file; the key is read in process and sent through curl `--config`
on stdin, never through argv. The reader fails when the collector is not
running, when discovery matches zero or several credentials, when the analytics
response is invalid (`model_stats` may be empty only when the summary reports
zero calls), when its coverage reports deleted raw events or a degraded summary,
or when an analytics model row reports tokens with zero cost: Manager+ prices a
row through its billing or pricing model and leaves one it cannot price at zero,
and coverage is judged from those analytics rows, not a price book. Calls that
used no tokens cost nothing legitimately. A display model that merges a priced
and an unpriced billing model shows a positive total and is not detected; that
is the limit of the estimate, which is why the window's status is `estimated`.

A consumer example with placeholder values:

```nix
{
  ai.programs.delegate-routing = {
    pools.anthropic-api = {
      description = "Monthly USD budget on the Anthropic API key, accounted by Manager+";
      usage = {
        runtime = "codex";
        technique = "proxy-accounted-usage";
      };
    };
    runtimes.codex.techniques.proxy-accounted-usage = {
      command = "<proxy-accounted-usage path> --provider claude --base-url https://api.anthropic.com --limit 100 --reset-day 1 --time-zone UTC --pool anthropic-api --account-name personal-anthropic-api";
      kind = "usage";
      notes = "Manager+ accounted budget; MANAGER_URL and MANAGER_KEY_FILE carry the endpoint and admin key file";
    };
  };
  ai.codex.environmentVariables = {
    MANAGER_KEY_FILE = "/run/secrets/manager-admin-key";
    MANAGER_URL = "http://127.0.0.1:18317";
  };
}
```

The `<proxy-accounted-usage path>` placeholder is the packaged script, the
`usageScripts.proxy-accounted-usage` passthru of the `delegate-routing-content`
package.

Usage follows generic `ai.<runtime>.settings.inference` selection. A selected
local instance with a file management-key reference supplies metadata
automatically. With no proxy or no management metadata, helpers use their direct
login or `ZAI_API_KEY_FILE`. Once metadata is supplied, missing accounts,
ambiguous z.ai keys, malformed responses and request failures are errors; stale
local logins are not consulted. The backend never drains the usage queue. z.ai
discovery reads secret-bearing configuration in memory, matches hostname
`api.z.ai` and requires one distinct key across both supported transports.

When a host manages the proxy and a project delivers routing, add the matching
runtime pairs in `devenv.local.nix` (use `ai.codex.environmentVariables` for
Codex's pair):

```nix
{
  ai.claude.native.settings.env = {
    DELEGATE_USAGE_CPA_CLAUDE_MANAGEMENT_KEY_FILE = "/run/secrets/proxy-management";
    DELEGATE_USAGE_CPA_CLAUDE_URL = "http://127.0.0.1:9000";
  };
}
```

`mkSkill`, `render` and `skills` consume the same family, pool, selector,
technique and named-entry inputs. Generated skill trees use `lib.ai.generated`
and the shared Markdown formatter; previews read the built files. Package
discovery supplies content, both backend modules and checks.

Run these from the repository root to print skills without launching delegates:

```bash
nix eval --raw .#delegate-routing-content.skills.claude.text
nix eval --raw .#delegate-routing-content.skills.codex.text
nix eval --raw .#delegate-routing-content.render --apply 'render: render { runtime = "kiro"; models.kiro = [{vendors = ["anthropic"];}]; }'
nix eval --raw .#delegate-routing-content.render --apply 'render: render { runtime = "claude"; extraRuntimes = ["codex"]; manualExternalDelegates = ["kiro"]; models.claude = [{vendors = ["anthropic"];}]; models.codex = [{vendors = ["openai"];}]; models.kiro = [{vendors = ["anthropic"];}]; }'
```

## Per-turn reminder

The default wording is Claude's user-voiced grant against the heron_brook clamp.
Before changing it, read `packages/claude-code/docs/heron-brook-clamp.md`.
Consumer delivery and enable controls are documented in the `reminder` option;
the hook pools own conflict diagnostics.

Kiro workflow step sessions skip the reminder so a delegated step does not
receive another invitation to delegate (measured on kiro-cli 2.31.1 with
`--v3`). The hook reads its session ID from stdin and checks the session's
`_meta.kiro.workflow` object under `$HOME/.kiro/sessions`; the engine uses
`HOME`, independently of the client's `KIRO_HOME` (see
`fixtures/kiro-primitives/carried-negatives.md`, C-1). Root sessions retain the
exact reminder; missing or unreadable session data fails open to that same
output.

## Acceptance suite

`eval/` is the acceptance suite: one manual suite of real sessions on Claude,
Codex, Kiro and Kimchi that checks what the delivered configuration makes an
agent do with a real task. `eval/cases.nix` evaluates the repository delivery
configuration with explicit acceptance-suite runtime and delegate-routing
settings, then applies each case's switches. It exports every delivered file
plus the evaluated delegate technique names. `eval/suite.py` is the single
runner: it renders each case into a fresh fixture repository, runs one session
under a scratch `HOME` that keeps only the login and carried-over settings; the
Kiro fixture writes the global workflow setting from its effective technique
inventory without changing the operator's home. It hides config from the loader,
not files from the model. It caps the session and asserts on the session's own
event log. Root model and effort come from the single `ROOT_BASELINES` table at
the operator’s strong-tier medium; Codex model/effort and Kiro default model are
not copied. Claude debug scope counts attribute bundled skills without a name
allowlist; Codex resolves catalog paths, and Kiro reads workspace skill source
metadata from CLI stream updates. Kimchi separates extension flags from the task
with `--`. Kiro resolves the newest matching Opus model only for live runs.
Results record requested controls separately from root event/log observations,
with `not exposed` for missing fields. Harness differences live in its
`HARNESSES` table; assertions in its `ASSERTIONS` table.

A delegate call is classified by technique name, so the suite and the rendered
skill read one table. Same-runtime nested children ARE logged in and can run and
spend inside the 600 s process-group cap; no PATH shim blocks them. Results are
`PASS`, `FAIL` or `ERROR`; only `ERROR` (no answer, a leak, or the routing skill
missing from the startup record) fails the run.

The owner check `delegate-routing-eval-structure` runs the suite's `--dry-run`
in the sandbox: it validates every case and renders every fixture and launch
plan with no harness and no login. Its `cases` passthru is the runner's fixture
export. It also runs the offline source-attribution and event-schema regressions
in `eval/test_suite.py`. No check starts a session. See `eval/README.md` for
reminder comparisons, the isolation recipe, the caps and the operator steps.

## Delegate map

`docs/delegates/evidence.md` owns pins, evidence marks and capture methods. The
other reference files own tools, controls, lifecycle and prompt reach.
`probes/delegates/<harness>/README.md` indexes exact case commands and expected
excerpts; `probes/delegates/run.py --only=<id|glob>` re-runs those rows, exits
with the MISMATCH count, and exits 2 when `--only` matches nothing. Captured
execution and source-only evidence stay separate. Probes write beneath a
temporary case tree. Kiro creates a fake fixture login from schema and native
type strings when no fixture home is supplied; both replay runners stay in an
empty network namespace with local service endpoints. Its a2/h2/h3 and
codex-side inline fixtures share bases and a generator with byte comparisons for
every case path.

The repo-only `delegate-evidence` dev skill (`dev/skills/delegate-evidence/`)
sends agents to the map and the suite before they state harness behavior or
debug the skill.

Kiro map results describe only the current flake pin. Its v2 replay cases remain
marked "v2 engine (not used by this config)"; skill capability citations use v3
cases. The headless nested capture shares its rules with the ACP nested case
through `rulesFrom`; AST selectors fail on a missing match. Kimchi replays use
the flake pin only; native VM tool exclusions come from that source, and
inventory stdin resolves before entering the scratch project. RPC/ACP scenario
deadlines are cleanup; the wire and tool results establish the behavior.
Workflow cancel/abort fixtures wait for an active provider request, and the
abort fixture waits 10 s before its status check. The Kimchi prompt map is
replayed by the `claude:sp-*` cases.

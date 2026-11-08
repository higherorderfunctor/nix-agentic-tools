# Delegate routing package

> **Last verified:** 2026-11-07 — the renderer consumes the private shared
> routing view for launch reaches and registered readers; the packaged
> non-launching helper consumes the same view and runtime sessionPool binding,
> rejects incomplete Reader envelopes, and keeps runtime-specific commands in
> skills so shared router rules remain byte-identical; routing ships an
> always-on "Pool drain" entry and a "Tune these rules" entry, the Review step
> holds the one review rule, the Work and review workflow builds a branch as
> units each reviewed by one check before the next starts (all three checks at
> the branch-level review when the PR goes ready), the usage helpers share one
> schema with UTC reset times, portable pools resolve usage readers and label
> family reaches on both backends, proxy-accounted-usage reads a Manager+
> accounted monthly budget, and the always-on stub names the source for steering
> its rules; OpenCode Go joins z.ai as an API-key pool found by base URL, with
> opt-in Go preset families.
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
delegate-routing" stub and seven enabled entries: "Follow the user's request",
"Size the work", "Choose execution", "Pool drain", "Validate the result",
"Orchestrator session" and "Tune these rules". "Pool drain", "Validate the
result" and "Orchestrator session" are always-on too. "Orchestrator session"
ships enabled; disable it with `routing."Orchestrator session".enable = false`.
Its first paragraph is the short user-voiced request shared by the rule and
per-turn reminder. Sweeps use a workflow where available, otherwise native
subagents. Keep the details in later paragraphs. Policy belongs in these entries
rather than renderer string literals.

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

## Skill text

The renderer holds no skill prose, only table and list glue and diagnostics.
Every heading and sentence is an entry, a column or a phrase under `skill`, at
`ai.programs.delegate-routing.skill` and at `runtimes.<runtime>.skill`. A
runtime key replaces the portable key atomically.

`skill.entries` is the ordered body: Routing, Common workflows, Delegate sizing,
Pools, Family tables, Technique availability, Technique tables and Manual-only
external delegates. Entry text may use `{routing}`, `{workflows}`, `{pools}`,
`{families}`, `{techniques}` and `{manual}`, each filled with its generated
block. An entry whose placeholder block renders nothing, such as Pools with no
pools declared, is omitted.

`skill.columns.<families|pools|techniques>` set header text, order and presence
keyed by column. A disabled column drops its header and cells; an enabled key
the renderer has no cell for fails naming it. The techniques Command column
still appears only when a delegate technique has a command. The families Pool
column stays between Effort (delegate) and Launch even without pooled families;
its cells are empty when a family has no pool guidance.

`skill.phrases` are templates used inside generated blocks: `"Native reach"` and
`"External reach"` (`{harness}`, `{launch}`, `{pool}`), `"Launch route"`
(`{technique}`, `{modelArg}`, `{model}`), `"Model pattern"` (`{match}`),
`"Pool binding"` and `"Manual pool hint"` (`{pool}`), `"Pool window"`
(`{limit}`, `{unit}`, `{resetDay}`), `"Family table heading"` (`{tier}`),
`"Technique table heading"` and `"Manual delegate heading"` (`{harness}`).
`"Launch fallback"`, `"Manual delegate note"`, `"OpenCode Go note"`,
`"Pool measured"`, `"Pool unmeasured"` and `"Pool reader missing"` take none. A
disabled phrase renders nothing; a phrase the renderer reads but cannot find
fails naming it. The families block emits "OpenCode Go note" after the family
tables only when a Go family renders. Disabling the Family tables entry also
drops that note.

Shipped entries and columns carry `after` edges to every predecessor, so
disabling any one keeps the rest in order. For example, this replaces one
paragraph and drops one column:

```nix
ai.programs.delegate-routing.skill = {
  columns.families.Orchestration.enable = false;
  entries."Technique availability".text = "Check your tool list first.";
};
```

The public `mkSkill` builder of the `delegate-routing-content` package is
overridable. Its `override` receives the shipped inputs, so a direct caller
edits the skill text from `prev.skill`:

```nix
(content.mkSkill {runtime = "claude";}).override (prev: {
  skill = lib.recursiveUpdate prev.skill {phrases."Launch fallback".text = ", or ";};
})
```

## Families and runtime capabilities

`families.<vendor>.<family>` is the portable decision table. Each record has a
capability tier, task and effort guidance, an optional orchestration mark
("default orchestrator" or "reserved for hard work"), and a required normalized
live-model pattern; an optional per-target `example`, shaped like `pools`, names
the family's concrete current id for one harness, and that harness's launch
route shows it instead of the pattern. Package fields use `mkDefault`, so
consumers can override a field or add a family. `lib/families.nix` carries the
package families without concrete model versions or Kimchi-served vendors, so a
launch route without a generated agent file instructs the reader to take the
highest id matching the pattern. Consumers selecting Kimchi models declare the
corresponding vendor families in their delegate-routing configuration.

`lib/opencode-go.nix` adds `opencode-go` preset families for the OpenCode Go
catalog that CPA's `opencode-go` vendor serves; ids the vendor refuses
(`vendors.opencode-go.refuses`, the ids the operator's other credentials serve)
get no preset. They come from per-model research, and every tier is provisional:
whenever an `opencode-go` family renders, one line under the tables says so.
Each family is named `go-` plus the exact Go id, except
`go-muse-spark-contributor` (Muse Spark 1.2 and 1.3), which the research found
share a role. The `go-` prefix keeps them apart from hand-written families such
as `kimi-k3`. Presets render only when a runtime selects them, for example
`models = [{vendors = ["opencode-go"];}]`; a tier-only selector picks them up
like any other vendor's. Setting `opencodeGo.plan` fills each preset's `pool`
field from the plan's documented monthly limit in the cliproxyapi `opencodeGo`
fact: the list-price dollars that empty the account's monthly pool, so a lower
limit weighs more. The skill always shows a Pool column, empty when a family has
no pool text, alongside each reach’s registered pool label. Set
`opencodeGo.pool = "<pool>"` to bind every generated preset to that registered
pool on each runtime that selects the `opencode-go` vendor. If one runtime
selects a preset and another family of any vendor, a custom `opencode-go` one
included, that match the same servable Go catalog id, such as a hand-written
`deepseek-v*-flash*` beside `go-deepseek-v4.1-flash`, evaluation fails and names
the id and the families. Selecting them on different runtimes is allowed, and
families that overlap with no preset selected are not checked. The
`delegate-routing-opencode-go-presets` check fails when a servable catalog id
matches no preset or several, or a preset matches no catalog id.

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
use that runtime's spelling. Claude's Agent tool names a generated agent file
through `subagent_type` to pin a full id; plain calls without a file take
aliases such as `opus`. Workflow `agent()` takes full model ids from configured
model-picker rows, including ids published by the operator's proxy routes.

`runtimes.<runtime>.techniques` is a keyed set of workflow, subagent, external,
introspect and usage nodes. Delegate nodes describe model and effort pinning,
and mode availability; `modelArg` names the model value spelling a delegate
technique passes (such as "full model id", "slug" or "modelId"), composed with
the family's `example` id or `match` pattern. The renderer refuses, at
composition, a technique that pins model and effort but names no spelling, and a
reach into a harness with no enabled technique pinning model and effort (from
another harness, only an external one counts), so both the module and the public
`mkSkill` helper enforce it; every enabled technique that pins model and effort
is listed in kind order (subagent, workflow, external) as fallbacks when its
family resolves the file that technique needs; each must name a spelling, and
disabled techniques are not listed or refused. The exception is
`launchRoute = false`: a technique that pins only model aliases, such as
Claude's plain `Agent` call without a generated file, is neither listed nor
refused. From another harness only an external technique can launch, so external
reaches name external techniques only. Modes describe usual availability, not
session-mode detection; use only tools present in the current session and
external commands on PATH. Introspection and usage nodes describe how to obtain
live evidence. Usage commands remain part of the existing technique catalog.
Each package field uses `mkDefault`; consumers can override fields, add nodes or
disable a node.

The private `lib/routing-view.nix` owns automatic and manual reach selection,
eligible technique ordering, concrete model ids versus unresolved patterns,
generated agent availability and pool bindings. `lib/render.nix` consumes those
records for Launch cells and the Pools table; it keeps skill phrases and table
formatting. The view reuses `select-families.nix` and takes the module's
effective techniques, including the Kiro workflow gate, and its already resolved
Claude agent records so proxy picker ids and family default effort remain
available. Direct builders retain catalog resolution when no resolved agent set
is supplied. Its reader inventory resolves every registered pool independently
of launch targets, including readers whose runtime is absent from both automatic
and manual reaches. Manual reaches stay separate from automatic candidates; this
view is private implementation data, not a public manifest or option.

### Generated Claude agent files

The common module writes `ai.claude.agents.<family>` at `mkDefault` priority;
the runtime delivers `.claude/agents/<family>.md` on both Home Manager and
devenv. Ordinary consumer agent entries override these files. The filename and
frontmatter `name` are the family name, unique across vendors.

For families selected by `runtimes.claude.models`, `example.claude` wins;
otherwise the highest matching id comes from Claude's extracted catalog plus the
configured inference lowering's published picker rows. Version segments compare
numerically. An unresolved family gets no file and skips the generated agent
technique in its Launch route. Files and routes share the resolved set.

`families.<vendor>.<family>.defaultEffort` is nullable, typed against Claude's
extracted effort enum, and defaults to null (no `effort:` line). Package
`mkDefault`s set medium for fable, opus and sonnet; haiku keeps null. A launch
call's effort overrides the file's default. The shared frontmatter renderer
writes the pins and a fixed delegate body.

There is no separate file enable option. Set
`runtimes.claude.techniques."Agent with generated agent file".enable = false` to
withhold both files and the route. The effective technique is also disabled when
the Claude runtime or its delegate-routing program is off.

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
vendor and one harness writes nothing extra. Without pools, the family tables
still render an empty Pool column. The package does not infer budgets from
vendors or add account names to its defaults.

### Deterministic routing helper

Each generated skill names its literal runtime, session pool and absolute
packaged `delegate-routing-plan` executable. The always-on router stays
runtime-neutral so contributions to shared AGENTS.md targets are byte-identical.
The wrapper binds the manifest and Bash store paths; no PATH installation is
needed. `mkSkill` and `render`, including overrides, use the same builder as
both module backends. The manifest serializes `lib/routing-view.nix` directly,
including automatic runtime inventory, registered readers, manual-only routes,
technique guidance and full resolved generated-agent records. It never
re-derives reach selection in Python.

Set `runtimes.<runtime>.sessionPool` to the registered budget actually spent by
that session. For registered keys `claude` and `codex`, the migration is
`runtimes.claude.sessionPool = "claude";` and
`runtimes.codex.sessionPool = "codex";`. Bind Kimchi, Kiro and proxied runtimes
to their actual configured keys. Descriptions are neutral budget descriptions,
not session identity data. The default is null: the module warns and the helper
cannot certify the buffer. Unknown keys fail option/manifest validation. No
pools preserves fit-only operation with explicit budget/session uncertainty.

Invoke the rendered command with `--role writer --launch-context <json-path>`
(repeat `--role` to share one snapshot). Supported roles are writer,
investigator, mechanical, finder, first-check, second-check and judge. The last
four require strong/frontier tiers before ranking; an empty qualified set exits
nonzero with “never step down a tier; report a loop failure.” The helper
certifies tier and pace, not semantic fit, trial eligibility or maker
independence. Provider-vendor identity remains provisional for aggregator
independence until explicit maker data exists.

The caller supplies observed availability, one concrete model id per technique
evidence record and supported effort values, plus requested effort and qualified
family evidence per role. For example, for a configured `sol` route:

```json
{
  "nonInteractive": false,
  "roles": {
    "writer": {
      "effort": "high",
      "families": {
        "sol": {
          "avoidFor": "task avoids sole grading",
          "fit": "bounded implementation against this spec",
          "trial": "not a trial",
          "useFor": "coding with executable acceptance checks"
        }
      }
    }
  },
  "techniques": [
    {
      "efforts": ["high"],
      "model": "gpt-6.1-sol",
      "runtime": "codex",
      "technique": "spawn_agent"
    }
  ]
}
```

A generated Claude agent supplies its resolved id and structured default effort
when no effort is requested. Unresolved model patterns, ambiguous concrete
evidence and unsupported efforts cannot produce certified lines. The first
eligible caller-observed technique wins; the JSON retains eligible named
alternatives and invocation/argument guidance, including generated agent
records. Manual-only routes remain separately labelled. Canonical lines such as
`role=writer runtime=codex family=sol technique=spawn_agent model=gpt-6.1-sol effort=high`
are specifications, not shell commands. The launching orchestrator binds
task/prompt/output paths and calls native tools natively. Explicit headless
status excludes external delegates; unknown status reports that condition
unresolved. No TTY inference, catalog command, live probe or delegate launch
occurs.

The helper runs every registered Reader once on one UTC snapshot, including
Readers owned by runtimes outside automatic targets; identical commands share
one read. Only that inventory can reach subprocess execution. Trusted configured
shell commands run under full strict Bash mode with a ten-second timeout that
kills the reader process group. Failed, malformed, partial, multi-account,
expired, missing-duration, unstarted-null-reset and model-scoped streams are
unmeasured with reasons; no account routing or missing resets are invented. The
shared schema is required before pace arithmetic: `account` contains
`auth_index`, `name` and `plan` (including null values), `pool` is a nonempty
string, `balances` and `bonuses` are arrays, each window's `status` is a string
or null, and each `resetsAt` is a UTC timestamp or null. Missing fields or wrong
shapes make the whole stream unmeasured. Registration keys determine budget
identity, never reader `.pool` output.

Each measured pool uses the minimum window pace
`(remainingPercent / 100) / ((resetsAt - now) / windowSeconds)` and the minimum
remaining share as its buffer. Reported calendar-month durations remain intact.
Higher pace sorts first, with deterministic family/runtime ties; an eligible
session pool wins an equal-pace tie only above the strict 20% buffer. A measured
session may be selected only if every other fitting measured pool is behind or
level. Exhaustion stays measured and never becomes a fit-only fallback.
Unmeasured candidates are excluded while fitted measured candidates exist; with
none, output explicitly states fit-only budget/session uncertainty. JSON is
printed to stdout and concise launch specifications to stderr. `--now` fixes the
clock for offline tests.

`checks/routing-plan-runtime.py scripts/delegate-routing-plan.py` exercises fake
Readers and hand-written expectations, including a subprocess spy that rejects
any candidate/probe launch. CI exposes it as `delegate-routing-plan-runtime`.
Eight backend/runtime delivery fixtures and mode-detection evidence belong to
the module/policy checks; offline helper tests do not establish live harness
compliance.

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
direct read. `zai-usage claude|codex` and `opencode-usage claude|codex` select
the route whose GLM or OpenCode Go pool they read; consumers attach them to a
runtime through that runtime's usage techniques. `opencode-usage` reads the
undocumented `GET https://opencode.ai/zen/go/v1/usage`, the request OpenCode's
open-source client makes, and prints Go's `rolling`, `weekly` and `monthly`
windows through the shared schema with UTC reset times.

Usage helpers print one JSON document per account with `pool`, `account`
(`auth_index`, `name`, `plan`), `windows`, `balances` and `bonuses`. Each window
has `usedPercent`, `remainingPercent`, a UTC RFC 3339 `resetsAt` (null only for
an unstarted window at 0%, which z.ai reports without a reset time), `status`
and `windowSeconds`; names derive from the duration (`5h`, `7d`, `monthly` for
28–31 days, otherwise `<seconds>s`, with `:<model>` for scoped windows); missing
windows are absent, and balances and bonuses are arrays. Codex reset credits
carry expiry dates when available; if the extra proxy request fails, the helper
still reports their count.

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
login, `ZAI_API_KEY_FILE` or `OPENCODE_API_KEY_FILE`. Once metadata is supplied,
missing accounts, ambiguous API keys, malformed responses and request failures
are errors; stale local logins are not consulted. The backend never drains the
usage queue. API-key discovery reads secret-bearing configuration in memory
across the claude, codex and openai-compatibility transports and requires one
distinct key. z.ai matches hostname `api.z.ai`; OpenCode Go matches hostname
`opencode.ai` under base path `/inference/go`, so it finds the key whichever
native API a credential declares and ignores other OpenCode surfaces.

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

The base wording is Claude's user-voiced standing request against the
heron_brook clamp; it grants delegation and states the default for bulk work.
Before changing it, read `packages/claude-code/docs/heron-brook-clamp.md`.

For each runtime, the hook appends the first paragraph of its effective
`routing."Orchestrator session"` entry, joining wrapped lines with spaces. The
entry's existing `enable`, `text` and `source` fields control the added line;
runtime entry replacement applies before reading them. Disabling that entry
leaves the base request byte-identical, without an extra newline.

`reminder.text` or `reminder.source` replaces the base request; the enabled
orchestrator entry still appends its line. Consumers wanting only their custom
reminder also disable that entry. `reminder.enable` and
`runtimes.<runtime>.reminder.enable` still withhold the whole hook. No second
reminder wording or new option is declared. The hook pools own conflict
diagnostics.

Codex's delegation behavior under the reminder is unmeasured, including whether
it has a delegation clamp. Run
`python3 packages/delegate-routing/eval/suite.py --only='codex-reminder-*'` and
inspect both verdicts, root logs and actual prompt/hook payload to measure it;
behavioral non-regression remains unknown until those cases run. Preserving the
grant is not evidence of their outcome.

Kiro workflow step sessions skip the reminder so a delegated step does not
receive another invitation to delegate (measured on kiro-cli 2.31.1 with
`--v3`). The hook reads its session ID from stdin and checks the session's
`_meta.kiro.workflow` object under `$HOME/.kiro/sessions`; the engine uses
`HOME`, independently of the client's `KIRO_HOME` (see
`fixtures/kiro-primitives/carried-negatives.md`, C-1). Root sessions retain the
exact reminder; missing or unreadable session data fails open to that same
output.

Headless delivery: `claude -p` receives the reminder (see
`docs/delegates/system-prompt.md`, hook `additionalContext`); Kiro workflow
steps skip it and a Kiro headless root receives it (see `lib/reminder.nix` and
`checks/reminder-runtime.nix`). Receipt by `codex exec` and `kimchi -p` is
unmeasured.

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

Probe results, history and replay evidence live in the map and the probes. They
never appear in rendered skill text or in comments beyond a one-line citation.

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

## Workflow resume directories

When Claude's effective Workflow technique and source runtime are enabled,
delegate-routing contributes `~/.claude/projects` to
`ai.claude.native.settings.permissions.additionalDirectories`. This is a plain
list definition: consumer plain lists concatenate with it; `lib.mkForce`
replaces the whole list to opt out. Home Manager delivers user settings; devenv
delivers project settings through the same native option.

On devenv, with a managed Claude package, it also contributes that directory to
`ai.claude.untrustedProjectAdditionalDirectories`. The launcher silently adds
`--add-dir` for an untrusted launch directory, and a SessionStart hook returns a
transcript-only `systemMessage` describing the fallback. Consumer SessionStart
entries concatenate with this hook. Home Manager intentionally has neither this
option nor this hook: user settings already deliver the same access
independently of project trust. A null package suppresses the launcher
contribution and notice; the settings contribution remains.

Pass `args` again on Workflow resume (anthropics/claude-code#103657), and keep
the working directory fixed for a run (anthropics/claude-code#99517).

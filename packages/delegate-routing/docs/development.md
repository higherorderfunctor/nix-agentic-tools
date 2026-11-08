# Delegate routing package

> **Last verified:** 2026-11-08 — all four runtimes on Home Manager and devenv
> receive an orchestrator `SKILL.md` plus planner/worker `PLANNER.md`; the
> companion is built first and read through an explicit absolute store path.
> Orchestrator duties reach the router or small skill before launch; shared
> policy uses the same resolved sources, preserves custom entries,
> disables/runtime replacement and direct builder overrides, and supplies worker
> policy to prepared briefs. Every reviewer launch has a planner-prepared base
> brief before validation; the orchestrator adds neutral earlier-check inputs at
> launch. Runtime-neutral routers retain the exact Orchestrator first paragraph;
> reminder/grant and existing hook exclusions are unchanged. Plan/check-plan and
> the deterministic helper retain their runtime/session-pool, Reader, tier/pace
> and verbatim-rubric contracts. Offline checks establish artifact delivery and
> validation, not live agent compliance. Opt-in helper-backed acceptance cases
> preserve fake-Reader receipts separately from session observations; no harness
> compliance is inferred from dry-run.
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
"Orchestrator session" and "Tune these rules". Only "Load delegate-routing" and
"Orchestrator session" are always-on by default; Pool drain and Validate the
result reach both the small skill and planner companion. "Orchestrator session"
ships enabled; disable it with `routing."Orchestrator session".enable = false`.
Its first paragraph is the short user-voiced request shared by the rule and
per-turn reminder. Sweeps use a workflow where available, otherwise native
subagents. Its later handoff paragraphs stay in the always-on Orchestrator
session entry, where the interactive session receives them before launching a
planner. Policy belongs in named entries rather than renderer string literals.

`workflows.<name>` has the same fields plus `steps.<name>`. Each step has the
routing entry fields except `always`; the workflow's `always` places its steps.
The package ships one enabled workflow, "Work and review", with the steps
Rubric, Subtractive, Plan, Work, Describe, Review and Loop chained by `after`.
Rubric preparation is preflight from the task goal; it does not authorize
task-source investigation before the planner. Plan uses the helper's
strong/frontier planner candidates before substantive source work, except for a
worker already assigned an approved bounded unit. It saves one plan and prepared
briefs, then checks them before launch with `--check-plan`. The rubric is a
saved file, pasted verbatim into the worker's and every reviewer's brief. Review
embeds the checks; they are not separate steps. Add, replace, disable or reorder
a step by key. The Plan and Review steps reference the Rubric step's Size row; a
consumer who disables that step moves or restates the size rule with it. A
workflow can have introductory text or only steps; an enabled step needs
content.

**Breaking migration:** remove overrides of `steps.Prosecute`, `steps.Defend`
and `steps.Judge`, and move their review policy into `steps.Review.text`
(including runtime-specific overrides). Those keys no longer name shipped steps:
setting them creates new consumer steps, and ordering against them no longer
anchors to a shipped step. There are no compatibility aliases.

Entries with `always = true` render through the existing per-runtime `ai.rules`
fan-out. The two shipped router entries address the orchestrator and are
excluded from the planner context. Other enabled routing entries and workflows,
including custom always-on entries, remain in `PLANNER.md`; non-always routing
entries also reach `SKILL.md`. A workflow's `always` controls its additional
rule placement; steps retain their order. The small router loads the runtime
skill on every delegating turn and carries handoff and substantive
source-steering rules: propose delegation-policy changes to package fragments or
consumer routing/workflow entries, never rendered files, memory or house rules.
It contains no runtime helper path, so shared AGENTS.md contributions remain
byte-identical. When the always-on render is empty, no router rule is emitted.
Full review execution policy and family/technique tables belong to the planner
reference; rubric preflight reaches the orchestrator too.

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

The skill tree contains `SKILL.md` and `PLANNER.md`. An audience table projects
Plan and launch only to the orchestrator, Routing and Routing helper to both
readers, and Common workflows as Rubric/Subtractive preflight plus Work,
Describe and Loop execution duties in the small skill or the full workflow in
the companion. The manual-only delegate table reaches both readers so the
orchestrator can honor an explicit user request. All other skill entries,
including consumer additions, belong to the planner. Each policy paragraph has
one authoritative source, even when both readers need its projection. The small
skill includes substantive-work bootstrap, family fit/route guidance, helper
command/schema, wave validation, launch supervision, source customization and
result evidence, review orchestration, diagnosis validation and ready-report
requirements. Automatic family/technique tables and the detailed reviewer checks
stay in the companion.

The planner must read its absolute companion path before planning. The
orchestrator passes prepared brief paths without loading the heavy reference for
every delegate. Worker/reviewer briefs carry their full rubric verbatim and
relevant execution policy; there is no extra plan-constraints channel or
unchecked JSON field.

`PLANNER.md` contains planner/worker routing, full workflow and tables,
including enabled custom entries. The shipped Orchestrator session and Load
delegate-routing entries stay with the orchestrator, so the planner can read
task source without being told to hand it off. Companion content is formatted in
a separate derivation first, then copied byte-identically into the skill tree;
the entrypoint references that first derivation, never its own output. Kiro and
other runtimes need no implicit sibling loading, Skill args or on-load hook.

The renderer holds no skill prose, only table and list glue and diagnostics.
Every heading and sentence is an entry, a column or a phrase under `skill`, at
`ai.programs.delegate-routing.skill` and at `runtimes.<runtime>.skill`. A
runtime key replaces the portable key atomically.

`skill.entries` is the ordered projection source: Plan and launch, Routing,
Common workflows, Delegate sizing, Routing helper, Pools, Family tables,
Technique availability, Technique tables and Manual-only external delegates.
Entry text may use `{routing}`, `{workflows}`, `{pools}`, `{families}`,
`{techniques}`, `{manual}`, `{helper}`, `{planner}` and `{bootstrap}`, each
filled with its generated block. An entry whose placeholder block renders
nothing, such as Pools with no pools declared, is omitted. `{planner}` is the
absolute companion path; `{bootstrap}` is compact fit/route guidance for
configured strong/frontier families, not certification of planner fit. With no
such family it explicitly reports a loop failure. Override or disable entries by
their names; custom skill entries are preserved in the companion.

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
`"Planner candidate"` takes `{family}`, `{useFor}`, `{avoidFor}`, `{effort}` and
`{routes}`. `"Planner unavailable"` supplies the no-planner diagnostic.
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
edits either projection from `prev.skill`. `render` and `.text` return the small
entrypoint; `mkSkill` emits both files; direct callers read
`"${skill}/PLANNER.md"` for companion text. No legacy large-entrypoint shim
remains:

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
pool on each runtime that selects the `opencode-go` vendor. Setting
`opencodeGo.plan` alone does not bind a pool. When a plan is set without
`opencodeGo.pool`, the module refuses evaluation: the Go preset families would
have no pool and rank on fit only. Set it to a registered pool key, for example
`"opencode-go"`; an unregistered key also fails evaluation. Hand-written family
`pools` bindings do not replace this requirement. There is no option to
deliberately leave Go presets without a pool while setting a plan. With
`opencodeGo.plan = null`, fit-only routing without a pool binding remains
supported. If one runtime selects a preset and another family of any vendor, a
custom `opencode-go` one included, that match the same servable Go catalog id,
such as a hand-written `deepseek-v*-flash*` beside `go-deepseek-v4.1-flash`,
evaluation fails and names the id and the families. Selecting them on different
runtimes is allowed, and families that overlap with no preset selected are not
checked. The `delegate-routing-opencode-go-presets` check fails when a servable
catalog id matches no preset or several, or a preset matches no catalog id.

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
which the execution choices in `fragments/plan-work.md` point readers at. It is
a hand-declared string, `"unknown"` by default; a shipped value names the mode
it was seen in, such as `"supported (headless)"`, and a one-line comment in
`lib/techniques.nix` cites the map row and case id that executed it. Change a
value only with a map row behind it.

Kimchi's Agent tool pins model and thinking. An omitted `thinking` falls back to
the persona default, so pass it explicitly. Kimchi's `/workflow` is a slash
command without a model tool; `dev/ai.nix` configures its interactive resource
for local activation (see `dev/fragments/pipeline/generation-architecture.md`).
External and manual runtime sections include external, introspect and usage
nodes. Kimchi has no usage node because no command reads usage without a model
turn. Shared table rendering escapes cells once.

### Pools

A pool is a budget shared by model reaches. It is not a runtime.
`pools.<name>.description` describes it in the planner reference's Pools table,
before the family tiers. The helper discovers the registered budgets and readers
from its generated manifest; the drain rule uses the helper output.

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
(repeat `--role` to share one snapshot). Supported roles are finder,
first-check, investigator, judge, mechanical, planner, second-check and writer.
Planner and the four review roles require strong/frontier tiers before ranking;
an empty qualified set exits nonzero with “never step down a tier; report a loop
failure.” The helper certifies tier and pace, not semantic fit, trial
eligibility or maker independence. Provider-vendor identity remains provisional
for aggregator independence until explicit maker data exists.

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
kills the reader process group. Failed, partial or multi-account Readers are
unmeasured; malformed, expired, missing-duration or unstarted-null-reset
unscoped windows also make streams unmeasured with reasons. No account routing
or missing resets are invented. The shared schema is required before pace
arithmetic: `account` contains `auth_index`, `name` and `plan` (including null
values), `pool` is a nonempty string, `balances` and `bonuses` are arrays, each
window's `status` is a string or null, and each `resetsAt` is a UTC timestamp or
null. Missing fields or wrong shapes make the whole stream unmeasured, except
malformed scoped windows, which warn and refuse only their named family.
Registration keys determine budget identity, never reader `.pool` output.

Each measured pool uses the minimum unscoped window pace
`(remainingPercent / 100) / ((resetsAt - now) / windowSeconds)` and the minimum
unscoped remaining share as its buffer; at least one unscoped window is
required. Reported calendar-month durations remain intact. A scoped window
`<window>:<model>` matches `<model>` by exact configured family name within that
pool, not by a model pattern. Each matching candidate uses the worse (minimum)
of its pool pace and all its scoped paces for both ranking and session
comparison. A scoped window at 0% excludes only that family and never consumes
the session pool's buffer. Unknown scopes produce a visible warning naming the
pool and window without making the pool unmeasured. A consistent unstarted
scoped window (0% used, 100% remaining, null reset) adds no family limit;
malformed scoped windows warn and refuse only their named family, preserving
pool measurement. A scoped window's `status` (the Reader maps `is_active` to
active/inactive) is not used: its limit applies regardless of status because
inactive has unknown meaning and applying the limit protects that model's
allowance.

Higher pace sorts first, with deterministic family/runtime ties; an eligible
session pool wins an equal-pace tie only above the strict 20% unscoped buffer. A
measured session candidate may be selected only if every other fitting measured
pool's candidate is behind or level in effective pace. Exhaustion stays measured
and never becomes a fit-only fallback. Unmeasured candidates are excluded while
fitted measured candidates exist; with none, output explicitly states fit-only
budget/session uncertainty. JSON is printed to stdout and concise launch
specifications to stderr. `--now` fixes the clock for offline tests.

`checks/routing-plan-runtime.py scripts/delegate-routing-plan.py` exercises fake
Readers and hand-written expectations, including a subprocess spy that rejects
any candidate/probe launch. CI exposes it as `delegate-routing-plan-runtime`.
Eight backend/runtime delivery fixtures check the rendered helper command,
runtime/session-pool identity in the small skill, and planner policy prose for
Reader completeness, the session buffer and named review fallbacks. Reader
collection, ranking and buffer behavior are tested against the source Python
helper with synthetic manifests. The
`module-delegate-routing-{hm,devenv}-{claude,codex,kimchi,kiro}-packaged-helper`
checks read each backend’s delivered `SKILL.md` for that runtime, follow its
rendered command to the packaged wrapper and manifest, and run that wrapper with
a fake Reader and fixed clock. Literal expectations cover the runtime, session
pool, measured budget and launch specification; a copied manifest with
`sessionPool = null` must fail the same assertions. CI builds these checks;
offline results do not establish live harness compliance.

### Interactive and headless discovery evidence

The delegate map classifies launch kinds; that classification does not establish
a trustworthy marker visible to a model or hook. The following source findings
use the map's pinned versions (`docs/delegates/evidence.md:24-32`), not a new
live capture. Verified means the cited map records the channel; unknown means it
does not prove automatic mode detection at that pin.

| Runtime / pin             | Verified channel evidence                                                                                                                                                     | Mode-detection status                                                                                              |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Claude Code 2.1.292       | `docs/delegates/system-prompt.md:75` verifies CLI append reaches interactive, headless and protocol main turns; line 77 distinguishes the `-p` child append channel from TUI. | Unknown: these channel differences do not prove a model-visible or hook-visible interactive/headless marker.       |
| Codex 0.160.1             | `docs/delegates/system-prompt.md:133` verifies developer instructions reach multiple launch kinds; line 137 verifies app-server instruction overrides.                        | Unknown: instruction reach and app-server overrides do not identify an automatic interactive/headless marker.      |
| Kimchi 1.5.1 / Pi 0.85.1  | `docs/delegates/system-prompt.md:246` names print, RPC and ACP launchers; line 261 verifies named-agent prompt replacement/inheritance.                                       | Unknown: launcher flags and inherited prompts do not prove a marker exposed to the model or hooks.                 |
| Kiro 2.28.0 / KAS 0.66.26 | `docs/delegates/system-prompt.md:188-190` records v3 headless and ACP launcher channels; `docs/delegates/evidence.md:35-36` distinguishes configured v3 from binary defaults. | Unknown: verified launcher channels do not establish model-visible or hook-visible interactive/headless detection. |

A bounded capture of the current pin's actual model input and hook payload in
both modes would settle each unknown; none was run for this contract. Callers
supply `nonInteractive` from known launch context or an explicit worker brief.
Unknown stays unknown, external launches remain unresolved, and the helper still
collects every Reader and applies tier/pace policy without a detection
prerequisite. No TTY or executable-name inference is permitted.

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
and the shared Markdown formatter; previews read the built entrypoint. Direct
`mkSkill` callers receive the same companion and absolute path as common-module
delivery. Package discovery supplies content, both backend modules and checks.

Run these from the repository root to print skills without launching delegates:

```bash
nix eval --raw .#delegate-routing-content.skills.claude.text
nix eval --raw .#delegate-routing-content.skills.codex.text
nix eval --raw .#delegate-routing-content.render --apply 'render: render { runtime = "kiro"; models.kiro = [{vendors = ["anthropic"];}]; }'
nix eval --raw .#delegate-routing-content.render --apply 'render: render { runtime = "claude"; extraRuntimes = ["codex"]; manualExternalDelegates = ["kiro"]; models.claude = [{vendors = ["anthropic"];}]; models.codex = [{vendors = ["openai"];}]; models.kiro = [{vendors = ["anthropic"];}]; }'
```

### Saved plans and prepared briefs

The resolved Work and review workflow's Plan step (`fragments/plan-work.md`)
defines the saved JSON fields and the prepared brief contract. Before
task-source investigation, an orchestrator runs its own runtime's helper for
`planner`, selects a fitted pinned candidate and passes the task, paths, saved
rubric and absolute `PLANNER.md` path. The planner must read that resolved
context before planning. No reachable qualified planner is a loop failure. An
assigned worker executing an approved bounded unit does not recursively invoke a
planner for it. New scope requires replanning the affected portion.

The planner saves `task`, originating launch `runtime`, the complete captured
helper JSON as `snapshot`, `rubric`, `units` and `waves` in the
orchestrator-provided working-data directory. Each unit names goal, owned files,
dependencies, one audience, one verification with its wrong implementation,
associated docs/checks, per-kind size and worker/reviewer launches. A launch
record contains its role, launching runtime, exact selected helper `launch`
object as `candidate`, that candidate's pinned `line`, and its prepared `brief`
path. Rubric and brief paths resolve relative to the plan. Every worker and
every reviewer brief contains the complete saved rubric bytes verbatim; a
summary or a path alone fails. The orchestrator may pass the prepared brief
artifact without reading all of it into the interactive context. The planner
prepares a base brief for every reviewer launch, including second-check and
judge, before returning the plan. The orchestrator adds earlier-check inputs
after those checks return, using the neutral, role-specific input rules in the
shared Work step. Check-plan therefore validates existing base briefs, not
future artifacts.

Invoke the same rendered executable with
`--check-plan <plan.json> --launch-context <current-context.json>` and repeat
`--role` for every planned role. `--max-concurrency <n>` applies a lower
host/user cap; the ceiling is ten. This operation collects fresh Readers and
validates the saved choices against that current role-qualified helper output,
not an allowlist embedded in the plan. It checks launching runtime, candidate
and pinned line together, dependency existence/cycles/order, disjoint exact
normalized writer paths, wave bounds and rubric bytes. A successful exit
includes `validation.status = "valid"` in the returned JSON. Unknown/unresolved
launches, automatic use of a manual-only route and invalid artifacts fail
without an approval result. An explicit request for a manual-only route remains
governed separately by user authorization, not this automatic validator.

The saved snapshot is provenance, never a freshness certificate. Changed context
or a new usage read requires checking against current output again; the
validation result supplies the current snapshot. There is no date expiry or
fingerprint over unrelated configuration. With all fitting pools unmeasured, a
current fit-only result may validate with budget/session uncertainty; this does
not certify an unresolved launch. A planner analyzing in another harness must
use the actual launching runtime's helper/sessionPool. Downstream launches in
another runtime need their own runtime-qualified plan and check. Candidate
target runtime can differ from launching runtime through a configured reach.

Independent units may share a wave on separate branches/parts with disjoint
owned files. The helper checks the declared shape, not code dependencies or
completion receipts. The orchestrator enforces writer → independent review →
fix/check → commit barriers before dependent waves or the next writer on a
shared branch. Reviewers retain isolated worktrees or read-only tools, and the
orchestrator checks the working tree after every shell-capable delegate. Model
fit, avoidFor guidance, trial restrictions and independence remain caller
assessments; a strong/frontier floor proves none of them. Offline validation
proves deterministic artifact checks, not live planner/harness compliance.

### Policy placement ledger

The ledger assigns each moved clause to its compulsory reader. Shared
planner/orchestrator policy is projected from one source, never copied into a
second authoritative paragraph. Worker policy travels in prepared briefs.
Fragment paths below are relative to `packages/delegate-routing/fragments/`.

| Clause                                                                                                                                             | Reader                                        | Authoritative source and delivery                                                                                                   |
| -------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Parts, Size, same-change docs/tests, ownership and dependencies                                                                                    | Planner                                       | `plan-work.md` → planner workflow and saved unit fields.                                                                            |
| At most ten, isolated/read-only reviewers, tree inspection after delegates                                                                         | Orchestrator; planner for waves and briefs    | `choose-execution.md` → shared Routing; `plan-work.md` → wave contract.                                                             |
| Change a running brief instead of stopping; prevent damage; salvage; retain finished work                                                          | Orchestrator; planner for supervision briefs  | `choose-execution.md` → shared Routing.                                                                                             |
| Brief before launch; detach long jobs; wait; outside-repository paths; transient 5xx reroute; vendor refusal; tool-less probes                     | Orchestrator; planner for launch briefs       | `choose-execution.md` → shared Routing and relevant prepared briefs.                                                                |
| One delegate versus workflow; independent starts; disjoint writers; serialize overlapping files                                                    | Planner; orchestrator executes waves          | `plan-work.md` → execution choices, units and waves.                                                                                |
| First pinning route; generated agent files; named fallbacks; launch cwd                                                                            | Planner; orchestrator binds tools             | `plan-work.md` → planner execution choices; helper supplies exact records; `choose-execution.md` keeps launch cwd in small Routing. |
| External briefs declare non-interactive status and reporting to an orchestrator                                                                    | Orchestrator; planner prepares briefs         | `choose-execution.md` → shared Routing, including the planner's own external launch.                                                |
| No external launches from non-interactive/external delegates                                                                                       | Worker; planner; orchestrator when headless   | `choose-execution.md` → shared Routing and prepared briefs; helper excludes headless external routes.                               |
| Another harness for a whole multi-step job; unknown reach probes; workflow/self-run fallback                                                       | Planner; orchestrator executes choices        | `plan-work.md` → planner execution choices and prepared launch choices.                                                             |
| Standing rubric rows; Subtractive rows; verbatim rubric copying                                                                                    | Orchestrator prepares rubric; planner; worker | `review-rubric.md` and `review-subtractive.md` → small preflight and full planner workflow; prepared briefs contain the rubric.     |
| Detailed reviewer checks; fit/trial restrictions                                                                                                   | Planner; worker                               | Resolved full workflow → `PLANNER.md`, then relevant worker/reviewer briefs.                                                        |
| Evidence chain; verified/retracted/unknown; rerun command claims; judge reading claims in full context                                             | Orchestrator; planner; worker                 | `load-delegate-routing.md` → always-on validation duty; `validate-the-result.md` → shared Routing and prepared briefs.              |
| Name why failure occurred; fix execution slips; bring only real decisions to the user                                                              | Orchestrator                                  | `validate-the-result.md` → small Routing.                                                                                           |
| Handoff before task-source investigation; triage reads allowed; quick facts only while a delegate runs; skill/usage reads count as handoff         | Orchestrator                                  | `orchestrator-session.md` → always-on router, excluded from planner context.                                                        |
| Bulk reading/searching/measuring/tracing/edit-test loops/moves/writing to delegates; one task; short evidence summary; stay on current item        | Orchestrator                                  | `orchestrator-session.md` → always-on router.                                                                                       |
| Read only cited output lines; pass file paths instead of pasted content                                                                            | Orchestrator                                  | `orchestrator-session.md` → always-on router.                                                                                       |
| Reader completeness; monthly/worst-window pace; buffer; unmeasured/fit-only/exhaustion policy                                                      | Planner; orchestrator                         | `pool-drain.md` → shared Routing; deterministic helper computes decisions.                                                          |
| Aim pools near empty at reset; no pool numbers unless asked                                                                                        | Orchestrator; planner reports to orchestrator | `pool-drain.md` → small and planner Routing.                                                                                        |
| Honor named model/effort/runtime/tool or report unavailable                                                                                        | Orchestrator; planner                         | `follow-the-users-request.md` → shared Routing.                                                                                     |
| Pin model/effort; name each role's model and effort in launch message/report                                                                       | Orchestrator; planner                         | `size-the-work.md` → shared Routing.                                                                                                |
| Disabled-Orchestrator-session quick fact/review/in-session fallback and no topic-only fan-out                                                      | Orchestrator                                  | Plan and launch in `entries.nix` → small skill, independent of router enablement.                                                   |
| Rule steering to source; no rendered edits or memory/house rules                                                                                   | Orchestrator                                  | `load-delegate-routing.md` → always-on router; `tune-these-rules.md` keeps override mechanics.                                      |
| Portable/runtime source customization, disables, overrides and workflow-step settings                                                              | Orchestrator; planner; worker editing rules   | `tune-these-rules.md` → shared Routing and relevant briefs.                                                                         |
| Planner bootstrap/non-recursion; check-plan/current snapshot; exclusions; manual authorization; review/commit barriers                             | Orchestrator                                  | Plan and launch in `entries.nix` → small skill; planner artifact/schema remains in `plan-work.md`.                                  |
| Writer/fixer hard rules; one surface/unit per writer; serialize shared-worktree writers and commit at boundaries                                   | Orchestrator; planner; worker                 | `review-work.md` → shared Work step and prepared briefs.                                                                            |
| Review brief ownership and claimed-review artifact verification; unit and branch-level review cadence; fix-sized checks                            | Orchestrator; planner prepares briefs         | `review-work.md` → shared Work step, moved from `work-and-review.md`.                                                               |
| Root-cause diagnosis validated before a different fixer acts                                                                                       | Orchestrator; planner; worker                 | `review-work.md` → shared Work step.                                                                                                |
| Judge never orchestrator; cut-judge family separation; unresolved-question validation; neutral second-check/judge inputs after first check returns | Orchestrator; planner prepares briefs         | `review-work.md` → shared Work step, moved from `review-checks.md`.                                                                 |
| Pin unit/fix/branch review bases; fix in introducing PR and restack; stop early; three-round cap; change brief after two rounds; gap list          | Orchestrator; planner; worker                 | `review-loop.md` → shared Loop step.                                                                                                |
| Ready report file count and added/removed line breakdown, including shipped instructions                                                           | Orchestrator; planner; worker                 | `review-describe.md` → shared Describe step.                                                                                        |
| Manual-only delegates require the user to name them                                                                                                | Orchestrator; planner                         | Manual-only external delegates entry → both projections; excluded from automatic selection.                                         |

The Orchestrator session first paragraph, reminder grant and hook exclusions
remain unchanged. All eight backend/runtime deliveries and direct `mkSkill`
callers emit both projections. The shipped pre-split skill baselines
(Claude/Codex defaults; explicit Anthropic selectors for otherwise unselected
Kimchi/Kiro) are 42,559 / 39,372 / 39,743 / 39,769 bytes, plus a 5,233-byte
router each. The size comparison renders Claude/Codex defaults without extra or
manual runtimes, and selects all Anthropic families for Kimchi/Kiro to match
those baselines; audience checks retain their custom Kimchi and restricted Kiro
scenario. Delivery checks require combined small-skill/router bytes below three
quarters of the original combined entry, exclude automatic family tables and
detailed reviewer checks and assert hand-written audience anchors; byte
reduction never substitutes for policy conservation.

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
in `eval/test_suite.py`. The `codex-helper-routing-controls` and
`codex-helper-independent-wave` cases conditionally import
`eval/helper-fixture.nix`; both execute the delivered helper with registered
fake Readers during dry-run, assert cross-runtime Reader execution,
outside-before-session selection and under-tier reviewer exclusion, and archive
setup receipts separately from live session receipts. Legacy cases retain their
synthetic-usage prompt and narrower evidence. The independent-unit case checks a
shared disjoint wave in the saved plan; this is not proof of concurrent launches
or organic planner compliance. Live helper-backed cases require
`--helper-backed`; generated inputs may need realization before dry-run. No
check starts a session. See `eval/README.md` for reminder comparisons, the
isolation recipe, the caps and the operator steps.

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

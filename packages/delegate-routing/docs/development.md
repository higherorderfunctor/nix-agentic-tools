# Delegate routing package

> **Last verified:** 2026-11-13 — native picker schema and bounded repairs
> preserve logged sessions and executable-tool removal; shared avoid/exclude
> fallback and all-technique machine defaults preserve floors, session gates and
> intentional null omission; failure warnings and the fallback notice reach
> stderr; advisory notes stay JSON-only; the renderer consumes the private
> shared routing view for launch reaches and registered readers; Plan saves
> bounded units, role-qualified launches and verbatim-rubric briefs, and
> check-plan validates them against fresh helper output; planner has a
> strong/frontier floor; the packaged non-launching helper consumes the same
> view and runtime sessionPool binding, rejects incomplete Reader envelopes, and
> keeps runtime-specific commands in skills so shared router rules remain
> byte-identical; Pool drain and Review use the helper as the canonical decision
> and retain named launch fallbacks; per-runtime mode evidence below leaves
> automatic detection unknown; routing ships an always-on "Pool drain" entry and
> a "Tune these rules" entry, the Review step holds the one review rule, the
> Work and review workflow builds a branch as units each reviewed by one check
> before the next starts (all three checks at the branch-level review when the
> PR goes ready), the usage helpers share one schema with UTC reset times,
> portable pools resolve usage readers and label family reaches on both
> backends, proxy-accounted-usage reads a Manager+ accounted monthly budget, and
> the always-on stub names the source for steering its rules; OpenCode Go joins
> z.ai as an API-key pool found by base URL, with opt-in Go preset families.
> Packaged-helper checks execute every runtime’s delivered helper on both
> backends and reject null sessionPool manifests.
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

## Static identities and CPA launch routes

`ai.catalog.models` and `ai.catalog.vendors` contain static owner contributions.
Delegate-routing reads those identities to validate concrete launch pins: an
undeclared identity or a null maker is refused. Pattern-only native launches
still use runtime introspection. The content package assembles its default
catalog with the existing catalog type module and Claude, Codex and CPA owner
modules; a manual `mkSkill` caller can supply a merged `catalog` instead.

`lib/cpa-routes.nix` reads each selected client's computed credentials from
`ai.internal.inferenceInstances`. CPA owns API selection and credential
filtering; the shared inference options refuse a disabled instance or an
undeclared client. OAuth offers expand catalog identities of the vendor's maker;
finite vendor lists do not define OAuth reach. A missing OAuth vendor is
refused. Canonical identities resolve through CPA's vendor-scoped
`ai.cliproxyapi.servedModels` mapping while launches retain the served spelling.
Without CPA reach, native launch pins name canonical catalog ids.

The projection feeds agent-file selection and `lib/routing-view.nix`.
Unknown-maker offers remain inspectable in the projection but cannot become a
concrete launch. Multiple credential offers remain available when CPA permits
overlap. Route pools retain the configured `family.pools` bindings; credential
names do not supply budget attribution. Native launches and external URLs retain
the existing fallback selection. Inherited picker entries outside a selected
client's reach are dropped; explicit entries are refused.

Module and manual builders pass the same `catalog`, `cpaRoutes` and resolved
agent data to prose and manifest rendering. Manual callers projecting CPA routes
supply evaluated instance options, inference-instance exports and runtime
selections. The `delegate-routing-cpa-routes` check uses synthetic identities,
checks projection and launch validation once, and checks module wiring on both
Home Manager and devenv.

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
Rubric, Subtractive, Plan, Work, Describe, Review and Loop chained by `after`.
Rubric preparation is preflight from the task goal; it does not authorize
task-source investigation before the planner. Plan uses the helper's
strong/frontier planner candidates before substantive source work, except for a
worker already assigned an approved bounded unit. It saves one plan and prepared
briefs, then checks them before launch with `--check-plan`. The rubric is a
saved file, pasted verbatim into the worker's and every reviewer's brief. Review
embeds the checks; they are not separate steps. Add, replace, disable or reorder
a step by key. "Choose execution" and the Review step reference the Rubric
step's Size row; a consumer who disables that step moves or restates the size
rule with it. A workflow can have introductory text or only steps; an enabled
step needs content.

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
rule is emitted. Keep launch binding details and technique notes in the skill.

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

`skill.entries` is the ordered body: Routing, Common workflows, Routing helper,
Technique notes and Manual-only external delegates. Entry text may use
`{routing}`, `{workflows}`, `{helper}`, `{pools}`, `{families}`, `{techniques}`,
`{techniqueNotes}` and `{manual}`, each filled with its generated block. An
entry whose placeholder block renders nothing, such as `{pools}` with no pools
declared, is omitted.

The shipped skill is built around caller capability and carries no full family,
pool or technique table and no sizing essay. Its Technique notes entry lists
each technique on one line (kind, modes, pins, runs-own-subagents, command and
notes), including the introspection commands and manual-only delegates. Family
selection has one mechanism: the helper's output, which the caller reruns before
every launch. The Routing section's Choose execution step gives three paths,
each valid for every runtime because observed tools and configuration decide
availability:

- native subagents only: the orchestrator invokes the helper, then binds the
  returned fixed technique, model and effort;
- a static workflow: a planner delegate returns the plan and the launching
  caller builds the workflow from it with fixed values; a new workflow reruns
  the helper while a running one is never mutated;
- a dynamic workflow: a planner inside it reruns the helper between steps and
  fixes every dispatch's values.

A consumer that wants a table back adds its own entry, for example
`entries."Family tables".text = "{families}";` with an `after` edge; the blocks,
columns and phrases below stay available for exactly that. The module check
`capability-skill` renders the shipped default and fails on a table row, a
family-table heading or sizing essay, or a missing capability path.

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
`"Technique notes heading"`, `"Technique table heading"` and
`"Manual delegate heading"` (`{harness}`). `"Launch fallback"`,
`"Manual delegate note"`, `"OpenCode Go note"`, `"Pool measured"`,
`"Pool unmeasured"` and `"Pool reader missing"` take none. A disabled phrase
renders nothing; a phrase the renderer reads but cannot find fails naming it.
The families block emits "OpenCode Go note" after the family tables only when a
Go family renders, so it appears only where a consumer entry uses `{families}`.

Shipped entries carry `after` edges to every predecessor, so disabling any one
keeps the rest in order. Column settings apply to a consumer's table entries.
For example, this replaces one paragraph and drops one column of a consumer
`{families}` entry:

```nix
ai.programs.delegate-routing.skill = {
  columns.families.Orchestration.enable = false;
  entries."Technique notes".text = "Check your tool list first.\n\n{techniqueNotes}";
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
catalog that CPA's `opencode-go` vendor serves. Coverage reuses the existing
Anthropic and OpenAI families and the shipped `zhipuai.glm` and
`zhipuai.glm-flash` guidance; these families have no default pool bindings.
`opencodeGo.presetScope.excludeModelPrefixes = []` checks the entire catalog by
default. Consumers can exclude case-insensitive nonempty prefixes from guidance
coverage, for example `["example-"]`. This changes neither CPA offers nor
runtime reach and does not remove families or bind pools. Home Manager, devenv
and the manual `mkSkill` builder accept the same nested option. Go presets come
from per-model research, and every tier is provisional: whenever a consumer
`{families}` block renders an `opencode-go` family, one line under the tables
says so. Each family is named `go-` plus the exact Go id, except
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
in-scope catalog id matches no guidance owner or several, or its owner lacks
use/avoid and effort guidance. Removing an upstream model does not fail this
gate. Explicit scope exclusions do not suppress missing guidance for other ids.

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
records for the optional pool, family and technique blocks; it keeps skill
phrases and table formatting. The view reuses `select-families.nix` and takes
the module's effective techniques, including the Kiro workflow gate, and its
already resolved Claude agent records so proxy picker ids and family default
effort remain available. Direct builders retain catalog resolution when no
resolved agent set is supplied. Its reader inventory resolves every registered
pool independently of launch targets, including readers whose runtime is absent
from both automatic and manual reaches. Manual reaches stay separate from
automatic candidates; this view is private implementation data, not a public
manifest or option.

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

`families.<vendor>.<family>.defaultEffort` uses the package scale
`minimal < low < medium < high < xhigh < max`, shared with the helper manifest.
It supplies every technique's default and remains consumer-overridable; Sol uses
medium, Go Kimi K3.1 Pro max, and families without levels null. Go Crouton Alpha
Free uses a provisional medium package choice, not a published recommendation;
consumers can override it. The shipped `zhipuai.glm` uses high;
`zhipuai.glm-flash` leaves the effort pin unset. Null omits the generated file's
`effort:` line. Agent files pin only efforts Claude's agent-file format accepts;
otherwise they leave effort to the launch call. A non-null role effort overrides
the family default. The shared frontmatter renderer writes the pins and a fixed
delegate body.

There is no separate file enable option. Set
`runtimes.claude.techniques."Agent with generated agent file".enable = false` to
withhold both files and the route. The effective technique is also disabled when
the Claude runtime or its delegate-routing program is off.

`runsOwnSubagents` fills the technique notes' "runs own subagents" fact and a
consumer technique table's "Runs own subagents" column. It is a hand-declared
string, `"unknown"` by default; a shipped value names the mode it was seen in,
such as `"supported (headless)"`, and a one-line comment in `lib/techniques.nix`
cites the map row and case id that executed it. Change a value only with a map
row behind it.

Kimchi's Agent tool pins model and thinking. An omitted `thinking` falls back to
the persona default, so pass it explicitly. Kimchi's `/workflow` is a slash
command without a model tool; `dev/ai.nix` configures its interactive resource
for local activation (see `dev/fragments/pipeline/generation-architecture.md`).
External and manual runtime sections include external, introspect and usage
nodes. Kimchi has no usage node because no command reads usage without a model
turn. Shared table rendering escapes cells once.

### Pools

A pool is a budget shared by model reaches. It is not a runtime.
`pools.<name>.description` describes it in the `{pools}` block of a consumer
entry; the shipped skill has no Pools table. The helper reads the budgets and
readers from its manifest.

Set `usage.runtime` and `usage.technique` to read a measured pool through an
existing technique. The runtime must be enabled. The technique must be enabled,
have kind `usage`, and have a non-empty command. The table resolves that command
from the technique catalog. Reader metadata follows the reader's runtime even
when it is not a delegate target.

For a budget without a reader, set `window.limit`, `window.unit` and
`window.resetDay`. This declares an allowance per calendar month in UTC, with a
reset day from 1 through 28. Current use stays unknown. A pool needs `usage` or
`window`; both default to null. If both are set, the measured reader takes
precedence. Configure `limits` and `usage.readerPool` for credential
observations; see [registration options](pacing.md#credential-collection). The
description defaults to an empty string.

Bind a family through `families.<vendor>.<family>.pools.<runtime> = "<pool>"`.
The key names the target harness that launches the model. Each native, external
or manual reach shows its binding. Several families or harnesses can share one
pool. A null binding means no pool is known for that reach. Unknown pool names
fail evaluation. Two accounts for one family on one harness are out of scope;
route and instance reaches are not represented.

The pool registry and family bindings default to `{}`. A consumer with one
vendor and one harness writes nothing extra. Without pools, a consumer's
`{families}` table still renders an empty Pool column. The package does not
infer budgets from vendors or add account names to its defaults.

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

Invoke the rendered command with
`--role first-check --launch-context <json-path>` (repeat `--role` to share one
snapshot). Supported roles are finder, first-check, investigator, judge,
mechanical, planner, second-check and writer. The routing policy lives in
[Pool drain](../fragments/pool-drain.md) and
[Size the work](../fragments/size-the-work.md).

The closed launch context supplies a bounded nonempty `taskSummary`, optional
nullable `proposerFamily`, required `nonInteractive`, compact `roles` and
observed `techniques`. Each role accepts only optional `effort`, `avoid` and
`exclude`; family qualification essays are refused. A known proposer is an exact
configured family; an unknown non-null name is refused before Readers. Absent or
null identity skips the picker and warns while preserving tier/pool fallback.

The helper validates the whole request before any Reader or picker runs and
reports every problem at once, schema-style:
`{"path": "launchContext.roles.writer.effort", "message": "unknown effort; allowed: minimal, low, ..."}`.
Paths cover `argv` (arguments, including unknown `--role` values),
`launchContext` (allowed keys, role names, `roles.<role>.effort` checked against
the manifest's `effortLevels` (observed technique efforts are unrestricted;
off-scale values such as `ultra` or `off` are ignored), configured family names
for `proposerFamily`, `avoid` and `exclude`, the `taskSummary` byte limit, a
required `nonInteractive`, technique evidence by index) and `manifest`. A
`manifest.` error is marked as a configuration fault, not caller-fixable.
Malformed JSON reports `launchContext` or `manifest` with the file, line and
column. On any error the helper prints
`{"status": "invalid-request", "errors": [...]}` on stdout, one
`delegate-routing-plan: <path>: <message>` line per error on stderr, and
exits 2.

When several observed models match one family's pattern, the helper launches the
highest version by the numeric rule generated agent files use (6.10 over 6.9;
the last listed wins a tie), so callers can pass every model their introspection
lists.

```json
{
  "taskSummary": "review a bounded source change",
  "proposerFamily": "opus",
  "nonInteractive": false,
  "roles": { "first-check": { "avoid": ["sol"], "exclude": ["opus"] } },
  "techniques": [
    {
      "efforts": ["high", "medium"],
      "model": "gpt-6.1-sol",
      "runtime": "codex",
      "technique": "spawn_agent"
    }
  ]
}
```

`runtimes.<runtime>.picker.entries` is an ordered list of explicit
`{technique, model, effort}` tuples. Claude defaults to `claude -p` / the sonnet
family's model (the resolved id of the generated sonnet agent file, which
honours an `example.claude` override) / medium, Codex to `codex exec` /
`gpt-6.1-sol` / medium (Sol, never Luna); Kimchi and Kiro default to empty
lists. An inherited entry is omitted when its model has no selected family/reach
or resolved id, or its known launch technique is disabled or unavailable;
explicit entries keep their literal model and retain strict validation. Module
and direct-builder defaults use the same routing-view resolver, including
builder overrides. The view resolves exact models against configured family
patterns and refuses duplicate tuples, unresolved models, invalid efforts or
techniques without enabled external reach, model/effort pinning and a nonempty
picker command. Direct `mkSkill` callers receive the same manifest field.

Technique-owned `pickerCommand` data carries initial and optional resume
commands, `outputFormat` (`json` or `claude-json`), and `sessionIdSource`
(`generated`, `codex-events` or null). The common routing view delivers these
fields to Python on both backends. Commands bind shell-literal placeholders for
the model, effort, prompt, result, schema file/JSON, session ID and event file.
Custom raw-JSON commands default to fresh calls. Resume templates must bind the
exact ID; latest-session selectors are never used.

One Python `PICKER_SCHEMA` supplies the native schema and prompt contract.
Strict decoding and semantic validation remain the sole acceptance gate:
duplicate keys/pairs, non-finite values, invalid Unicode, wrong keys/types or
version, unasked pairs and missing coverage are rejected. Reasons must be
nonblank and printable throughout, then are stripped and truncated to 240
characters. Claude's complete result envelope is strictly decoded before its
successful `structured_output` is extracted; free text is not a substitute.

Each entry gets at most three subprocess calls total, including transport
failures and validation repairs, with two seconds only between calls. Each call
has a 90-second timeout and 65536-byte result, event and stderr limits; prompt
bytes are bounded at `7 * 65536` to accommodate escaped task data.
Timeout/output overrun kills the process group. Prompt/output overflow and
unavailable catalogs end the entry immediately. Exhaustion advances to the next
entry and preserves safe fallback warnings, without subprocess stderr or model
replies.

Claude receives a generated UUID; Codex captures the `thread.started` ID from
JSONL events while reading its answer from the last-message file. A rejected
reply resumes that exact session with only “Correct your previous submission”
and the exact local validator error as JSON-string data. JSON syntax diagnostics
include position, never the rejected document. A transport failure with a known
session ID resumes that session and sends again the full original request when
no validator error is available. A resume reporting “No conversation found”
clears the ID so the next budgeted call starts fresh. Missing IDs or
non-resumable commands use the full original request plus the latest error.
Repairs retain model, effort, task/pair set, working directory and tool
restrictions. Each call clears result/event files so stale output cannot be
accepted.

Both native templates retain normal CLI session logging: neither
`--no-session-persistence` nor `--ephemeral` is passed. Scratch is deleted after
the entry; native session histories are retained. Claude runs in the caller’s
project directory, so its picker session appears in that project’s `/resume`
history and is what `claude --continue` would pick up there. Codex resolves
`CODEX_HOME` before entering stable scratch and writes one tool-free model
catalog from its `models_cache.json`. Missing/unreadable models make the entry
unavailable. Claude keeps its working directory and normal auth/provider
settings, with hooks, slash commands and MCP disabled and an empty executable
tool set.

Offline tests with Codex 0.169.0 and Claude 2.1.323 exercise native schema,
initial/resumed requests and session-store persistence against localhost fake
providers using synthetic homes. Codex sends no tools; Claude sends only the
`StructuredOutput` protocol tool, which submits JSON rather than executing a
command. Both requests retain the same schema and model; Codex's wire effort and
Claude's disabled hook canary are checked. These optional tests require raw CLI
binaries in `CODEX_PICKER_COMMAND`, `CODEX_PICKER_RESUME_COMMAND`,
`CLAUDE_PICKER_COMMAND` and `CLAUDE_PICKER_RESUME_COMMAND`, populated with the
shipped templates. They skip without those inputs. Stub protocol, strict
validation and bound tests always run. Live authenticated compatibility remains
unverified; offline captures do not establish provider behavior or tool
availability that depends on authentication.

Readers and hard eligibility still precede judgment. A picker must be distinct
from the proposer, allowed by pool/scoped limits and available on PATH; an empty
eligible catalog spends no call. Its keep/exclude decisions cover every eligible
role/family pair, including avoided fallbacks. Only kept families enter pool
ranking. The authorized internal picker may run with `nonInteractive: true`.

When identity is absent/null, no entry is runnable, or all entries fail, report
exactly
`WARNING: model picker unavailable; using tier and pool ranking only. Report this failure to the user.`
followed by ` Unavailable: <reason>.` for each failed entry, or for missing
identity/no runnable entry, and use hard-eligible tier/pool routes. Failure
reasons describe timeouts, exit status, limits and invalid decisions without
including prompts, raw output or stderr. Picker failure alone does not erase
routes.

Observed `efforts: []` always means launch without effort, regardless of role
request, family default or avoidance. JSON keeps effort null; canonical lines
omit its token and launchers omit the argument, flag or pin.

With Sol's medium default, the example produces this fallback specification:

```text
role=first-check runtime=codex family=sol technique=spawn_agent model=gpt-6.1-sol effort=high
```

The candidate's `launch.fallback` is
`{"kind": "avoided-family", "launchEffort": "high", "resolvedEffort": "medium"}`;
only a fallback first pick produces a notice, once per role, naming its family
and launch effort and asking the caller to report it to the user. These lines
are specifications for native tools, not shell commands. JSON also retains named
alternatives, invocation guidance and generated-agent records; manual-only
routes are separately labelled. `nonInteractive: true` excludes external
techniques; absent mode evidence leaves them unresolved.

Only configured Reader commands and verified tool-free picker commands reach
subprocess execution. Identical commands share one read and retry; full strict
Bash mode and a ten-second process-group timeout bound execution. Registration
keys determine budget identity rather than Reader `.pool` output. The required
envelope has `account` fields `auth_index`, `name` and `plan` (including null
values), a nonempty string `pool`, arrays `balances` and `bonuses`, and a
`windows` map. An empty map is valid and unmeasured. Failure reasons use safe
validation text, never Reader stderr, command text or exception payloads.

The pace formula is
`(remainingPercent / 100) / ((resetsAt - now) / windowSeconds)`. The pool uses
the minimum unscoped pace and remaining share; a candidate uses the minimum of
pool and matching scoped paces. A scoped key such as `7d:fable` matches the
exact family name in the manifest's `poolFamilies` inventory for that pool. The
inventory collects all configured runtime pool bindings, including families
outside the current runtime's automatic and manual launch routes. A family
configured only in another pool still produces an unmatched-scope warning.
Remaining shares must be finite numbers in [0,100], excluding booleans. Used
windows require a UTC reset and retain the strict reset-duration bound; reported
calendar-month durations remain intact. Idle windows bypass reset validation;
all-idle pools use pace 1.0 and full buffer. Scoped `status` is ignored because
inactive has unknown meaning. Ties sort non-session pools first, then
family/runtime deterministically.

See [saved allowance observations](pacing.md) for saved captures with explicit
model scopes.

JSON goes to stdout and canonical lines to stderr. JSON includes all warnings;
stderr includes failure warnings and the fallback notice; advisory notes stay
JSON-only. All-failed choices retain reasons and exit non-zero. `--now` fixes
the UTC snapshot for offline tests. No TTY inference, catalog command, live
probe or delegate launch occurs.

From this package directory, run the offline runtime suite with its explicit
fixture input:

```bash
python3 checks/routing-plan-runtime.py scripts/delegate-routing-plan.py checks/fixtures/routing-readers.json checks/fixtures/codex-models-cache.json
```

It exercises fake Readers and hand-written expectations, including a subprocess
spy that rejects any candidate/probe launch. The fixture preserves five full
successful Reader envelopes captured live from the five registered pools,
evaluated at `2026-11-10T00:08:41Z`. Only `account.auth_index` and
`account.name` are replaced with stable synthetic strings; nulls, field types,
windows, balances and bonuses are preserved. These captures verify arithmetic
and ranking; synthetic cases verify Reader failures. CI passes the fixture store
path explicitly in `delegate-routing-plan-runtime`. Eight backend/runtime
delivery fixtures check the rendered helper command, runtime/session-pool
identity in the skill, and policy prose for Reader completeness, the session
buffer and shared avoided-family fallback. Reader collection, ranking and buffer
behavior are tested against the source Python helper with synthetic manifests.
The
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
direct read. `zhipuai-usage claude|codex` and `opencode-usage claude|codex`
select the route whose GLM or OpenCode Go pool they read; consumers attach them
to a runtime through that runtime's usage techniques. `opencode-usage` reads the
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

### Saved plans and prepared briefs

The resolved Work and review workflow's Plan step (`fragments/plan-work.md`)
defines the saved JSON fields and the prepared brief contract. Before
task-source investigation, an orchestrator runs its own runtime's helper for
`planner`, selects a fitted pinned candidate and passes the task, paths, saved
rubric and resolved routing/workflow context. No reachable qualified planner
after shared avoided-family fallback is a loop failure. An assigned worker
executing an approved bounded unit does not recursively invoke a planner for it.
New scope requires replanning the affected portion.

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
and pinned line together, including current fallback metadata and intentional
null effort, dependency existence/cycles/order, disjoint exact normalized writer
paths, wave bounds and rubric bytes. A successful exit includes
`validation.status = "valid"` in the returned JSON. Unknown/unresolved launches,
automatic use of a manual-only route and invalid artifacts fail without an
approval result. Candidate equality does not bind actual worker identity or add
a worker-effort contract. An explicit request for a manual-only route remains
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
orchestrator checks the working tree after every shell-capable delegate. Trial
restrictions and independence remain caller assessments; helper-owned judgment
applies task/role fit and avoidFor guidance; a strong/frontier floor proves none
of them. Offline validation proves deterministic artifact checks, not live
planner/harness compliance.

### Policy placement ledger

The Plan step adds a saved artifact and validation caller; existing policy
paragraphs retain their authoritative fragment and compulsory readers. No source
is removed or hidden by this change. This ledger names the current destination
of each execution clause so later context delivery can preserve its audience
without copying authoritative paragraphs.

| Policy substance                                                                                                                         | Source and compulsory destination/reader                                                                                                                                                    |
| ---------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Parts, Size, same-change docs/tests, file ownership and dependencies                                                                     | `choose-execution.md` remains resolved routing context; Plan consumes these as saved unit fields before returning a plan.                                                                   |
| At most ten, isolated/read-only reviewers, tree inspection after delegates                                                               | `choose-execution.md` remains execution policy; Plan records wave bounds and briefs carry relevant constraints; the orchestrator enforces them.                                             |
| Change a running brief instead of stopping, prevent damage, salvage diffs, retain finished work                                          | `choose-execution.md` remains compulsory execution context and is attached to relevant worker briefs; orchestrator supervision retains these duties.                                        |
| Brief before launch, detach long jobs, wait for exit, outside-repository paths, transient 5xx reroute, vendor refusals, tool-less probes | `choose-execution.md` remains compulsory planner/executor context and supplies the relevant prepared launch briefs.                                                                         |
| One delegate versus workflow, independent starts, disjoint writers, serialization                                                        | `choose-execution.md` remains the decision procedure; Plan records its units, owners, dependencies and waves.                                                                               |
| First available pinning route, generated Claude agent files, concrete named fallbacks, launch cwd                                        | `choose-execution.md` plus helper route output remains planner launch context; prepared briefs carry exact pinned choices and working directory.                                            |
| Every external brief declares a non-interactive delegate reporting to an orchestrator, not a person                                      | `choose-execution.md` remains the source; Plan explicitly requires that declaration in every external-launch brief.                                                                         |
| Non-interactive/external delegates never launch external delegates                                                                       | `choose-execution.md` remains an unconditional launch-context constraint; Plan requires it in worker briefs and helper checks refuse headless external candidates.                          |
| Another harness for an entire multi-step job, unknown reach probes, runtime workflow/self-run fallback sequence                          | `choose-execution.md` remains planner/executor context; the plan records the relevant decision and launch exception.                                                                        |
| Rubric, Subtractive, Work hard rules, full Review policy and trial/fit restrictions                                                      | The resolved Work and review steps remain compulsory workflow context; Plan saves the full rubric first and includes it verbatim in every prepared worker/reviewer brief.                   |
| Result validation and evidence chain                                                                                                     | `validate-the-result.md` remains orchestrator-visible; prepared briefs carry relevant evidence duties and the orchestrator validates receipts.                                              |
| Pre-handoff triage of what the user pointed at; quick facts only while a delegate runs; skill/usage reads count as handoff               | `orchestrator-session.md` remains always-on orchestrator context; Plan's rubric preflight adds no task-source investigation exception.                                                      |
| Read only delegate-cited output lines; pass the next delegate a file path rather than pasted content                                     | `orchestrator-session.md` remains always-on orchestrator context; prepared brief paths let the orchestrator comply.                                                                         |
| Aim for every pool to reach reset near empty; do not report pool numbers unless asked                                                    | `pool-drain.md` remains always-on execution context; helper output does not waive either obligation.                                                                                        |
| Source customization and rule steering                                                                                                   | `tune-these-rules.md` and `load-delegate-routing.md` retain their resolved/always-on placement; portable/runtime entry replacement, disables and direct builder overrides remain unchanged. |

Fragment paths in this ledger are relative to
`packages/delegate-routing/fragments/`. The Orchestrator session first
paragraph, reminder grant and hook exclusions remain unchanged. The helper
invocation remains in each runtime's skill; the always-on router is
runtime-neutral. No separate planner companion or reduced entrypoint is emitted
by this contract alone.

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
skill read the same technique configuration. Same-runtime nested children ARE
logged in and can run and spend inside the 600 s process-group cap; no PATH shim
blocks them. Results are `PASS`, `FAIL` or `ERROR`; only `ERROR` (no answer, a
leak, or the routing skill missing from the startup record) fails the run.

The owner check `delegate-routing-eval-structure` runs the suite's `--dry-run`
in the sandbox: it validates every case and renders every fixture and launch
plan with no harness and no login. Its `cases` passthru is the runner's fixture
export. It also runs the offline source-attribution and event-schema regressions
in `eval/test_suite.py`. The separate module check `capability-skill` rejects
full tables and missing capability paths in the shipped skill. Neither check
starts a session. See `eval/README.md` for reminder comparisons, the isolation
recipe, the caps and the operator steps.

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

# Delegate routing package

> **Last verified:** 2026-10-07 — one enabled "Work and review" workflow ships
> the Subtractive standard; a runtime workflow record without text keeps the
> portable header; all delegate runtimes must be managed, and reaching Kiro
> defaults `ai.kiro.v3` on only when its package is managed.

`ai.programs.delegate-routing` exposes portable `families`, `routing` and
`workflows`. Runtime controls live under `runtimes.<runtime>` for Claude, Codex,
Kimchi and Kiro. Both Home Manager and devenv import `modules/common.nix` and
expose the same surface.

## Named guidance

`routing.<name>` has `enable`, `always`, `before`, `after` and either `text` or
`source`. Names become headings. The package ships the always-on "Load
delegate-routing" stub and four enabled entries: "Follow the user's request",
"Size the work", "Choose execution" and "Validate the result". "Validate the
result" is always-on too. The "Orchestrator session" catalog entry ships
disabled. Policy belongs in these entries rather than renderer string literals.

`workflows.<name>` has the same fields plus `steps.<name>`. Each step has the
routing entry fields except `always`; the workflow's `always` places its steps.
The package ships one enabled workflow, "Work and review", with the steps
Rubric, Subtractive, Work, Review, Prosecute, Defend, Judge and Loop chained by
`after`. Review is one reviewer; Prosecute, Defend and Judge replace it for a
change to a shared abstraction. The Subtractive step adds the subtraction
standard to the rubric. Loop sends validated findings back to the worker for at
most 3 rounds. Add, replace, disable or reorder a step by key. A workflow can
have introductory text or only steps; an enabled step needs content.

Entries with `always = true` render through the existing per-runtime `ai.rules`
fan-out. Other entries render in the generated skill. A workflow's `always`
selects the destination for its header and numbered steps together; steps retain
their order within that workflow. The always-on stub tells the agent to load the
skill before delegation. When the always-on render is empty, no router rule is
emitted. Keep model tables and harness details in the skill.

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

This repository enables "Orchestrator session" in `dev/ai.nix`. Its portable
"Local limits" entry caps external CLI delegates at two. Its Claude-only "Pool
drain" entry follows "Size the work" and asks for usage before each batch of
delegates, choosing allowance left per hour until reset. These house entries are
consumer policy, not shipped defaults.

## Families and runtime capabilities

`families.<vendor>.<family>` is the portable decision table. Each record has a
capability tier, task and effort guidance, and a required normalized live-model
pattern. Package fields use `mkDefault`, so consumers can override a field or
add a family. `lib/families.nix` carries the package families without concrete
model versions or Kimchi-served vendors. Kimchi serves other vendors' models, so
this repository declares those families in `dev/ai.nix`.

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
per tier with all applicable native and external reaches.

Resolve concrete models at launch time: inspect the runtime's live list, compare
version segments to find the highest version matching the family pattern, and
use that runtime's spelling. Claude's interactive tools take aliases such as
`opus`.

`runtimes.<runtime>.techniques` is a keyed set of workflow, subagent, external,
introspect and usage nodes. Delegate nodes describe model and effort pinning,
and mode availability. Modes describe usual availability, not session-mode
detection; use only tools present in the current session and external commands
on PATH. Introspection and usage nodes describe how to obtain live evidence.
Usage commands remain part of the existing technique catalog. Each package field
uses `mkDefault`; consumers can override fields, add nodes or disable a node.

Kimchi's Agent tool pins model and thinking. An omitted `thinking` falls back to
the persona default, so pass it explicitly. Kimchi's `/workflow` is a slash
command without a model tool; `dev/ai.nix` enables its interactive resource
separately. External and manual runtime sections include external, introspect
and usage nodes. Kimchi has no usage node because no command reads usage without
a model turn. Shared table rendering escapes cells once.

## Delivery and previews

When an enabled runtime reaches Kiro, as the session runtime or through
`extraRuntimes` or `manualExternalDelegates`, the program sets `ai.kiro.v3` with
`mkDefault` only when `ai.kiro.package != null`. The skill's Kiro evidence
covers the v3 engine only. A consumer's own `ai.kiro.v3 = false` still wins and
emits a mismatch warning. Every reached runtime must be enabled. With a managed
package, Kiro's wrapper carries `--v3` to interactive and delegate launches
alike; with `package = null`, there is no wrapper, v3 is left unset and the
mismatch warning fires. A consumer without the Kiro module is untouched.

Reaching Kiro on devenv withholds `trustedMcpTools` from `kiro acp` (warned),
while Home Manager drops bare tokens such as `use_aws` from the
`permissions.yaml` translation.

The common module imports `mkSkillPackageModule` once for the supported
runtimes. Per-runtime program enable inherits portable enable through the
factory's null-as-inherit rule. Skills and router rules contribute to
per-runtime pools, never the portable pools. Runtime-only controls are not
declared at portable scope. Copilot is excluded from this program.

The Kimchi skill lands in devenv `.kimchi/skills` or Home Manager
`harness/skills`. Project skills take precedence over config paths and harness
skills. Both project-scoped roots load only when Kimchi trusts the project. A
trusted project's `.claude/skills/delegate-routing` can override the Home
Manager harness copy through default config paths.

The always-on routing rule uses the existing native Claude rules and AGENTS.md
delivery for Codex, Kimchi and Kiro. Under Home Manager, Kimchi's copy lands in
its user harness AGENTS.md. Byte-identical contributions deduplicate. The
content package injects packaged usage helper paths into technique defaults. The
Claude helper carries curl and jq; the Codex helper carries timeout, jq and
Python, while the consumer supplies the Codex CLI.

`mkSkill`, `render` and `skills` consume the same family, selector, technique
and named-entry inputs. Generated skill trees use `lib.ai.generated` and the
shared Markdown formatter; previews read the built files. Package discovery
supplies content, both backend modules and checks.

Run these from the repository root to print skills without launching delegates:

```bash
nix eval --raw .#delegate-routing-content.skills.claude.text
nix eval --raw .#delegate-routing-content.skills.codex.text
nix eval --raw .#delegate-routing-content.render --apply 'render: render { runtime = "kiro"; models.kiro = [{vendors = ["anthropic"];}]; }'
nix eval --raw .#delegate-routing-content.render --apply 'render: render { runtime = "claude"; extraRuntimes = ["codex"]; manualExternalDelegates = ["kiro"]; models.claude = [{vendors = ["anthropic"];}]; models.codex = [{vendors = ["openai"];}]; models.kiro = [{vendors = ["anthropic"];}]; }'
```

## Planning regression suite

`eval/` contains a manual routing simulation: named Nix cases render the actual
delivered skill and router rule through the existing module harness. Fictional
inventories, capabilities and executed usage mocks provide the observations;
independent expected tuples stay out of prompts. Pool cases consume this
worktree's house rule sources. Child-support observations are synthetic test
configuration, not measurements of real runtimes. Missing-usage fallback remains
a partial expectation until its policy is decided.

`eval/run.py` renders without authentication and grades strict saved JSON plans
against `eval/plan.schema.json`; `eval/rubric.md` owns prose criteria and
separate calibration samples. Runtime adapters stay disabled until verified
tool/context suppression and terminal capture establish safe planning mode.
Outputs default outside checkouts. Pending prose and policy decisions remain
separate from exact scores, with infrastructure failures retained in end-to-end
rates.

The owner check `delegate-routing-eval-structure` evaluates and renders all
cases, validates the schema, and checks expected field references. Its `cases`
passthru is the runner's fixture export boundary. It never starts a model
process. Existing module checks own Home Manager/devenv delivery parity; the
manual suite owns behavioral evidence. See `eval/README.md` for replay commands.

The separate `eval/vendor-cases.nix` set evaluates `dev/ai.nix` through the
devenv module harness and exports the actual delivered files for each Claude
experimental switch and Kiro task shape. `run.py --set vendor --render-only`
materializes those files and a tool-denial overlay, retaining vendor system
steering for manually authorized live capture. Configured hook content and
observed sources are distinguished from hidden vendor text, which stays UNKNOWN.
The vendor structural check renders every variant without starting a runtime.
See the evaluation guide for safety preflight requirements, provenance, paired
comparisons and paid-turn counts.

## Delegate decision reference

`docs/delegates/evidence.md` owns pins, evidence marks and capture methods. The
other reference files own tools, controls, lifecycle and prompt reach.
`probes/delegates/<harness>/README.md` indexes exact case commands and expected
excerpts. Captured execution and source-only evidence stay separate. Probes
write beneath a temporary case tree; Kiro needs an operator-supplied fixture
home because this probe set does not define its serialized login schema.

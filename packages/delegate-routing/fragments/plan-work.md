The planner runs the actual launching runtime's rendered helper with
`--launch-context <json-path> --role <worker-role> --role <reviewer-role>`,
repeating `--role` for every planned worker and reviewer role, before selecting
launches or writing briefs; save its complete JSON output as the plan's
snapshot.

The planner reads the resolved routing/workflow policy and task source once,
then returns a saved JSON plan and prepared human-readable launch briefs in the
working-data directory the orchestrator provided. Never invent a scratch
location. Save the full numbered rubric before writing any implementation brief.
Every worker and every reviewer brief must include its complete text verbatim,
not a summary or pointer. The orchestrator passes the prepared paths without
loading every brief into the interactive context.

Use this JSON contract (paths to rubric and briefs are relative to the saved
plan; writer file ownership is repository-relative):

- `task`: nonempty assignment identity; `runtime`: the actual launching runtime,
  not the planner's analysis harness; `snapshot`: the full captured helper JSON
  (including its snapshot timestamp); `rubric`: saved rubric path.
- `units`: records with unique `id`, `goal`, `audience` (one reader), `files`
  (all writer-owned paths, including associated docs/tests), `dependencies`
  (unit ids), `docs` and `checks` path lists, `size` (per-kind `added`/`removed`
  nonnegative line counts), and `verification` with one `command` and the
  `wrongImplementation` it rejects.
- Each unit's `launches` contains one worker role (`writer`, `investigator` or
  `mechanical`) and its proposed reviewer roles, including `first-check`. Each
  record contains `role`, launching `runtime`, `candidate` (the selected helper
  candidate's complete `launch` object), `line` (that same candidate's exact
  pinned routing line), and `brief` (prepared artifact path). Include every
  finder, first-check, second-check and judge that will run; the helper's floor
  never proves fit, trial eligibility or independence. Honor explicit avoidFor
  guidance and the Review step's trial restrictions.
- `waves`: ordered lists of unit ids. Put at most ten simultaneous delegates in
  a wave, honoring lower host/user caps. Each unit contributes one concurrent
  delegate because its worker and reviewers run in sequence. Writers in one wave
  own disjoint files on independent branches/parts. A dependency must finish
  writer → independent review → fix/check → orchestrator commit before a later
  wave starts. Units sharing a branch run through that same barrier before the
  next writer. Review wave membership is not permission to launch an entire
  unrevised branch.

The saved helper snapshot records provenance. Execution uses the current
snapshot returned by the orchestrator's check-plan operation. Do not add age
limits or fingerprints of unrelated configuration. A downstream delegate that
launches work in another runtime needs a separate plan/check using that
runtime's rendered helper and session pool, even if a planner in another harness
prepares it. The helper validates specifications and reads registered Readers;
it never executes a delegate or probe.

Prepare briefs using the relevant resolved Choose execution, Work, Review and
Validate the result policy, including external-launch declarations, the
non-interactive limit, hard rules, evidence, isolation and trial restrictions.
The orchestrator receives its launch and supervision duties directly in the
router and small skill.

**Execution choices**

List the parts of the work before choosing execution. Size each part with the
Work and review rubric's Size row and follow that row's split rule. Checks,
tests and docs that exist only for a part ship in the same change as that part,
so a split never moves a part's tests to another PR. Name the files each part
writes and its dependencies.

Use a tool from the table that exists in the launching session's mode. A single
self-contained task needs one delegate. Use a workflow where the runtime has
one, otherwise native subagents, when the work has dependent steps, loops or
parallel parts. With "Orchestrator session" enabled, every sweep, including
self-contained design work, also takes that route. Start independent tasks
together. Writers on disjoint files may run in parallel in one working tree,
with one committer staging and committing for all of them. Serialize writers
whose files overlap; use separate worktrees when they need different bases.

One delegate on a model the launching runtime can reach goes through the first
technique in the family table's Launch column for the launching runtime that is
in the launching session's tool list; Claude's Agent tool with a generated agent
file pins the family's full model id and the family default effort when its
agent-file format accepts it, including cross-vendor models published in its
picker. Bind the canonical launch effort explicitly when the file omits it or
fallback changes it; intentional null omits the actual effort pin. Name the
family with `subagent_type`; a plain Agent call without a file stays
alias-locked and is not listed. A family without a generated file uses the next
listed technique, such as the Workflow tool or an external launcher
(`claude -p`, `codex exec`).

Use another vendor's harness for a model the launching runtime can reach only
when that harness runs the whole multi-step job itself: hand the entire job to
one delegate there that can run its own subagents (the table's "Runs own
subagents" column), such as Codex orchestrating a three-check review with GLM. A
model no technique of the launching runtime reaches keeps the Launch column's
external technique for one delegate, a single cross-vendor reviewer included. If
that column says unknown, probe it in the launcher you plan to use before
relying on it. If no runtime can, an interactive orchestrator runs the steps
from its launching session:

1. Use the launching session's workflow tool, if it has one.
2. Otherwise run the steps yourself: launch each external worker, wait for it,
   check its output, then start the next step, such as the reviewer.

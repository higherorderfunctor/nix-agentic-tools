Treat an assigned repository change, or investigation/design/bulk reading beyond
a quick fact from named documents, as substantive. Prepare the rubric from the
task goal as preflight; this does not authorize task-source investigation.
Before that investigation, use this runtime's rendered helper with
`--role planner --launch-context <json-path>` with taskSummary, nullable
proposerFamily, nonInteractive, compact role requests and observed techniques to
select a reachable, fitted strong/frontier planner, trying shared avoided-family
fallback before declaring no qualified route. Pin its model and effort from a
canonical candidate, pass the task, source paths, saved rubric and the resolved
routing/workflow context. Use a native subagent or workflow when
non-interactive; if no qualified pinned planner is reachable, report a loop
failure rather than doing the design in the orchestrator. A worker assigned an
approved bounded unit does not recursively plan that assignment. Replan only the
affected portion when scope changes.

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
  pinned routing line), and `brief` (prepared artifact path). Prepare a base
  brief for every reviewer launch, including second-check and judge, before
  returning the plan; preserve the full rubric and relevant review policy,
  leaving earlier-check inputs for the orchestrator to add after those checks
  return. Include every finder, first-check, second-check and judge that will
  run; the helper's floor never proves fit, trial eligibility or independence.
  Each record fixes one launch's technique, model and effort; a dynamic
  workflow's planner may replace them after a fresh helper run. The helper's
  picker applies avoidFor guidance itself; honor the Review step's trial
  restrictions.
- `waves`: ordered lists of unit ids. Put at most ten simultaneous delegates in
  a wave, honoring lower host/user caps. Each unit contributes one concurrent
  delegate because its worker and reviewers run in sequence. Writers in one wave
  own disjoint files on independent branches/parts. A dependency must finish
  writer → independent review → fix/check → orchestrator commit before a later
  wave starts. Units sharing a branch run through that same barrier before the
  next writer. Review wave membership is not permission to launch an entire
  unrevised branch.

Before approving a wave, run the rendered helper with
`--check-plan <plan-path> --launch-context <current-json-path> --role <role>`
repeated for every planned role and `--max-concurrency <host-or-user-cap>` when
below ten. It collects a fresh Reader snapshot and checks role + launching
runtime + candidate + pinned line, dependency cycles/order, exact normalized
file overlap, wave bounds and rubric bytes in every prepared brief. A zero exit
with `validation.status = "valid"` approves only those current specifications;
the orchestrator must still enforce review/commit barriers and verify receipts.
Read the returned exclusions and warnings. An all-pools-unmeasured fit-only
decision remains possible with explicit budget/session uncertainty; an
unresolved model, unsupported effort or technique never becomes an approved
launch. Intentional null effort is resolved: preserve JSON null and omit the
actual effort argument, flag or pin. Preserve canonical fallback metadata with
each selected launch; current candidate equality validates it without worker
binding. Manual-only routes stay outside automatic approval; handle an explicit
user request separately under its authorization.

The saved helper snapshot records provenance and is never an allowlist or proof
of current pace. A saved plan is not permission to skip the helper: rerun it as
Choose execution requires. Changed launch context or a new usage read requires
validation against the current helper output; use that returned snapshot for
execution. Do not add age limits or fingerprints of unrelated configuration. A
downstream delegate that launches work in another runtime needs a separate
plan/check using that runtime's rendered helper and session pool, even if a
planner in another harness prepares it. The helper validates specifications and
reads registered Readers; it never executes a delegate or probe.

Execution constraints remain compulsory: Choose execution owns launch selection,
supervision, retries, isolation and named fallbacks; Work owns hard-rules
briefs; Review owns independence and trial limits; Validate the result owns
receipts and evidence. Attach the relevant resolved execution policy to each
prepared brief. Every external-launch brief says the delegate is non-interactive
and reports to an orchestrator, not a person; a non-interactive delegate never
launches external delegates. The orchestrator enforces these constraints before
launching and checks the working tree after every delegate with shell access.

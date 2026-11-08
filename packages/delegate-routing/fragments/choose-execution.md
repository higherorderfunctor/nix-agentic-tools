List the parts of the work before choosing execution. Size each part with the
Work and review rubric's Size row and follow that row's split rule. Checks,
tests and docs that exist only for a part ship in the same change as that part,
so a split never moves a part's tests to another PR. Name the files each part
writes and its dependencies.

Run at most ten delegates at once in one fan-out. Drain the rest through fixed
waves or a pool capped at ten, never through the runtime's own concurrency
limit, which can be higher. A wider fan-out once exhausted host memory and every
running delegate lost its work. Never give a reviewer or analyst a writable
working tree that holds uncommitted work: give it its own worktree, read-only
tools, or a commit to review. After any delegate with shell access ends, check
the working tree before continuing. A reviewer once restored files in a shared
tree and silently reverted edits.

Change a running delegate's task with a new brief rather than stopping it. Stop
one only when its next step would do damage, such as pushing to a merged branch,
and salvage its diff first. Finished work outside the intended scope, or done
after its PR merged, becomes a new PR on a fresh branch and is never discarded.

Write every brief file before launching. Launch long external runs detached so
they outlive the launching step, and wait on their exit. Tell reviewers how to
address paths outside the repository: absolute paths and `git -C`. On a
transient 5xx from a provider, rerun on another pool instead of looping. When a
vendor's safety filter refuses a brief, route the task to another vendor; never
retry it or reword it to get past the filter. Check whether a model answers only
with a tool-less probe agent or a direct API call, never with an ordinary
workflow agent.

Use a tool from the table that exists in this session's mode. A single
self-contained task needs one delegate. Use a workflow where the runtime has
one, otherwise native subagents, when the work has dependent steps, loops or
parallel parts. With "Orchestrator session" enabled, every sweep, including
self-contained design work, also takes that route. Start independent tasks
together. Writers on disjoint files may run in parallel in one working tree,
with one committer staging and committing for all of them. Serialize writers
whose files overlap; use separate worktrees when they need different bases.

One delegate on a model this runtime can reach goes through the first technique
in the family table's Launch column for this runtime that is in your tool list;
Claude's Agent tool with a generated agent file pins the family's full model id
and default effort, including cross-vendor models published in its picker. Name
the family with `subagent_type`; a plain Agent call without a file stays
alias-locked and is not listed. A family without a generated file uses the next
listed technique, such as the Workflow tool or an external launcher
(`claude -p`, `codex exec`). Launch delegate CLIs from the current directory.
That directory decides their permissions and configuration. Say in every
external launch brief that the delegate is non-interactive and reports to an
orchestrator, not a person.

A non-interactive or external delegate does not launch external delegates. It
may use its own runtime's native subagent and workflow tools. This limit governs
every launch recommendation in this skill; report an unreachable model to the
orchestrator.

Use another vendor's harness for a model this runtime can reach only when that
harness runs the whole multi-step job itself: hand the entire job to one
delegate there that can run its own subagents (the table's "Runs own subagents"
column), such as Codex orchestrating a three-check review with GLM. A model no
technique of this runtime reaches keeps the Launch column's external technique
for one delegate, a single cross-vendor reviewer included. If that column says
unknown, probe it in the launcher you plan to use before relying on it. If no
runtime can, an interactive orchestrator runs the steps from this session:

1. Use this session's workflow tool, if it has one.
2. Otherwise run the steps yourself: launch each external worker, wait for it,
   check its output, then start the next step, such as the reviewer.

## Orchestrator handoff

Save compulsory execution constraints alongside the plan for the orchestrator to
read before launching each wave. Include the applicable handoff, supervision,
routing, pool, source-steering and evidence clauses from this reference and the
resolved workflow; relevant clauses also travel in each prepared worker/reviewer
brief.

Task source is the code or documents the work will change. Reading what the user
pointed at, such as a board or issue, to triage and write the brief is fine
before handoff. Hand off before investigating task source; gather quick facts in
this session only while that delegate runs. Loading delegate-routing and running
its usage reads before the launch are part of the handoff, not quick facts. A
sweep is the deep check or investigation; design work, such as choosing a new
setting, is a sweep however little code it needs. Keep this session for talking
with the user, deciding, and checking results.

Hand bulk reading, searching, measuring, tracing, edit-and-test loops, file
moves and document writing to delegates. Give each delegate one task: one part
of the system, or one question. Have them write large output to files and report
a short summary with evidence. Stay on the current item until it is done or
blocked.

Read a delegate's summary and only the output lines it cites, never its whole
result. Point the next delegate at a file path instead of pasting content into
its brief.

## Rule steering

The resolved planner reference lists the models and tools you can use, and how
to set model and effort for each.

Delegate-routing owns these delegation and review rules; the small router is
their always-on entrypoint. When someone steers how they should work, propose a
change to their source — the delegate-routing package's fragments, or for a
consumer its `ai.programs.delegate-routing` routing and workflows entries — so
it is committed and distributed. Do not edit a rendered rule or skill file, and
do not record that steering in memory or as a house rule that changes how the
skill is read.

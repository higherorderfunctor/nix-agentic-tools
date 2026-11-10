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

Use a tool that exists in this session's mode. A single self-contained task
needs one delegate. Use a workflow where the runtime has one, otherwise native
subagents, when the work has dependent steps, loops or parallel parts. With
"Orchestrator session" enabled, every sweep, including self-contained design
work, also takes that route. Start independent tasks together. Writers on
disjoint files may run in parallel in one working tree, with one committer
staging and committing for all of them. Serialize writers whose files overlap;
use separate worktrees when they need different bases.

Choose the launch path by what this session shows it can do, never by runtime
name. Observed tools and configuration decide availability: use a technique only
when it is in your tool list or its command is on PATH. Report what you observed
in the helper's launch context. Every launch fixes technique, model and effort
from one helper line, bound exactly. Before dispatch, rerun the helper before
every launch (each subagent call or new workflow).

- **Native subagents only:** you invoke the helper, then bind the returned fixed
  technique, model and effort in each subagent call.
- **Static workflow** (the script is fixed once it starts): a planner delegate
  returns the plan and the caller that launches the workflow builds it from that
  plan with fixed values. A static workflow's picks stay fixed for that run and
  the next launch reruns the helper. Never mutate a running one.
- **Dynamic workflow** (a planner inside the workflow chooses later steps): the
  planner reruns the helper between steps and fixes every dispatch's values from
  that fresh result.

Launch delegate CLIs from the current directory. That directory decides their
permissions and configuration. Say in every external launch brief that the
delegate is non-interactive and reports to an orchestrator, not a person.

A non-interactive or external delegate does not launch external delegates. It
may use its own runtime's native subagent and workflow tools. This limit governs
every launch recommendation in this skill; report an unreachable model to the
orchestrator.

Use another vendor's harness for a model this runtime can reach only when that
harness runs the whole multi-step job itself: hand the entire job to one
delegate there that can run its own subagents, such as one that orchestrates a
three-check review with another vendor's model. A model no technique of this
runtime reaches takes the helper's external line for one delegate, a single
cross-vendor reviewer included. If no runtime can, an interactive orchestrator
runs the steps from this session:

1. Use this session's workflow tool, if it has one.
2. Otherwise run the steps yourself: launch each external worker, wait for it,
   check its output, then start the next step, such as the reviewer.

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

Write every brief file before launching. Tell reviewers how to address paths
outside the repository: absolute paths and `git -C`. On a transient 5xx from a
provider, rerun on another pool instead of looping. When a vendor's safety
filter refuses a brief, route the task to another vendor; never retry it or
reword it to get past the filter. Check whether a model answers only with a
tool-less probe agent or a direct API call, never with an ordinary workflow
agent.

On a rate limit, wait out the stated reset or cooldown, or back off when none is
stated, then retry. Exclude a pool's families in the helper launch context only
while its usage reads 100% used, until that window resets.

When local validation cannot run, such as a held shared lock or an unreachable
cache, push the reviewed unit or branch and let CI run its checks instead of
working around the block. CI's result is that unit's check: dependent work still
waits for it.

Use this session's native subagent tool for one self-contained task. Use its
native workflow tool, where it has one, for dependent steps, whole write-review
loops and parallel parts; without one, run those steps with native subagent
calls. With "Orchestrator session" enabled, every sweep, including
self-contained design work, also takes that route. Start independent tasks
together. Writers on disjoint files may run in parallel in one working tree,
with one committer staging and committing for all of them. Serialize writers
whose files overlap; use separate worktrees when they need different bases.

Offer the helper every native technique and model this session shows it can pin.
Observed tools and configuration decide availability, not runtime or model
family names. Report what you observed in the helper's launch context. Every
launch fixes technique, model and effort from one helper line, bound exactly; a
named user request wins. Rerun the helper before every launch (each subagent
call or new workflow).

- **Native subagents only:** you invoke the helper, then bind the returned fixed
  technique, model and effort in each subagent call.
- **Static workflow** (the script is fixed once it starts): a planner delegate
  returns the plan and the caller that launches the workflow builds it from that
  plan with fixed values. A static workflow's picks stay fixed for that run and
  the next launch reruns the helper. Never mutate a running one.
- **Dynamic workflow** (a planner inside the workflow chooses later steps): the
  planner reruns the helper between steps and fixes every dispatch's values from
  that fresh result.

External CLIs such as `codex exec` are manual techniques for probes and fixture
testing, not fallback routes for work. Run a manual probe from the intended
launch directory, which determines permissions and configuration. If no native
technique reaches a qualified model, report the gap instead of shelling out. A
delegate never launches external CLIs; it may use its own runtime's native
subagent and workflow tools.

Every work workflow's script carries its own guards:

- **Ceiling:** a token limit it can enforce, or a maximum number of agent calls
  if it cannot meter tokens. Check it before each dispatch; a turn budget alone
  is not enough.
- **Size:** after each unit, script code checks the Size row's running total and
  compares each changed file's resulting size with its planned target. Measure
  final lengths against those targets, not preexisting lines or net shrinkage.
- **Scope judge:** at the first unit and periodically after it, a fresh agent
  that did not write the work judges scope and size against the approved plan
  and agreed design.

The workflow returns early:

- at the first unit, for the orchestrator's first-diff check;
- on a ceiling, Size trigger, missed file target or scope-creep verdict.

It returns completed unit IDs, artifact paths, measured sizes and the judge's
evidence. The orchestrator verifies those artifacts and settles the next step
before resuming from the finished run where the workflow tool supports it;
completed agents replay from cache.

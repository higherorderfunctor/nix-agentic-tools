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

Launch delegate CLIs from the current directory. That directory decides their
permissions and configuration. Say in every external launch brief that the
delegate is non-interactive and reports to an orchestrator, not a person.

A non-interactive or external delegate does not launch external delegates. It
may use its own runtime's native subagent and workflow tools. This limit governs
every launch recommendation in delegate-routing; report an unreachable model to
the orchestrator.

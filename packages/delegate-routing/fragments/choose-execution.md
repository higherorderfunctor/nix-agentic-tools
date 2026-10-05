Use a tool from the table that exists in this session's mode. A single
self-contained task needs one delegate. Use a workflow when the work has
dependent steps, loops or parallel parts. Start independent tasks together. Run
writers that share a working tree one at a time.

When another runtime should do a multi-step job, hand the whole job to one
orchestrator delegate there, meaning a delegate that runs its own subagents. The
"Runs own subagents" column records this capability for each mode. Unknown
requires a probe in the intended launcher before relying on it. If none can,
orchestrate from this session with the best option it has:

1. This session's workflow tool, if it has one.
2. Otherwise run the steps yourself: launch each external worker, wait for it,
   check its output, then start the next step, such as the reviewer.

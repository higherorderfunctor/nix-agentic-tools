Use a tool from the table that exists in this session's mode. A single
self-contained task needs one delegate. Use a workflow when the work has
dependent steps, loops or parallel parts. Start independent tasks together. Run
writers that share a working tree one at a time. Launch delegate CLIs from the
current directory. That directory decides their permissions and configuration.
Say in every external launch brief that the delegate is non-interactive and
reports to an orchestrator, not a person.

To give another runtime a multi-step job, hand the whole job to one delegate
there that can run its own subagents (the table's "Runs own subagents" column).
If that column says unknown, probe it in the launcher you plan to use before
relying on it. If no runtime can, orchestrate from this session:

1. Use this session's workflow tool, if it has one.
2. Otherwise run the steps yourself: launch each external worker, wait for it,
   check its output, then start the next step, such as the reviewer.

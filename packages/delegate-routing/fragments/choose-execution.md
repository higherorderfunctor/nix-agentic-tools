List the parts of the work before choosing execution. Size each part with the
Work and review rubric's Size row and follow that row's split rule. Checks,
tests and docs that exist only for a part ship in the same change as that part,
so a split never moves a part's tests to another PR. Name the files each part
writes and its dependencies.

Use a tool from the table that exists in this session's mode. A single
self-contained task needs one delegate. Use a workflow when the work has
dependent steps, loops or parallel parts. Start independent tasks together.
Writers on disjoint files may run in parallel in one working tree, with one
committer staging and committing for all of them. Serialize writers whose files
overlap; use separate worktrees when they need different bases.

One delegate on a model this runtime can reach goes through this runtime's
technique named in the family table's Launch column; in Claude that is a
single-node Workflow, since Agent pins only a model alias and never effort, and
`claude -p` only when there is no Workflow tool. Launch delegate CLIs from the
current directory. That directory decides their permissions and configuration.
Say in every external launch brief that the delegate is non-interactive and
reports to an orchestrator, not a person.

Use another vendor's harness for a model this runtime can reach only when that
harness runs the whole multi-step job itself: hand the entire job to one
delegate there that can run its own subagents (the table's "Runs own subagents"
column), such as Codex orchestrating a three-check review with GLM. A model no
technique of this runtime reaches keeps the Launch column's external technique
for one delegate, a single cross-vendor reviewer included. If that column says
unknown, probe it in the launcher you plan to use before relying on it. If no
runtime can, orchestrate from this session:

1. Use this session's workflow tool, if it has one.
2. Otherwise run the steps yourself: launch each external worker, wait for it,
   check its output, then start the next step, such as the reviewer.

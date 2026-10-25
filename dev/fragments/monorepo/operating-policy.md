## Repository operating policy

> **Last verified:** 2026-10-25 — the monorepo category loads these decisions;
> the linked guides retain procedures, rationale and settled evidence and must
> be read before the actions named below.

### Repository writes and Git operations

Before planning a repository change or writing the first repo-destined file,
read [Git Workflow](dev/fragments/monorepo/git-workflow.md). Read it again
before creating a worktree, planning commits, pushing, rebasing, changing hooks
or repository settings, handling bot updates, or cleaning up a merged PR if it
is not already in your current context. Its settled constraints remain binding.

Every change goes through an isolated worktree and PR. This includes untracked
drafts; only a session scratchpad outside the repository is exempt. Before the
first write, run `git rev-parse --path-format=absolute --git-dir`: a path ending
in `.git/worktrees/<slug>` is a linked worktree; the primary checkout's `.git`
means create a worktree first. The primary checkout belongs to the operator.

Create worktrees from `origin/main` beside the primary checkout, deriving their
parent from the absolute Git common directory as the guide specifies. Do not
bootstrap them by default. Hook configuration comes from the launch checkout;
hook state comes from the committing worktree. A branch adding a local gate
still gets its own CI validation. Materialize a worktree only to test its devenv
output; never bypass missing hook configuration. Keep the shared hooks path and
serialize stack operations against the shared branchless database.

Use the existing `stack-*` skills for operations they cover. Push the first
commit and subsequent work as it lands. Amend an existing PR for its own review
fixes, intended follow-ups and defects; open another PR only for unrelated work.
Before rewriting history, push a backup under `archive/<slug>/<what>` to
`origin` in the same command sequence. Local tags and branches are unsafe
backups. Regenerate conflicting lockfiles; never hand-merge them.

Human PRs are squash-merged by the operator. Bot `update/*` PRs auto-merge after
required checks and review-thread resolution; do not restore a manual batch
merge path. Once a PR merges, its implementing agent removes its worktree, local
branch and `archive/<slug>/*` backup refs before declaring completion. Retain
backups when a PR closes unmerged until the operator says otherwise.

Before writing shared agent memory, read the guide's **What is shared across
worktrees — and what is not** section. List recent memory files and search the
concept before choosing a filename; extend an existing record rather than
creating a concurrent duplicate.

### PR ownership and review

Before opening or updating a PR against `main`, pushing to one, responding to
review, or investigating its checks, load the `pr-review-loop` skill and the Git
Workflow guide above. Own the loop through green checks and completed review, or
a decision only the operator can make. Never end on an unarmed promise to check
later: run the skill's background watcher for the pushed head, react to its
first failure, read the failing log, fix and re-arm. An empty check list with
`mergeStateStatus: DIRTY` means rebase, not wait.

Open ready when dev-complete; reserve drafts for WIP or an explicit preview.
Copilot automatically reviews once when a PR becomes ready. Never request the
first review manually or infer a missed trigger from an ordinary push. Read both
inline threads and the whole review body, including suppressed findings. Reply
to and resolve each gating thread in the same turn as its fix.

Re-request only for new scope, a new mechanism, or an approach rewritten since
the last review. Applying findings, rewording, formatting and renaming do not
qualify. Further paid review needs such a change or the operator's instruction.
Do not restore the Devenv Diagnostic as a required or automatic PR context; read
the guide's evidence and the live ruleset before changing repository gates.

Use a separate reviewer from a different vendor when Copilot errors, lacks
quota, never reviewed a draft, or the change since its last review meets the
re-request test. Give requirements and the diff; the PR body is not evidence.
Report dismissed findings as well as fixes. Never review your own diff.

For work going to `main`, use delegate-routing's **Work and review** workflow.
Use its three blind checks when dismissing a reviewer finding, or when a diff
touches `lib/**`, `packages/*/lib/**`, `packages/*/patches/**`,
`packages/*/packages/**/*.nix`, or adds, removes or retypes a `mkOption` under
`packages/*/modules/**` or `lib/ai/**`. Otherwise use one reviewer. Drafts and
unsettled experiment branches forgo this escalation. Run these checks locally,
never through github.com Copilot, and size each role separately. Do not route
escalation on an undefined judgment of "complexity".

### Instruction and validation changes

Before changing instruction sources, their registration, generation or delivery,
read [Architecture Fragments](dev/fragments/monorepo/architecture-fragments.md)
and the applicable path-scoped pipeline guidance. Before changing an abstraction
a fragment describes, read that fragment and update it in the same commit.

Edit authoritative sources, never generated instruction projections. Use owner
registries for package categories and `config/fragment-categories.nix` for
workspace categories. Keep one current verification marker; retain settled
rejections and their evidence, not a changelog. Add fragments for non-inferable
knowledge, not signatures or ephemeral work. Target fewer than 150 lines per
fragment and split longer topics by concern. Regenerate after source or registry
changes with `devenv tasks run --mode before generate:all`; `--mode before` is
required to run dependency leaves. Sync input locks separately with
`devenv update <input>` when needed.

Before changing hooks, validators, formatter configuration, or diagnostic and
shell-activation wiring, read [Linting](dev/fragments/monorepo/linting.md) and
the Git Workflow guide's shared-hook rules. `config/repo-validation.nix` owns
validation policy; every local validator needs its declared CI backend.
`nix flake check` is authoritative; local changeset success or a bypassed hook
does not prove corpus correctness. Treefmt formats and lints nothing. Keep
corpus diagnostics off shell activation; the diagnostic hook runner must
explicitly request the manual stage.

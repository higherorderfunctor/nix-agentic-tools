# Diagnosing dependency update CI

The design lives in
[CI Update Workflow](../dev/fragments/pipeline/ci-update-workflow.md) and
[Update Pipeline Architecture](../dev/fragments/pipeline/update-pipeline.md).
This guide records operational evidence and the traps that matter when checking
a sweep. It does not replace the workflow or scripts as the source of truth.

## Establish what actually ran

Check the workflow run's head SHA and start time before attributing it to a
change. A scheduled run that starts before a merge keeps the older workflow even
if it publishes PRs after that merge. Compare end-to-end wall time separately
from summed job time and individual job durations; matrix parallelism reduces
wall time while spending more runner time.

Download the `update-receipt-*` artifacts and compare their `name`, `base`,
`status`, and `touched` fields with that run's discovered matrix. The target
count changes with the registry; do not assume the rollout's 52 targets forever.
Paginate artifact listings: the first production sweep had 104 artifacts, more
than one 100-item API page, because reports and receipts are separate artifacts.

- `HELD BACK` preserves an existing branch and can appear in a green sweep.
  Inspect the corresponding `update-report-*` artifact for the preparation
  failure before declaring the update healthy.
- `NO UPDATES` means the target produced no diff from the pinned base.
- `UPDATED` means preparation completed and publication returned successfully;
  inspect the PR and publisher log for whether it was created, refreshed,
  unchanged, or preserved by an ownership/human-hold guard. It does not prove
  the PR passed its native checks or merged.

The collector requires exactly one receipt per discovered target on the same
base. Missing or duplicate receipts are incomplete evidence, even if some PRs
already merged. Inspect cleanup's job and steps as well as its outcome: a
cancelled sweep must not perform stale cleanup. Successful cleanup can keep
touched or protected PRs, close and delete untouched bot-only proposals, or
reopen a PR after detecting a race. Inspect the log to establish which paths
actually ran; success alone does not show that deletion or recovery was
exercised.

## Distinguish the failure phase

Preparation uses the workflow token; publication mints a fresh App token. Locate
the failing command before treating every GitHub error as the original one-hour
publishing-token expiry. In
[run 34817177152](https://github.com/higherorderfunctor/nix-agentic-tools/actions/runs/34817177152),
a native PR check failed fetching a nixpkgs tarball with HTTP 403,
`Resource not accessible by integration`. The next sweep refreshed the same
[GitLab MCP PR #1662](https://github.com/higherorderfunctor/nix-agentic-tools/pull/1662),
which then passed and auto-merged. The failed fetch's cause was not established;
that recovery does not prove a permanent authentication fix.

Prefer receipt JSON and actual failing job output to keyword counts across a
whole log. GitHub echoes shell bodies containing `echo "::error::..."` before
executing them; those lines are not evidence that the error occurred. GitHub CLI
can also label aggregated output `UNKNOWN STEP`, so use job IDs and step
metadata when identifying the failing phase.

## Retrying a sweep

A rerun of selected failed jobs depends on retained receipts from successful
siblings and a matching discovery base. A
[single-worker retry of run 34760253804, attempt 2](https://github.com/higherorderfunctor/nix-agentic-tools/actions/runs/34760253804/attempts/2)
reran `sympy-mcp` and dependent cleanup: same-name artifact uploads succeeded,
and cleanup collected all 52 receipts including the other 51 workers' retained
receipts. This is a measured platform behavior, not permission to weaken the
collector if artifacts are missing or expired. A fresh full dispatch starts a
new sweep and can restore complete coverage; a target-subset dispatch skips
stale cleanup.

## Rollout baseline, 2026-09-14

[PR #1637](https://github.com/higherorderfunctor/nix-agentic-tools/pull/1637)
merged at 07:13 UTC. The first scheduled run using the merged implementation
started at 12:29 UTC:

| Run                                                                                                           | Observed result                                                                                        |
| ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| [Update 34843679511](https://github.com/higherorderfunctor/nix-agentic-tools/actions/runs/34843679511)        | 19m07s wall time; 52 matching-base receipts, 46 unchanged, six updated, none held back; cleanup passed |
| [Nixpkgs PR CI 34844559243](https://github.com/higherorderfunctor/nix-agentic-tools/actions/runs/34844559243) | 14m25s wall time; all 16 jobs passed                                                                   |
| [Oxlint PR CI 34845250183](https://github.com/higherorderfunctor/nix-agentic-tools/actions/runs/34845250183)  | 25m22s wall time; all 16 jobs passed                                                                   |

The sweep created five PRs and refreshed #1662; all six passed checks and
auto-merged. Two merged before the sweep finished without changing its pinned
base or interrupting the remaining workers. These are historical observations
with existing cache coverage, not empty-cache benchmarks or a guarantee about
future runtimes. Cancellation and persistent reopen failures also have dedicated
fixtures; the green baseline did not exercise every race or recovery path.

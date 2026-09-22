## CI Update Workflow

> **Last verified:** 2026-09-21 — publication retries briefly when a newly
> pushed App branch has no queryable activity row or its PR view is unavailable.
> Identity mismatches still fail immediately, and auto-merge intent is rechecked
> before arming.
>
> **Settled — do not relitigate.** Run `34710827449` timed out before the
> package-layout refactor. The same oxlint derivation appeared before and after
> it. Reports advanced from 39 to 48 across the failed sweeps; the unchanged
> rerun of `34729241702` finished preparation in 6m53s with cache hits. These
> failures involved cold compilation and an expired publishing token, not a
> demonstrated layout-induced cache invalidation.
>
> Full lineage:
> `git show ff610ca0:dev/fragments/pipeline/ci-update-workflow.md`.

### Independent preparation and publication

`update.yml` runs four times daily and supports `workflow_dispatch`. Discovery
pins one `main` SHA, reads root inputs from `flake.lock`, and evaluates the
owner registry's `.#updateTargets`. Every input and package becomes one Linux
matrix worker, with eight concurrent workers and `fail-fast: false`. The Ninja
DAG remains the local update entrypoint; its ordering edges do not transfer
changes between isolated branches, so CI workers need no cross-target edges.

Each worker runs the existing `update-input.sh` or `update-pkg.sh` in an
ephemeral worktree and publishes its own `update/<name>` branch. A slow or
failed worker cannot discard other workers' completed PRs. Branch names remain
stable, existing PRs are reused, and every sweep rebuilds bot changes on the
pinned main base.

**A PR must already contain its locks, source and dependency hashes, extracted
files, and formatting. Branch CI only validates; it never mutates a branch to
finish an update.** The package worker skips only the final informational full
build (`NAT_UPDATE_VERIFY_PACKAGES=0`). Hash derivation and embedded-file
extraction still run before publication. Input workers retain build verification
and its hash-repair pass because those repairs can mutate the prepared branch. A
writable update may open with failing build checks; an incomplete update is held
back and its existing PR is preserved.

`update-matrix.py` requires a normal target return and exactly one final report
before permitting publication. An early rev/source commit alone proves nothing:
main-tracking packages create it before refreshing dependency hashes. A timeout
must therefore never publish that worker's partial branch. Completed siblings
publish independently; no `always()` publication of an interrupted worker is
needed. Diagnostics still upload on failure or cancellation.

Each worker has a 120-minute job ceiling, with preparation and setup sharing 105
minutes from its first step. The remaining budget is reserved for publishing and
cache finalization. CI sets one build and one evaluator per runner, with a 4 GiB
evaluator ceiling and all native compiler cores. The common script's optional
evaluator caps only reduce its existing resource bounds. Local Ninja keeps its
coupled target/evaluator limits and informational package builds. Rust release
profiles, fat LTO, and binary performance settings do not change.

### Authentication and experimental dispatches

Preparation uses the job's read-only `GITHUB_TOKEN` for upstream rate limits.
The workflow-level permission declaration grants repository contents read and no
pull-request write access; branch and PR mutations require the separately minted
App token. App installation tokens expire after one hour: minting one at startup
caused both public-upstream Git authentication errors and failed PR publication
in the original long sweeps. Every worker now mints its App token immediately
before publishing and runs `gh auth setup-git`. Both checkouts disable persisted
credentials so an old Authorization header cannot override the fresh helper.
App-authored PRs trigger CI automatically; using the default workflow token for
publication can require manual approval.

Automation is checked out into `automation/` from the selected workflow ref. The
repository being updated is a separate `source/` checkout of discovery's pinned
**main** SHA. Scripts run from automation with source as their working
directory. Dispatching an experimental workflow therefore cannot carry the
workflow rework itself into an auto-merging dependency PR.

All workflow refs share the same concurrency group as scheduled main sweeps
because they publish the same `update/*` branches. A newer scheduled or manual
Update run cancels the older run. Main and PR CI use a separate group per ref;
they neither wait for nor cancel Update. Merges during a sweep do not change its
pinned base or remaining target roster. The optional comma-separated `targets`
dispatch input selects a bounded subset and disables stale cleanup. The warm-IFD
and bot-identity actions accept the source checkout path explicitly; composite
actions do not inherit the workflow's run working directory.

### Renovate-style branch and cleanup protections

`update-publish.sh` compares stable patch IDs and merge bases. It skips a push
only when the patch is identical, the remote branch already uses the current
base, and the PR is not conflicting. A behind-base or conflicting bot branch is
rebuilt and pushed. Unchanged and human-protected PRs remain recorded as
touched.

Only same-repository App-authored PRs may be edited or armed. Open PR discovery
spans every base: a PR targeting a branch other than `main` preserves the shared
stable branch and cannot be replaced by a new `main` proposal. Fork PRs with the
same branch name are ignored, and human-owned PRs on the internal branch are
preserved. Before either rewriting or deleting a branch, `update-github.py`
requires GitHub's repository activity to identify the update App as the pusher
of that exact ref and head SHA. Commit metadata alone cannot prove ownership.
Remote commits with a different author OR committer also prevent a rewrite; a
human amend can retain the original bot author. Pushes use an explicit
force-with-lease against the observed remote SHA to protect concurrent changes.

Before any existing App PR can be re-armed, publication reads its latest
auto-merge timeline event. An explicit human disable is retained through a safe
behind-base branch refresh and title edit; only the re-arm is skipped. An
automatic disable with a GitHub reason, a bot disable, or a PR that has never
been armed can still self-heal, and ordinary comments and reviews that do not
block merging remain allowed. Immediately before arming, publication rechecks
the current PR's repository, target base, App ownership, exact expected head,
push actor, and commit identities. A changed or unverified head blocks the arm,
preserves the ref, and fails the worker without changing an existing auto-merge
request. An unavailable PR view or an empty repository activity result gets up
to five reads, two seconds apart; a visible wrong identity, head, or pusher
fails immediately. The final PR read validates `autoMergeRequest`, and the
latest auto-merge event is checked again before a new enable. An existing
request is retained without a redundant enable/rollback attempt, while a newly
attempted request may still be disabled after an ambiguous enable failure. A
human or unverifiable pusher discovered before patch comparison also preserves
and touches the branch without changing its merge state. Pusher and commit
identity authorize destructive ref updates; only an explicit human auto-merge
disable expresses a merge-state hold. The merge command also receives
`--match-head-commit`.

Before creating an absent open proposal, publication inspects the most recent
closed same-repository App PR for that base and stable head. A bot cleanup close
may be recreated. A human close preserves an equivalent patch, but does not
suppress a materially newer dependency patch. The publisher fetches the closed
PR's immutable `refs/pull/<number>/head` into `FETCH_HEAD` and requires it to
equal the list API's `headRefOid` before comparing patch IDs, so a fresh worker
does not depend on a deleted branch's object remaining reachable. Missing close
metadata, an unavailable pull ref, or an OID mismatch fails closed. A completed
`NO UPDATES` result means no diff from pinned main and returns without
publication; a still-needed unmerged update is reconstructed before the
unchanged-patch comparison. A PR-list, creation, or arming failure fails only
that worker and prevents its successful receipt; other matrix workers continue.
GitHub's squash auto-merge still waits for required checks and unresolved
review-thread rules.

Cleanup starts after every worker reaches a terminal state unless the sweep was
cancelled. An optional diagnostics upload failure after its successful receipt
upload still permits cleanup; the worker failure remains visible in the workflow
result. The `!cancelled()` status guard permits that failure path without
keeping stale cleanup running after a replacement sweep cancels this run.
`update-matrix.py collect` requires exactly one receipt for every discovered
target, all on the pinned base, and writes the complete-sweep sentinel. Missing,
duplicate, or foreign receipts prevent cleanup. Updated and held-back targets
must preserve their branch in the touched list. `update-cleanup.sh` refuses to
close anything without that sentinel.

Stale PRs are closed and their branches deleted only when their author, commit
authors and committers, reviews, issue comments, and inline review-thread
replies are all known bots. The thread scan paginates and preserves a PR if a
nested discussion is truncated. Human or unmapped identities preserve the PR.
Committers require the paginated REST commits endpoint because
`gh pr view --json commits` omits them. Lists that reach an API or CLI cap are
treated as incomplete and cannot authorize deletion. The PR scan explicitly
raises the CLI's default 30-item limit; a mass update must not silently hide
older candidates.

Cleanup closes the PR, rechecks activity, its head, target base, and that it
remains closed, then deletes the observed head with a force lease. A new human
comment or review during closure reopens the PR without deleting the branch. A
changed head, unknown activity, or failed deletion also reopens it. Reopening
gets three bounded attempts; a persistent failure names the closed PR and
preserved branch in the log, lets cleanup examine the remaining candidates, and
leaves the workflow red after the sweep. Bot login forms differ between App and
User API surfaces; keep both forms in the allowlist. Human engagement and commit
protection are separate checks.

### Native package build shards

`ci.yml` distributes every eligible package across five shards per native
platform. New exports enter the sorted partition automatically. Each runner
builds one derivation at a time using all cores. The macOS nixpkgs failure in
run `34732693179` did not start oxlint until minute 44 because other package
builds occupied its slots. Sharding removes most of that queue, and a 120-minute
worker ceiling accommodates a cold shard without changing optimization flags.

`ci-packages.py` checks every selected evaluation and requires a successful
build or cache hit. Empty, failed, skipped, or incomplete results fail. Coverage
receipts must agree on the package universe and assign every package exactly
once. The existing required `build (x86_64-linux, ubuntu-latest)` and
`build (aarch64-darwin, macos-latest)` contexts check worker outcomes and
complete native coverage. Both fail if any worker fails, including a failure
after receipt upload. The two dedicated `kiro-patched` jobs, `test`, and
`gitleaks` remain the other four required contexts. The full Devenv Diagnostic
remains manual-only; its extracted deterministic contracts remain in `test`.

Generated documents stay in the flake checks. Patched proprietary Kiro stays in
its dedicated native jobs without cache publication; the update workers retain
Cachix's `pushFilter: kiro-cli`. Numtide substitution remains confined to
package build runners through job-level `NIX_CONFIG`, which survives
cachix-action's configuration override. On authenticated main builds, only the
shard containing Semble mirrors its runtime closure into the project cache and
checks its narinfo.

The Cachix action owns shard uploads and its finalization remains part of the
worker outcome. Do not also start nix-fast-build's optional uploader: its
duplicate daemon required forced shutdowns in passing macOS jobs. This is
separate from the old single-user store migration deadlock, which the shared
multi-user Nix installer fixed.

### Reports and deliberate manual updates

Each worker uploads its report and preparation logs, plus a separate receipt
only after successful publication. The workflow runs the upstream Copilot SEA,
new pnpm major, and patched aihubmix-mcp detectors once per sweep. They remain
informational warnings and do not open PRs. Derive compared versions from the
repository; stable pnpm detection must use `latest-<N>`, not prerelease
`next-<N>` tags. A local patch against published build output requires human
re-authoring and must not quietly become a swept hash-only update.

For receipt-based diagnosis, retry evidence, and the measured rollout baseline,
read the
[operations guide](https://github.com/higherorderfunctor/nix-agentic-tools/blob/main/docs/update-ci-operations.md).
A green sweep may contain held-back targets, but only once each. The first sweep
that holds a target back warns and stays green; the
`Escalate repeated hold-backs` step fails `cleanup` when the same target is held
back on two consecutive SCHEDULED sweeps. That threshold exists because a
hold-back means no new PR or branch update was written for the attempt, so
branch CI has nothing to judge for it and the condition cannot clear itself. Any
update PR still open on a held-back target is an EARLIER proposal that
publication preserved, not the blocked one. Read receipt statuses before
claiming every update was prepared successfully.

The Python fixture suites exercise package coverage, completion reports, cleanup
receipts, and PR publication against disposable local Git repositories. They run
inside the required `test` job without evaluating or building Nix themselves.

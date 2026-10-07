## CI Update Workflow

> **Last verified:** 2026-10-07 — package build runners use no CI-only
> substituter and no shard mirrors a runtime closure into the project cache.
>
> **Settled — do not relitigate.** Run `34710827449` timed out before the
> package-layout refactor. The same oxlint derivation appeared before and after
> it. Reports advanced from 39 to 48 across the failed sweeps; the unchanged
> rerun of `34729241702` finished preparation in 6m53s with cache hits. These
> failures involved cold compilation and an expired publishing token, not a
> demonstrated layout-induced cache invalidation.
>
> **Settled — do not relitigate.** Taking the first entry of a
> `status=completed` scheduled-run listing as the escalation predecessor failed:
> GitHub served a weeks-old snapshot headed by run `33844722138` (2026-09-04),
> so every hold-back read as a first offense.
>
> Full lineage:
> `git show ff610ca0:dev/fragments/pipeline/ci-update-workflow.md`.

### Independent preparation and publication

`update.yml` runs four times daily and supports `workflow_dispatch`. Discovery
pins one `main` SHA, reads root inputs from `flake.lock`, and evaluates the
owner registry's `.#.updateTargets`. The leading dot makes the attribute path
absolute: Nix skips its package namespace lookup, whose unfree filtering can
force source-derived versions through `meta.position` and `checkedBy`. Keep
`allow-import-from-derivation = false` on discovery.
`checks.update-discovery-ifd-free` runs the actual workflow step against the
real registry with deliberately cold IFD package namespaces, and verifies the
resulting matrix. Every input and package becomes one Linux matrix worker, with
eight concurrent workers and `fail-fast: false`. The Ninja DAG remains the local
update entrypoint; its ordering edges do not transfer changes between isolated
branches, so CI workers need no cross-target edges.

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
back and its existing PR is preserved. A worker whose build verification failed
still publishes and arms auto-merge, uploads its receipt, and then fails in
`Fail on failed build verification` (`update-matrix.py verdict`) with an
`::error::` naming the target, failed attributes and PR -- when that PR is new
or its patch changed. A PR that already proposed the same patch, and a branch
that is not the bot's own last push, are skips: a `::notice::`, and the lane
stays green. The required checks keep auto-merge from landing a red PR.

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

**The contract: the bot touches an `update/*` branch -- push, PR title edit,
auto-merge change -- only while origin's live head is exactly the SHA it expects
as its own last push.** `bot_owns` in `update-publish.sh` is that one gate. It
reads origin with `git ls-remote`, never GitHub's API. Before this run pushes,
the expected head is the one the job checked out, and that head must also carry
only commits the bot both authored and committed (a human amend can keep the bot
author) and be credited by GitHub's repository activity to the App as pusher
(`update-github.py push`), because commit identities are freely chosen. After
this run's own push, the expected head is the one it pushed.

Anything else is a skip, never red, even when build verification failed: non-bot
commits, a head GitHub does not credit to the App or has no activity row for
yet, origin moved to anyone's commits (other bot commits included), a lease
rejected because origin moved, or a PR view that disagrees with origin. Each
touches nothing and writes the reason to the receipt's `skip` field with a
`::notice::` (`skip_lane`). Only a human edit -- a head carrying commits the bot
did not both author and commit -- also gets `leave_human_edit`'s ONE comment on
the open PR per head SHA (deduped by a marker carrying the branch and SHA in the
bot's own comments), saying the branch changed since the bot last updated it and
is left alone until it is deleted (merging deletes it). Lag, a missing activity
row and another bot push are a notice alone. There are no re-read loops: at four
sweeps a day the next sweep re-reads, so lag heals itself.
`update-matrix.py verdict` turns `skip` into a notice, and
`Escalate repeated hold-backs` neither counts a skipped hold-back nor treats it
as the previous of two. The same `skip` field records an existing PR whose patch
did not change.

Red is reserved for a NEW PR or a changed patch (`new_id != old_id`) whose
verification failed, and for genuine errors: origin unreadable by
`git ls-remote`, malformed auto-merge metadata, an auto-merge event that cannot
be classified, a failed `gh pr view` (an API exception, not lag), a
`gh pr create` failure, or a push that failed while origin did not move.
`update-github.py push` exits 2 for "not the App's push" (a skip) and 1 for an
exception (an error), so an API failure is never read as someone else's edit.

`update-publish.sh` compares stable patch IDs and merge bases. It skips a push
only when the patch is identical, the remote branch already uses the current
base, and the PR is not conflicting. A behind-base or conflicting bot branch is
rebuilt and pushed. Unchanged and left PRs remain recorded as touched.

Only same-repository App-authored PRs may be edited or armed. Open PR discovery
spans every base: a PR targeting a branch other than `main`, or a human-owned PR
on the internal branch, skips the lane and leaves the shared stable branch. Fork
PRs with the same branch name are ignored. The push's force-with-lease is the
head the gate accepted (empty when the branch was absent).

Before any existing App PR can be re-armed, publication reads its latest
auto-merge timeline event. An explicit human disable is retained through a safe
behind-base branch refresh and title edit; only the re-arm is skipped. An
automatic disable with a GitHub reason, a bot disable, or a PR that has never
been armed can still self-heal, and ordinary comments and reviews that do not
block merging remain allowed. Arming passes the gate again, then reads the PR:
another repository, base, author, head branch or head SHA than expected leaves
the branch. An existing request is retained without an enable attempt. The merge
command receives `--match-head-commit`. When an enable fails, the rollback
disables auto-merge only if the App now owns the request -- auto-merge was off
when the attempt began, so that is this run's own enable; one a human enabled
meanwhile stays.

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

Generated documents stay in the flake checks. Kiro's scoped native jobs build
the extracted-metadata drift check on both Linux and Darwin, covering TUI
materialization on macOS where the Linux-only flake check cannot. These jobs
explicitly enable and assert the Nix sandbox before the materializer executes;
Darwin's Nix default does not provide that guarantee. Patched proprietary Kiro
stays in those jobs without cache publication; the update workers retain
Cachix's `pushFilter: kiro-cli`.

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
A green sweep may contain held-back targets, but only once each, unless the
target's branch is not the bot's own last push: the hold-back path reads
origin's live head through the same gate, leaves that branch, and never counts
it. The first sweep that holds a target back warns and stays green; the
`Escalate repeated hold-backs` step fails `cleanup` when the same target is held
back on two consecutive SCHEDULED sweeps. That threshold exists because a
hold-back means no new PR or branch update was written for the attempt, so
branch CI has nothing to judge for it and the condition cannot clear itself. Any
update PR still open on a held-back target is an EARLIER proposal that
publication preserved, not the blocked one. Read receipt statuses before
claiming every update was prepared successfully.

Only the immediate predecessor's receipt is consulted, and only its ABSENCE
makes a first offense. The predecessor is the newest scheduled run created
before this one, read from a listing that includes running sweeps
(`event=schedule&branch=main`, no `status=completed`). The listing must contain
the current scheduled run, and the predecessor must be no older than one
schedule interval plus half an interval, where the interval is derived from the
cron in `update.yml`. A listing that fails either test is re-read with backoff
and then reported as `Update hold-back count unknown`, never as a first sweep.
The step runs under `!cancelled()`, so a failed cleanup step cannot skip it. The
step asks whether the receipt artifact exists before downloading it, because a
failed download alone cannot tell "no receipt" from "receipt we failed to read".
When that listing, the download or the parse still fails after `gh` retries, the
target also fails `cleanup`, titled `Update hold-back count unknown`: counting
it as a first offense would silently reset the counter and turn a repeat green.
Every annotation states which predecessor it compared against and why. Every
failing one quotes a preparation excerpt, or says why none could be read. The
excerpt is the newest nix builder block, or, when nothing was built, the log
tail with traceback frames and the pipeline's own trailer lines removed.

The Python fixture suites exercise package coverage, completion reports, cleanup
receipts, and PR publication against disposable local Git repositories. They run
inside the required `test` job without evaluating or building Nix themselves.

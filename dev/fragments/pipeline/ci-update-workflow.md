## CI Update Workflow

> **Last verified:** 2026-08-03 (commit pending — makes the hidden update report
> artifact upload real and fails loudly when the report is absent). Prior:
> 2026-08-03 (commit pending — records `devenv-test` as an always-reporting
> fifth merge gate and corrects the auto-merge thread rule). Prior: 2026-08-03
> (commit pending — updates the pnpm detector's documented lookup after all
> package groups move under `pkgs.ai`). Prior: 2026-08-01 (commit pending —
> Phase 2 now runs on `if: always()` so a timed-out sweep SHIPS what it finished
> instead of discarding it, and the `ninja-completed.flag` sentinel is re-gated
> on `steps.ninja.outcome` so a partial sweep can never let the close step
> delete the PRs it did not reach. Measured on run 30713330569: 47 of 52 edges
> done, step `skipped`, everything thrown away). Prior: 2026-08-01 — documents
> the SECOND `extraExtract` self-heal, `vu.mkExtractRegen`, alongside the hash
> one: which failure it answers, that a red drift check reports a broken
> MECHANISM rather than a stale file, why extracts get no
> `fix_sidecar_hashes`-style standalone hatch, and how to tell "never wired"
> from "ran and failed". glab had no hook at all, which stayed invisible from
> #560 until PR #621). Prior: 2026-07-27 — adds the three-valued
> `git diff --quiet` rule and the `git_diff_quiet` helper every dirtiness gate
> in the update scripts now goes through; the bare form had routed a git ERROR
> into "there are changes" in `update-input.sh` and into "the tree is dirty" at
> both of `update-pkg.sh`'s gates. Earlier: the
> `Detect a newer @aihubmix/mcp on npm` annotation step and the
> excluded-because-a-local-patch-cannot-be-swept rule behind it, which is about
> SWEEPABILITY and not about lagging: aihubmix-mcp tracks `dist-tags.latest` and
> is still excluded. Earlier: the `NAT_UPDATE_JOBS` evaluator budget that killed
> run 30181958460, the `verify_all_packages` single-definition build gate and
> the `fix_sidecar_hashes` repair-on-failure retry, and the non-blocking
> annotation-step family plus the new-pnpm-major raise). If you touch
> `.github/workflows/update.yml`, `dev/scripts/update-common.sh`,
> `dev/scripts/update-input.sh`, `dev/scripts/update-pkg.sh`, or the PR creation
> logic, and this fragment isn't updated in the same commit, stop and fix it.

### Design: Renovate-style per-dependency PRs

The CI update workflow creates one PR per updated dependency, matching
Renovate's model. Each dependency is independently validated on both platforms
(x86_64-linux + aarch64-darwin) via the normal ci.yml PR pipeline. A failed
darwin build only holds back that specific dependency, not the entire batch.

### Trigger

The workflow runs on a **nightly `schedule`** (cron) plus manual
`workflow_dispatch`; it does NOT run on push. It opens per-dependency PRs
against the default branch (the `BRANCH_NAME` env is the PR base). It previously
ran on push to a long-lived integration branch; the trunk-based migration moved
it to a time-based schedule.

### Workflow phases

**Phase 1 — Ninja pipeline** (ubuntu runner):

The workflow runs the ninja DAG. Each target updates its dependency in an
isolated worktree and leaves the resulting commits on a per-dependency branch
(`update/<name>`). Branches are not pushed or merged at this stage — that
happens in Phase 2.

**Phase 2 — PR creation** (same ubuntu runner):

After ninja completes, the workflow iterates all `update/*` branches. For each
branch with commits ahead of the base SHA:

1. Force-pushes the branch to origin — unless the change is unchanged from what
   is already on the remote branch (see "Patch-identity guard" below).
2. Creates a PR against the working branch (or updates an existing PR's title if
   one already exists for that branch).

On re-run, branches are force-updated and PRs are reused. Same behavior as
Renovate's rebasing strategy, with the same `rebaseWhen: conflicted` exception.

#### Phase 2 runs on `always()` — a timeout must not discard finished work

This step carries `if: always()`, and that is load-bearing rather than
defensive. Without it a sweep that runs out of wall clock throws away every
dependency it had already finished.

Measured on run `30713330569`: ninja was `cancelled` at the 60-minute
`timeout-minutes` with **47 of 52 edges already done**, this step was `skipped`,
and all of it was discarded — including a `glab` branch that had correctly
regenerated its extracted sidecar. The `if: always()` steps AFTER it every one
reported `success` in that same run, which is the evidence the condition is
honoured on a timeout and not only on a plain failure.

Publishing a partial sweep is safe because of where each target commits: a
target commits into its own worktree branch only AFTER its build verification
passes. A killed ninja therefore leaves every branch either at the base commit
(skipped by the base-SHA guard) or carrying a complete, verified commit. There
is no half-written state to publish.

**The sentinel is what makes this safe, and it moved.** `ninja-completed.flag`
now requires BOTH that ninja itself succeeded (`steps.ninja.outcome`, read
through `env:`) and that the push loop exited cleanly — reaching the end of the
loop no longer implies the sweep was complete. Getting that wrong is
destructive, not untidy: the close step DELETES any `update/*` PR missing from
`touched-branches`, so a sentinel written after a partial sweep would close
exactly the PRs whose targets never got to run.

**Do not substitute raising `timeout-minutes` for this.** It cannot help the
resource-exhaustion death described under the evaluator budget below — that one
reports `failure`, not `cancelled` — and even for a genuine time bound it only
moves the cliff. This removes it.

One honest limitation: a cancelled job gets a finite grace period, so a sweep
with very many branches to push could still be cut off mid-loop. That degrades
to "some dependencies landed" instead of "none", which is the point.

**Phase 3 — Validation** (triggered automatically):

PRs trigger ci.yml's `pull_request` event, which runs builds on both linux and
darwin runners, plus the always-reporting `devenv-test` workflow. That runtime
gate performs its expensive work only when the pull request touches a relevant
path; otherwise it succeeds after a changed-files API query. PRs can merge only
after all five required status contexts pass.

### Non-blocking annotation steps

A small family of `if: always()` steps runs after PR creation. Each is
strict-mode bash that only ever `echo "::warning::…"` — none can fail the sweep,
and none opens a PR. They exist for changes the pipeline deliberately does NOT
automate because a human has to decide:

- **`Surface held-back updates as a warning`** — cosmetic red for targets the
  sweep could not land.
- **`Detect upstream copilot-cli SEA restoration`** — evaluates
  `github-copilot-cli.sourceRoot` on nixos-unstable HEAD; if upstream ships
  per-platform SEA again, our standalone derivation could go back to being an
  `overrideAttrs`.
- **`Detect a new pnpm major upstream`** — compares the highest npm `latest-<N>`
  dist-tag against the highest `pnpm_<N>` this repo carries, and prompts a human
  to slide the window (adopt the new major, retire the oldest). Two rules, both
  load-bearing:
  - **Key on `latest-<N>`, never `next-<N>`.** Measured 2026-07-25: `next-12`
    already exists (an alpha) while `latest-12` does not, so a next-keyed
    detector would fire on every sweep from now on. It would look like a working
    detector while being pure noise.
  - **Derive "ours" from the repo**, not a literal. The step reads
    `pkgs.ai.generic.pnpm_*` attribute names out of
    `nix eval .#packages.<system>`; a hardcoded major rots silently the moment
    the window slides, and a detector that has stopped detecting is worse than
    none.
- **`Detect a newer @aihubmix/mcp on npm`** — compares the registry's
  `dist-tags.latest` against the version this repo pins, derived (never
  hardcoded) from `nix eval --raw .#packages.x86_64-linux.aihubmix-mcp.version`
  with the `+<local>` suffix stripped.

  This one is worth understanding as a RULE, not a special case. A package
  carrying a local patch against upstream's published BUILD OUTPUT cannot be
  swept: no update script can re-author a patch, and that is true whether or not
  the package is currently up to date. aihubmix-mcp now tracks
  `dist-tags.latest`, so the detector is normally silent — but the exclusion
  stays, because CURRENCY IS NOT SWEEPABILITY. The measured proof, 2026-07-27:
  the patch written against 1.0.0 took hunk 1 with fuzz and FAILED hunks 2 and 3
  against 1.1.0, because `build/tools/painting-tools.js` was rewritten (288 ->
  624 lines). It had to be re-authored by hand. A targets row would go RED the
  next time upstream does that, occupying a channel meant for TRANSIENT failures
  and training operators to ignore it.

  The pairing — a `config.update.excludePatterns` entry recording the exclusion,
  plus an annotation step keyed on a repo-derived version — is the honest shape:
  one HTTP GET per sweep, and any lag stays visible. Do NOT run both this and a
  targets row; and when a patch is finally dropped (upstream absorbs the
  feature, or the fork lands), delete the exclusion AND the detector in the same
  commit that adds the targets row. Detection machinery left behind after the
  thing it detects became sweepable is dead code.

When adding one of these, copy the shape: `if: always()`, no `${{ }}`
interpolation of external data into the shell, and an explicit no-op message on
the negative branch so a silent step is distinguishable from a dead one.

### Formatter passes (per-input and per-package)

Both worktree update scripts run `nix fmt` before their commit so the
per-dependency PR ships treefmt-clean files. PR CI's `treefmt-check`
(`checks.formatting`) runs on each PR branch in isolation, and the base-branch
`full-format` ninja rule only runs post-merge — too late to gate a PR — so each
branch must normalize its own tree. The two paths differ in their **trigger**:

- **`update-input.sh` (Phase 2.5)** runs `nix fmt` only when the input bump
  moves `formatter.<system>`'s store path (a new prettier/alejandra/biome
  version wants different output across the whole tree). Detail below.
- **`update-pkg.sh`** runs `run_build nix fmt` whenever the update left a dirty
  tree. The trigger is "the updateScript regenerated a file," not "the formatter
  moved": a package's custom updateScript can emit non-canonical output even
  when the formatter is unchanged. The motivating case is `claude-code`'s
  `extraExtract`, which `cp`'s `jq`-pretty-printed JSON (every array multi-line)
  over `overlays/claude-code-extracted.json`; biome collapses short arrays (e.g.
  `effortLevels`) onto one line, so the raw `cp` drifts from treefmt-clean. The
  `extraExtract` hook also formats its own output directly (defense in depth —
  the hook stays correct when invoked outside the pipeline); the `update-pkg.sh`
  pass is the general net for any future package updateScript. Gated on a dirty
  tree so a no-op update doesn't create a spurious reformat commit.

#### Per-input formatter pass (`update-input.sh` Phase 2.5)

Between build verification and the commit, `update-input.sh` conditionally runs
`nix fmt` inside the per-input worktree — only when the input bump actually
moves `formatter.<system>`'s store path — and `git add -A`'s any reformatted
files into the pending commit. The gate captures
`nix eval --raw .#formatter.x86_64-linux.outPath` before `nix flake update` and
again after build verification; identical store paths mean the formatter hasn't
changed and `nix fmt` is skipped. Most inputs (devenv, git-branchless,
rust-overlay, etc.) don't carry new prettier / alejandra / biome versions, so
unconditionally running `nix fmt` per target added ~15–20 minutes per pipeline
run for no benefit.

When the formatter does move (typically a `nixpkgs` bump, or an input that
follows nixpkgs for treefmt-nix), the pass catches the case where a new
formatter version wants different output than the existing repo files. Without
it, the `update/<name>` PR ships only the lock change and PR CI's
`treefmt-check` fails because the docs / other files no longer round-trip
through the bumped formatter.

`nix fmt` exits 0 on successful in-place formatting regardless of whether files
changed (we do not pass `--fail-on-change`), so a non-zero exit here is a real
formatter error and correctly aborts the worktree subshell → reports HELD BACK.

This requires `projectRootFile = "flake.nix"` in `treefmt.nix`: treefmt-nix's
default `projectRootFile = ".git/config"` does not exist inside a git worktree
(where `.git` is a gitfile pointer, not a directory), so the default would make
`nix fmt` error in every worktree.

The base-branch `full-format` ninja rule still runs after the per-input pipeline
as a safety net for the rare case where two simultaneous input bumps interact in
a way the per-input passes do not catch on their own.

### `git diff --quiet` is three-valued — use `git_diff_quiet`

Every dirtiness gate in the update scripts goes through `git_diff_quiet` in
`update-common.sh`. Do not open-code `git diff --quiet` in a test position; the
helper exists because that status is **not a boolean**:

    0   no difference
    1   difference
    >1  git ITSELF failed (commonly 128 — bad revision,
        unreadable path, corrupt index)

Testing it for truthiness folds the error into one of the two normal answers,
and **which** one depends on whether the test is negated — so one defect
presents in OPPOSITE directions at different call sites and neither looks wrong
read locally. `if git diff --quiet` reads an error as "there ARE changes";
`if ! git diff --quiet` reads it as "the tree is dirty". The second is the
failure-becomes-a-commit shape that `config/generate-update-ninja.nix`'s
`full-format` rule body had to close with the same discriminate-by-value idiom
(that rule body cannot call the helper — it is a ninja `command =` string, so it
carries the `case` inline, with `$$` escaping).

`git_diff_quiet` returns 0 or 1 exactly like the bare command, and on >1 names
the real cause and exits the calling shell with git's status. Callers therefore
stay free to chain with `||`: a short-circuit can only skip a diff that is
already answered, never one that errored.

Call it from inside a target's **reporting subshell** — the `( … )` whose
failure the caller turns into `report_held_back`. That is what converts the
error exit into the one report line every target owes; from a target's main
shell it would exit with no report entry at all.

Two properties are worth keeping in mind when reading these gates:

- **A short-circuited pair is ONE gate, not two.** `update-pkg.sh` tests
  `! …diff || ! …diff --staged` twice. Under the bare form a failure of the
  FIRST invocation skipped the second entirely, so a single fault flipped BOTH
  gates at once — the redundant reformat AND the commit/amend. Reasoning about
  either gate in isolation understates it.
- **Do not sweep this class by grepping the shape you last saw.** The first
  sweep matched `git diff --quiet` literally and missed the two
  `git -C "$wt" diff --quiet` call sites for that reason alone. Enumerate every
  invocation whose exit status is consumed, then judge each.

Prove changes here with a **four-outcome** control set — 0, 1, >1, and the
negated/short-circuit variant — driving the >1 case with a stubbed `git` whose
`diff` exits above 1 while every other subcommand execs the real binary.
Reasoning is not a substitute: the `full-format` fix read as correct twice
before a control caught that it still routed an error into the commit branch.
Measured on the pre-fix scripts, with `git diff` forced to 128 and the tree
genuinely unchanged: `update-input.sh` ran the FULL `nix-fast-build`
verification of every package and reported the cause as "update or build
failed", and when the input HAD moved it reported plain `UPDATED` with the git
fault invisible; `update-pkg.sh` ran a pointless `nix fmt` and then
`commit --amend --no-edit`, which succeeds on an unchanged tree, so a green
sweep silently rewrote the update commit.

### GitHub App token

PRs created with the default `GITHUB_TOKEN` do NOT trigger cross-workflow events
(GitHub security feature to prevent recursive workflow triggers). This workflow
uses a GitHub App token (`nix-agentic-tools-bot`) instead. App installation
tokens DO trigger `pull_request` events in ci.yml.

The App needs these permissions:

- `contents: write` — push branches
- `pull-requests: write` — create/update PRs

Self-triggering is prevented by checking the actor:
`github.actor != 'nix-agentic-tools-bot[bot]'`.

### IFD warm step

Before the ninja pipeline runs, a warm step forces all IFD source fetches (see
the IFD patterns fragment for details). This ensures `nix-update` (which
internally runs `nix-instantiate`) can evaluate packages that use
`builtins.readFile` on fetched sources. Without this step, nix-update crashes on
cold runners.

### Patch-identity guard

The base SHA comparison below only detects "this branch has no commits". It
cannot detect "this branch has the same commits as last run, rebased onto a
newer base" — and because every run rebuilds each worktree from the _current_
base, the tip SHA always differs. The unconditional force-push therefore fired a
duplicate 4-job CI run per dependency on every pipeline run, to re-validate a
byte-identical patch. Measured on `update/devenv`: heads `595acf55` (parent
`010dbe15`) and `6b51fe30` (parent `06da1e47`) both hash to patch-id
`692bc6a5…`.

Before pushing, the workflow compares `git patch-id --stable` of
`base_sha..<branch>` against the same computation for the remote branch over
_its_ own merge-base. `patch-id` hashes the diff alone, so a pure rebase onto an
_unchanged_ base compares equal and the push is skipped.

Three conditions keep the guard honest:

- **Empty patch-id is never a match.** An empty diff hashes to the empty string;
  treating that as equality would collapse every no-op branch together.
- **A `CONFLICTING` PR is pushed anyway.** Otherwise a skipped branch could rot
  against a base it no longer applies to. This is Renovate's
  `rebaseWhen: conflicted` in effect. Note the working branch has no protection
  rule requiring branches be up to date, so an unrebased-but-mergeable PR still
  merges.
- **A branch behind the current base is rebased anyway.** The guard skips only
  when the remote branch's merge-base with the current base equals the base tip
  (`old_base == base_head`). If the base branch has advanced since the PR was
  last pushed, the branch is force-pushed even when the dependency patch is
  byte-identical, so the PR re-runs CI against the base it will actually merge
  into. This is Renovate's `rebaseWhen: behind-base-branch` layered on top of
  `conflicted`; it lets a PR self-heal after a base-branch CI fix instead of
  staying pinned to a stale, possibly broken base.

**A skipped branch must still be recorded in `touched-branches`.** The stale-PR
step closes _and deletes_ any `update/*` PR missing from that file, so a silent
skip would make the pipeline close its own valid PR and recreate it on the next
run — strictly worse than the duplicate CI it was meant to avoid.

### Base SHA comparison

The workflow records the branch HEAD before the ninja pipeline as `base_sha`.
After ninja completes, each `update/*` branch is compared against this SHA.
Branches where HEAD equals `base_sha` are skipped (no changes — the dependency
was already at latest). This avoids creating empty PRs or force-pushing
unchanged branches.

### Branch name extraction

`git branch --list 'update/*'` output includes markers for worktree-checked-out
branches (prefixed with `+`). The workflow strips these with `tr -d ' *+'`
before using the branch name. Forgetting this causes branch operations to fail
with cryptic errors about branches named `+ update/foo`.

### Environment requirements

| Variable            | Source                             | Purpose                                              |
| ------------------- | ---------------------------------- | ---------------------------------------------------- |
| `CACHIX_AUTH_TOKEN` | Repository secret                  | Pushes fetched sources + built outputs               |
| `GITHUB_TOKEN`      | App token step output              | Authenticates git push + gh CLI                      |
| `NIX_PATH`          | `nixpkgs=flake:nixpkgs`            | Required by nix-update (uses `import <nixpkgs>`)     |
| `NAT_UPDATE_JOBS`   | `update.yml` step env (`4`)        | Bounds ninja `-j` AND the evaluator budget (below)   |
| `WORKTREE_LOCK`     | `$RUNNER_TEMP/nix-update-worktree` | Serializes `git worktree add` (not concurrency-safe) |

### The evaluator budget is MULTIPLICATIVE — `NAT_UPDATE_JOBS`

ninja runs `$NAT_UPDATE_JOBS` targets concurrently, and every target that
actually changed runs its OWN `nix-fast-build`, whose defaults are sized for it
running ALONE on the box (verified in `nix_fast_build/options.py` @ 1.6.0):

    --eval-workers          multiprocessing.cpu_count()
    --eval-max-memory-size  4096      # MiB, PER WORKER

Under ninja those MULTIPLY. On the 4-vCPU / 16 GiB `ubuntu-latest` runner a bare
`-j4` is `4 x 4 x 4 GiB` = **64 GiB of evaluator heap budget against 16 GiB of
RAM**, plus 16 evaluator processes fighting over 4 cores and one eval-cache
SQLite file.

This is INVISIBLE while targets are unchanged — an unchanged target exits before
build verification and never spawns an evaluator at all — which is why the sweep
looks healthy for months. It bites when several inputs move at once against a
COLD eval cache, exactly what a `nixpkgs` bump guarantees, since that
invalidates the eval cache for the whole package set.

That is what killed run `30181958460`, twice on the same commit: `nixpkgs`,
`nixpkgs-test` and `devenv` all updated, the pipeline went silent with four
`nix-eval-jobs` processes live, and the runner was torn down with
`The runner has received a shutdown signal` + exit 143 (SIGTERM) — 6m59s into
attempt 1, 19m27s into attempt 2.

**Diagnostic trap:** that is NOT a timeout and NOT a concurrency cancel. A
60-minute `timeout-minutes` hit reports conclusion `cancelled` (control: run
`30074075218`, duration `1:00:22`), and so does a `cancel-in-progress` kill.
Both attempts here reported `failure`. Do not "fix" this class of death by
raising `timeout-minutes` — it is a resource bound, not a time bound.

`nfb_eval_flags` in `update-common.sh` bounds the PRODUCT, deriving both knobs
from the machine so a bigger runner uses its headroom automatically:

- never more than ONE evaluator per core across all concurrent invocations —
  `jobs * floor(cores/jobs) <= cores`
- total evaluator heap ceiling <= 60% of RAM (the rest is the nix daemon, git,
  and the runner agent — the agent being the process whose death produces the
  shutdown signal)

The first invariant holds only because **`NAT_UPDATE_JOBS` is itself clamped to
the core count**. `nfb_eval_flags` cannot give an invocation fewer than one
evaluator, so once there are more concurrent targets than cores the evaluator
total is pinned at the target count and no per-invocation budget can pull it
back. Fewer targets is the only lever. Measured, cores=2 / jobs=4:
workers-per-invocation clamps to 1 and the total lands at 4 evaluators on 2
cores.

The second invariant is stronger — it holds for ANY jobs value, because
per-worker is `(RAM*0.6)/(jobs*workers)` and the product telescopes back to
`RAM*0.6` exactly.

**Do not "make this consistent"** by substituting `min(jobs, cores)` into the
memory divisor as well. The divisor must be the number of invocations that will
ACTUALLY run concurrently; shrinking it while ninja still spawns `jobs` of them
inflates the per-worker ceiling. Measured, cores=2 / jobs=4 / 16 GiB: that
variant yields **119% of RAM** — the exact failure class this machinery exists
to prevent.

`NAT_UPDATE_JOBS` is ONE knob feeding both consumers on purpose, and the
workflow **sources `update-common.sh`** rather than reading its own env var so
it gets the CLAMPED value. Clamping in the library while ninja still ran `-j4`
from the raw env var would fix nothing. Changing ninja's `-j` without changing
the evaluator budget silently re-creates the overcommit.

### Build verification gate (`run_nfb_build` / `verify_all_packages`)

`update-input.sh` and the `final-build` ninja rule both invoke `nix-fast-build`
to verify peer packages still build after an input change. The invocation itself
lives in ONE place, `verify_all_packages` — three callers need it
byte-identical, and when the copies drifted they silently verified different
things.

Upstream has a known bug where `async_main`'s `finally: stack.aclose()` can
swallow non-zero exit on the build-failure path — per-build failures silently
exit 0. Effect: a broken peer package would let `nixpkgs` (or any other input
update) ship as UPDATED instead of HELD BACK.

`run_nfb_build` in `update-common.sh` defends against this with four independent
gates — any of them tripping fails the build:

1. **Exit code** — `nix-fast-build`'s own exit code is non-zero.
2. **JSON result file** — `--result-file <path> --result-format json` is
   appended to the caller's command, then `jq` checks for any `success: false`
   entry. Empty/missing file is also a failure (we asked for one; not getting
   one means verification was incomplete).
3. **Stderr grep — build failures** — the consistent
   `ERROR:nix_fast_build:BUILD: N successes, M failures` line with `M > 0` is
   matched against captured stderr. This is the tripwire that caught CI run
   26473689694 when (1) and (2) both missed.
4. **Stderr grep — evaluation failures** — the distinct
   `ERROR:nix_fast_build:EVAL: N successes, M failures` line with `M > 0` is
   matched against captured stderr. Eval-time throws (e.g. an input bump that
   breaks a package's `fetchPnpmDeps`) never become builds, so they are
   invisible to gates 1-3.

`|| exit_code=$?` localizes errexit suppression to the single nix-fast-build
call — no blanket `set +e`. All four gates run unconditionally so failure
signals are always logged together.

### Stale sidecar hashes self-heal (`fix_sidecar_hashes`)

`mkUpdateScript` rebuilds a sidecar FROM SCRATCH on every write, so `vendorHash`
(and bruno's `srcHash`/`npmDepsHash`) survive only because the overlays
re-derive them through `extraExtract`. That covers the VERSION-BUMP path and
nothing else.

A **nixpkgs or Go-toolchain bump can invalidate a `vendorHash` with no version
change at all.** `extraExtract` never fires, so nothing re-derives the hash. The
stale hash then fails the input bump's own build verification and the input is
reported HELD BACK — the breakage does NOT leak into the tree, but every later
`nixpkgs` update parks behind a hash a human has to fix by hand.

So Phase 2 retries ONCE through `fix_sidecar_hashes`: it discovers every
`passthru.fixVendorHash` / `passthru.fixNpmDepsHash` across `packages.<system>`
and runs it, then re-verifies. The correction lands in the same commit as the
lock change, so the PR is green.

Three properties are load-bearing:

- **Repair-on-failure, not a prophylactic sweep.** A healthy bump pays nothing.
  Running the fixers up-front would drive a separate `nix build` per fixer per
  changed input.
- **The roster is DISCOVERED, never listed.** A hardcoded list would silently
  stop covering the next absorbed Go package, and a fixer that has quietly
  stopped firing is worse than no fixer.
- **Collect, don't abort.** One package genuinely broken by the bump must not
  stop the others self-healing; the retry build is the authority on whether the
  tree is good.

Exposure grew from zero to four Go packages in a single slice (`#513`), so this
widens with every Go absorption.

### Stale option-surface sidecars self-heal (`vu.mkExtractRegen`)

The SECOND self-heal running through `extraExtract`, and the one to reach for
when a bump PR fails `checks.<system>.<pkg>-extracted` rather than a build. Do
not conflate the two: the section above repairs a HASH the sweep invalidated;
this one keeps a committed `overlays/**/<pkg>-extracted.json` describing the
artifact actually pinned.

Four packages have a `passthru.extracted` — `chatgpt-codex`, `claude-code`,
`glab`, `kiro-cli` — and each wires `vu.mkExtractRegen {attr, dest, pkgs}` into
its `extraExtract`. It rebuilds `.#<attr>.passthru.extracted` against the
just-written sidecar and copies it over `dest`, so the bump PR carries its own
regenerated option surface and the drift check never sees a stale one.

**Read a red drift check as "the self-heal did not run", not "this JSON is
stale."** Hand-regenerating the file turns the check green and leaves the
mechanism broken, so it goes red again on the next bump. That is exactly what
happened to `glab`: it was the one extracted package that never wired the hook
at all, invisible from #560 until its first version bump reddened PR #621.

Diagnosing it from the pipeline side:

- **`nix build .#<pkg>.updateScript --no-link --print-out-paths` and read the
  tail.** The regeneration is the last thing in the emitted script. Absent means
  the package never wired `extraExtract` — the glab failure mode. Present means
  it ran and something inside it failed, which the target's
  `.update-logs/<target>.log` will show.
- **It fires on the VERSION-BUMP path only**, being spliced in after the sidecar
  `mv` — the same limitation the hash self-heal has, and the reason that one
  needs `fix_sidecar_hashes` as a standalone escape hatch. Extracts get no such
  hatch on purpose: an extract that moves at an unchanged version means someone
  edited the extractor, and the right response is to read that diff, not to
  re-run a fixer.
- **Ordering matters for an extract built FROM SOURCE.** `glab` is the only one:
  its extract realizes `src` and `goModules`, which hold `lib.fakeHash` until
  `fixHashes` has run, so `mkExtractRegen` is chained AFTER it. The other three
  probe a prebuilt binary and have no hash to restore.
- **A green drift check with a red `checks.formatting`** points at the `nix fmt`
  step inside the hook, not at the extraction — see the sidecar-formatting note
  earlier in this fragment.

### Sidecar logging and forensic preservation

The workflow uploads `.update-report.txt` as the `update-report` artifact on
every outcome. The leading dot is load-bearing: `actions/upload-artifact`
excludes hidden files by default, so the upload explicitly sets
`include-hidden-files: true`. It also sets `if-no-files-found: error`; a missing
forensic record must be a visible workflow failure rather than an apparently
successful upload that produced no artifact.

Every ninja rule wraps its script invocation in
`2>&1 | tee .update-logs/<target>.log` to capture per-target output
independently of ninja's stdout capture (which buffers until child exit). The
`Diagnostic dump` step (`if: always()`) in `update.yml` globs `.update-logs/*`
and surfaces every file under `::group::log: <name>` collapsible sections —
works on success, failure, cancel, and timeout.

`run_nfb_build` writes its forensic data (`nfb-result-XXXXXX.json` +
`nfb-stderr-XXXXXX.log`) into the same `.update-logs/` dir. On gate failure the
files are preserved for the Diagnostic dump to surface; on success they are
cleaned up.

The directory is gitignored.

### Key files

| File                           | CI-relevant sections                                  |
| ------------------------------ | ----------------------------------------------------- |
| `.github/workflows/update.yml` | Full workflow definition                              |
| `dev/scripts/update-common.sh` | Shared worktree, version, and report helpers          |
| `dev/scripts/update-init.sh`   | Cleans stale `update/*` branches + detaches worktrees |

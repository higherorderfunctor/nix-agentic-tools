---
name: stack-test
description: >-
  Use when you need to run tests or formatters across commits in a stack. Use
  INSTEAD of manual git test run or looping git checkout + test. Prevents:
  testing every commit when only the tip has to pass, unbounded parallel jobs
  exhausting memory, cache misunderstandings.
argument-hint: "<command> [--fix] [--stack|--tip] [--jobs N] [revset]"
disable-model-invocation: false
compatibility: "Requires git-branchless"
---

Run a test command or formatter across commits in the current stack.

## Pre-flight

1. **Load references** — read `references/git-branchless.md` (relative to this
   skill's directory) before proceeding. The sections **Choosing the test
   revset** and **Sizing `--jobs` — by memory, not by cores** are the rules this
   skill applies; the rest of this file is how to apply them.

2. **Confirm repository initialization.** A devenv project with
   `stacked-workflows.gitPreset` enabled initializes automatically before Git
   hooks are installed. Outside that setup, initialize from the primary worktree
   when the common branchless state is absent:

   ```bash
   git_common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
   if [ ! -d "$git_common_dir/branchless" ]; then
     git -C "$(dirname "$git_common_dir")" branchless init
   fi
   ```

## Arguments

- First argument: the command to run (optional — auto-detected if omitted)
- `--fix`: use fix mode (apply changes per commit, e.g., formatters)
- `--stack`: test **every** commit — for a stack of independent PRs/MRs
- `--tip`: test only the stack tip — for one PR/MR with several commits
- `--jobs N`: parallelism override for run mode. **Never `0`** (see step 5). Fix
  mode always runs `--jobs 1` (see Fix Mode)
- Remaining args: an explicit revset, which overrides `--stack` / `--tip`

## Steps

1. **Parse `$ARGUMENTS`**. If no command is provided, detect from the project:
   - `package.json` → `npm test` or `pnpm test`
   - `Cargo.toml` → `cargo test`
   - `Makefile` → `make test`
   - `flake.nix` → `nix flake check`
   - Otherwise, ask the user.

2. **Determine mode**. If `--fix` is in arguments, use fix mode. Otherwise use
   run mode.

3. **Determine the target revset.** This is a coverage decision — get it right
   before worrying about speed.

   **Select this worktree's own stack first**, and use `$STACK` wherever this
   skill says "the stack" — the table below, fix mode, and every revset you
   pass:

   ```bash
   main_branch="$(git config branchless.core.mainBranch || echo main)"
   remote="$(git config "branch.${main_branch}.remote" || echo origin)"
   base="$(git rev-parse --abbrev-ref "${main_branch}@{upstream}" 2>/dev/null \
     || echo "${remote}/${main_branch}")"
   git rev-parse --verify -q "${base}^{commit}" >/dev/null || base="$main_branch"
   STACK="descendants(roots((stack() & ::HEAD) - ::$base)) - ::$base"
   ```

   Plain `stack()` is not your stack whenever local `main` is behind its
   upstream, the normal state when worktrees branch from `origin/main`: the
   upstream commits count as draft, so `stack()` holds them and every stack that
   another worktree branched from them. `git test run` then tests other agents'
   work, and `git test fix` **rewrites** it, including a forged copy of an
   upstream commit under your own stack. `$STACK` stops at `$base` and at HEAD's
   own line, so neither can happen. The one exception is a worktree stacked on
   yours, which the fix-mode checks below catch; see **Selecting your own
   stack** in `references/git-branchless.md`. This does not fetch; the last
   fetched `$base` is enough to tell your commits from upstream ones. With no
   upstream ref (no remote, or a remote with no main branch yet), `$base` falls
   back to local `main`.

   Precedence, highest first: an explicit revset argument, then `--stack` /
   `--tip`, then the mode default. **The mode default differs**: run mode
   defaults to the tip (the table below), fix mode defaults to `$STACK` (see Fix
   Mode, step 6). So in `--fix` the table below does not apply unless `--tip` or
   an explicit revset was given.

   **Fix mode rewrites every commit it selects and moves the branches on them,
   so check before running:**

   ```bash
   : "${STACK:?run the selection block first}"
   stack_commits="$(git query -r "$STACK")" || exit 1
   test -n "$stack_commits" || { echo "empty stack selection" >&2; exit 1; }
   outside="$(git query -r "(<revset>) - ($STACK)")" || exit 1
   test -z "$outside" || { printf '%s\n' "$outside"; exit 1; }
   current_worktree="$(git rev-parse --show-toplevel)" || exit 1
   other_heads="$(git worktree list --porcelain | awk -v current="$current_worktree" '
     $1 == "worktree" {
       if (path != "" && path != current && head != "") print head
       path = substr($0, 10); head = ""
     }
     $1 == "HEAD" { head = $2 }
     END { if (path != "" && path != current && head != "") print head }
   ')" || exit 1
   selected_commits="$(git query -r "<revset>")" || exit 1
   test -n "$selected_commits" || { echo "empty fix selection" >&2; exit 1; }
   overlap=""
   for other_head in $other_heads; do
     for selected_commit in $selected_commits; do
       if git merge-base --is-ancestor "$selected_commit" "$other_head"; then
         overlap="${overlap}${overlap:+ }${other_head}"
       fi
     done
   done
   test -z "$overlap" || { printf '%s\n' "$overlap"; exit 1; }
   ```

   - **The query prints commits:** stop and show them. The revset reaches
     another worktree's stack or upstream commits (`draft()` and `stack()` both
     can). Run mode only reads, so an explicit revset may reach further there;
     say so in the report.
   - **The worktree check prints a commit:** another worktree, including a
     detached one, has its HEAD inside your stack. Stop and ask. Fixing would
     rewrite or abandon the commit under that worktree.

   Every guard must print nothing and exit 0. Re-run the selection block and
   this guard in the same shell before fix mode.

   With no revset and no flag, read the structure of the work — every PR/MR
   needs its own branch, so branch refs inside the stack count the PRs:

   ```bash
   git query "$STACK" | wc -l                # commits in the stack
   git query --branches "$STACK"             # and their branches
   ```

   | Branches in stack | Situation                                 | Revset          |
   | ----------------- | ----------------------------------------- | --------------- |
   | `$STACK` is empty | No commits of your own — on main or fresh | `@`             |
   | 0 or 1            | One PR/MR, several WIP commits            | `heads($STACK)` |
   | 2+                | A stack of independent PRs/MRs            | `$STACK`        |

   Check the empty case first and mechanically — on `main`, `heads($STACK)`
   resolves to zero commits and would test nothing at all.

   Use `heads($STACK)` rather than `@` for the tip: it stays correct when the
   user has navigated back with `git prev`, where `@` is a middle commit.

   **When the count is 2+, name the branches you found in your report.** The
   count cannot tell a real PR stack from one PR plus a stale branch left over
   from earlier work — both look like 2. Over-testing is the safe direction, so
   still default to `$STACK`, but listing the names lets the user spot a stale
   branch immediately instead of wondering why seven commits are being tested.

   **Why the tip is the default.** In a single PR only the merged result ships:
   the tip is what reviewers read and what CI gates, and the commits underneath
   are checkpoints. Testing all seven commits of a seven-commit PR runs six
   evaluations that buy nothing. Small, frequent commits inside one PR are a
   deliberate, good habit — **never** discourage them, and never read them as N
   things to validate.

   **Say which revset you chose and why, before running.** Widening and
   narrowing are both coverage changes, and a silent one is a bug.

4. **Reject `nix` per-commit testing.** If the command is a Nix command
   (`nix flake check`, `nix build`, …) _and_ the revset covers more than one
   commit, stop and tell the user the cost before running:

   > Per-commit testing does not fit Nix at any `--jobs` value. Each job is a
   > multi-GB evaluator in its own worktree with no shared eval cache, so at
   > `--jobs 0` this fans out until it exhausts RAM (7 commits measured ~24 GB,
   > OOM-killing a 30 GB workstation), and at `--jobs 1` it is N sequential full
   > evaluations.

   Then confirm the user really wants every commit evaluated. If not, use
   `heads($STACK)`.

5. **Size `--jobs` by memory, not by cores.** Each job runs in its own worktree
   with no shared cache, so peak usage is `jobs x per-job footprint`.

   Use an explicit `--jobs N` on **every** invocation. Never pass `--jobs 0`: it
   means _one job per physical CPU_, and it overrides whatever bound the
   machine's config had set. Omitting the flag inherits `branchless.test.jobs`,
   which is only safe if you know what it says — this repo's own preset shipped
   `0` for a while, so do not rely on it.

   Derive the number with the snippet under **Sizing `--jobs`** in
   `references/git-branchless.md`. It already clamps by CPUs and by commit
   count; the one value you must supply is `footprint_mb`, taken from that
   section's table **for the command you detected in step 1** — not the Nix
   default. Leaving it at Nix's ~3500 for `cargo test` or `npm test` would
   serialize a run that could safely use every core.

   When the revset resolves to a single commit, `--jobs 1` is the whole answer
   and no arithmetic is needed. Fix mode is always `--jobs 1`; skip this step
   there.

### Run Mode (testing)

6. **Run tests**:

   ```bash
   git test run -x '<command>' --jobs <N> '<revset>'
   ```

7. **Report results**:
   - State the revset and job count used, and why.
   - If all pass: confirm with commit count.
   - If some fail: list which commits failed with their hashes and messages.
   - Suggest `git test run -x '<command>' --jobs 1 --search binary` to bisect if
     the failure pattern is unclear.

### Fix Mode (formatting)

6. **Apply formatter across the stack**:

   ```bash
   git test fix --strategy working-copy --jobs 1 --no-cache -x '<command>' '<revset>'
   ```

   Always pass `--strategy working-copy --jobs 1 --no-cache`. With the
   `worktree` strategy (this repo's git preset), `git test fix` silently fixes
   nothing: it reports `No commits to fix`. A cached result from any earlier
   worktree-strategy run has the same effect, and a `--jobs` above 1 selects
   `worktree` too. See **`git test fix`** in `references/git-branchless.md`.

   `working-copy` checks each commit out in this worktree, so it needs a clean
   working tree. If tracked files have changes, it exits 1 and changes nothing;
   ask the user to commit them first.

   Fix mode replaces tree OIDs directly and never produces merge conflicts.

   Formatters are the one case where the tip is _not_ enough: an unformatted
   intermediate commit stays unformatted forever. Default to `$STACK` here even
   for a single PR.

7. **Verify** with `git sl` to show any commits that were modified.

8. **Optionally re-run tests** to confirm the formatting didn't break anything:

   ```bash
   git test run -x '<test-command>' --jobs <N> '<revset>'
   ```

## Examples

```
/stack-test "npm test"                          # tip only, auto-sized jobs
/stack-test "nix flake check"                   # tip only — see step 4
/stack-test "cargo test" --stack                # every commit: a PR stack
/stack-test "cargo fmt --all" --fix             # every commit (formatter)
/stack-test "prettier --write ." --fix '@'      # fix one commit
/stack-test "make lint" '@'                     # explicit revset wins
/stack-test "npm test" --jobs 4 'draft()'       # run mode only: every worktree's drafts
```

## Notes

- Test results are cached by command + tree ID, under
  `.git/branchless/test/<tree-oid>/`. Use `--no-cache` to bypass the cache for
  one run without clearing stored results (useful after environment changes).
- Cache cleanup affects the common Git directory shared by every worktree. Stop
  and ask before clearing cached test results.
- `strategy = worktree` (set by this repo's git preset; upstream defaults to
  `working-copy`) is what makes parallelism possible at all. In run mode it also
  means `--jobs 1` still runs in an isolated worktree, so a dirty working copy
  is fine. Fix mode overrides it with `--strategy working-copy` (step 6).
- `--jobs N` on the command line overrides `branchless.test.jobs` in **both**
  directions: it lowers a configured `0` and raises a configured `1`.
- The `BRANCHLESS_TEST_COMMIT` env var is available inside the test command.

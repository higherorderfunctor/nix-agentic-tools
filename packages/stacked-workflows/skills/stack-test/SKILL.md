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

2. **Check branchless init**:

   ```bash
   if [ ! -d ".git/branchless" ]; then git branchless init; fi
   ```

## Arguments

- First argument: the command to run (optional — auto-detected if omitted)
- `--fix`: use fix mode (apply changes per commit, e.g., formatters)
- `--stack`: test **every** commit — for a stack of independent PRs/MRs
- `--tip`: test only the stack tip — for one PR/MR with several commits
- `--jobs N`: parallelism override. **Never `0`** (see step 5)
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

   An explicit revset argument always wins. `--stack` and `--tip` come next.
   With none of those, read the structure of the work — every PR/MR needs its
   own branch, so branch refs inside the stack count the PRs:

   ```bash
   git branchless query 'stack()' | wc -l              # commits in the stack
   git branchless query 'stack() & branches()'         # and their branches
   ```

   | Branches in stack | Situation                       | Revset           |
   | ----------------- | ------------------------------- | ---------------- |
   | stack() is empty  | Nothing draft — you are on main | `@`              |
   | 0 or 1            | One PR/MR, several WIP commits  | `heads(stack())` |
   | 2+                | A stack of independent PRs/MRs  | `stack()`        |

   Check the empty case first and mechanically — on `main`, `heads(stack())`
   resolves to zero commits and would test nothing at all.

   Use `heads(stack())` rather than `@` for the tip: it stays correct when the
   user has navigated back with `git prev`, where `@` is a middle commit.

   **When the count is 2+, name the branches you found in your report.** The
   count cannot tell a real PR stack from one PR plus a stale branch left over
   from earlier work — both look like 2. Over-testing is the safe direction, so
   still default to `stack()`, but listing the names lets the user spot a stale
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
   `heads(stack())`.

5. **Size `--jobs` by memory, not by cores.** Each job runs in its own worktree
   with no shared cache, so peak usage is `jobs x per-job footprint`.

   Use an explicit `--jobs N` on **every** invocation. Never pass `--jobs 0`: it
   means _one job per physical CPU_, and it overrides whatever bound the
   machine's config had set. Omitting the flag inherits `branchless.test.jobs`,
   which is only safe if you know what it says — this repo's own preset shipped
   `0` for a while, so do not rely on it.

   ```bash
   if [ -r /proc/meminfo ]; then
     avail_mb=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
   else
     avail_mb=$(( $(sysctl -n hw.memsize) / 1048576 / 2 ))  # macOS: half RAM
   fi
   footprint_mb=3500          # nix; see the footprint table in the reference
   jobs=$(( avail_mb * 70 / 100 / footprint_mb ))
   if [ "$jobs" -lt 1 ]; then jobs=1; fi
   echo "$jobs"
   ```

   Then clamp `jobs` to the commit count and to the physical CPU count. When the
   revset is a single commit, `--jobs 1` is the whole answer.

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
   git test fix -x '<command>' --jobs <N> '<revset>'
   ```

   Fix mode replaces tree OIDs directly and never produces merge conflicts.

   Formatters are the one case where the tip is _not_ enough: an unformatted
   intermediate commit stays unformatted forever. Default to `stack()` here even
   for a single PR. Formatters are also cheap (< 0.1 GB per job), so a high
   `--jobs` is fine — size it from the footprint table, not from fear.

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
/stack-test "prettier --write ." --fix --jobs 8
/stack-test "make lint" 'stack()'               # explicit revset wins
/stack-test "npm test" --jobs 4 'draft()'
```

## Notes

- Test results are cached by command + tree ID. Use `git test clean` to clear.
  Use `--no-cache` to bypass the cache for the current run without clearing
  stored results (useful after environment changes).
- `strategy = worktree` (set by this repo's git preset; upstream defaults to
  `working-copy`) is what makes parallelism possible at all. It also means
  `--jobs 1` still runs in an isolated worktree, so a dirty working copy is
  fine.
- `--jobs N` on the command line overrides `branchless.test.jobs` in **both**
  directions: it lowers a configured `0` and raises a configured `1`.
- The `BRANCHLESS_TEST_COMMIT` env var is available inside the test command.

---
name: stack-test
description: >-
  Use when you need to run tests or formatters across every commit in a stack.
  Use INSTEAD of manual git test run or looping git checkout + test. Prevents:
  untested commits, wrong parallelism settings, cache misunderstandings.
argument-hint: "<command> [--fix] [--jobs N] [revset]"
disable-model-invocation: false
compatibility: "Requires git-branchless"
---

Run a test command or formatter across commits in the current stack.

## Pre-flight

1. **Load references** — read `references/git-branchless.md` (relative to this
   skill's directory) before proceeding.

2. **Check branchless init**:
   ```bash
   if [ ! -d ".git/branchless" ]; then git branchless init; fi
   ```

## Arguments

- First argument: the command to run (optional — auto-detected if omitted)
- `--fix`: use fix mode (apply changes per commit, e.g., formatters)
- `--jobs N`: parallelism level (0 = auto-detect CPUs)
- Remaining args: revset to target (default: `stack()`)

## Steps

1. **Parse `$ARGUMENTS`**. If no command is provided, detect from the project:
   - `package.json` → `npm test` or `pnpm test`
   - `Cargo.toml` → `cargo test`
   - `Makefile` → `make test`
   - `flake.nix` → `nix flake check`
   - Otherwise, ask the user.

2. **Determine mode**. If `--fix` is in arguments, use fix mode. Otherwise
   use run mode.

3. **Determine target revset**. If a revset argument is provided, use it.
   Otherwise default to `stack()`.

### Run Mode (testing)

4. **Run tests across the stack**:
   ```bash
   git test run -x '<command>' '<revset>'
   ```
   Add `--jobs <N>` if specified (uses worktree strategy automatically).
   Default to `--jobs 0` for parallel when the project supports it.

5. **Report results**:
   - If all pass: confirm with commit count
   - If some fail: list which commits failed with their hashes and messages
   - Suggest `git test run -x '<command>' --search binary` to bisect if the
     failure pattern is unclear

### Fix Mode (formatting)

4. **Apply formatter across the stack**:
   ```bash
   git test fix -x '<command>' '<revset>'
   ```
   Add `--jobs 0` for parallel execution. Fix mode replaces tree OIDs directly
   and never produces merge conflicts.

5. **Verify** with `git sl` to show any commits that were modified.

6. **Optionally re-run tests** to confirm the formatting didn't break anything:
   ```bash
   git test run -x '<test-command>' '<revset>'
   ```

## Examples

```
/stack-test "npm test"
/stack-test "cargo fmt --all" --fix
/stack-test "prettier --write ." --fix --jobs 0
/stack-test "make lint" stack()
/stack-test "npm test" --jobs 4 draft()
```

## Notes

- Test results are cached by command + tree ID. Use `git test clean` to clear.
  Use `--no-cache` to bypass the cache for the current run without clearing
  stored results (useful after environment changes).
- `--jobs >1` implies worktree strategy (concurrent git worktrees).
- The `BRANCHLESS_TEST_COMMIT` env var is available inside the test command.
- Fix mode is safe for parallel execution — it works on tree objects directly.

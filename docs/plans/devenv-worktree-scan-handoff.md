# Handoff: keep git worktrees out of the devenv/Nix flake scan

**Status:** banked reference for future work — a portable handoff for fixing the
same devenv/Nix worktree-scan problem in _other_ repos (e.g. via Kiro).

**Provenance:** root-caused and fixed in this repo on 2026-07-16 (commit
`594baa78`,
`fix(update-pipeline): move worktrees out of flake root to stop devenv scanning them`).
The local update pipeline was creating per-dependency worktrees under
`$PWD/.worktrees/`, inside the flake root, so devenv re-scanned ~8k files on
every `direnv reload`. Fix: relocate to
`${TMPDIR:-/tmp}/nat-update-worktrees/<name>/`, make them ephemeral (teardown on
exit + `git worktree prune` at init), serialize `remove` under the worktree
lock, and write forensics to an absolute workspace path. See
`dev/scripts/update-common.sh`, `dev/scripts/update-init.sh`, and the
`dev/fragments/pipeline/` fragments.

**How to use:** paste everything below the line into the target repo's agent
(Kiro/Claude/etc.) as a task brief. It is diagnosis-first and repo-agnostic: the
worktree _location_ is prescribed, the rest is adapted to the target repo's
pipeline. Do not transplant this repo's exact implementation.

---

## HANDOFF: keep git worktrees out of the devenv/Nix flake scan

**Why you're getting this:** a sibling repo root-caused a real devenv/Nix
problem that you likely share **if this repo creates git worktrees (or any large
gitignored tree) inside its devenv/flake root**. Confirm it applies here, then
implement a fix that fits _this_ repo's pipeline — the **location is
prescribed** (below), the rest you adapt.

### The problem (authoritative — don't re-derive or dismiss)

devenv/Nix enumerates **all untracked _and_ gitignored files under the flake
root on every shell entry** — it runs `git ls-files --cached --others` (no
`--exclude-standard`), so `.gitignore` does **not** keep a directory out of the
scan. Confirmed by devenv's maintainer:

> "we tell git to read all files also ignored by gitignore and I still can't
> find a good way to avoid that." — domenkozar, **cachix/devenv#2042**
> (canonical: **#257**)

Non-fixes (don't waste time):

- **No in-place exclude** — no `.devenvignore`, no devenv.nix/yaml option.
  Adding gitignore entries or hunting for an ignore flag cannot fix this.
- The perf fix (#2093) is **speed-only** — still reads the files; upgrading
  devenv won't drop the count.
- **Worktrees are the worst offender**: each is a full repo checkout
  (hundreds–thousands of files) that people assume is skipped because it's
  gitignored. It isn't. (`node_modules`/`.venv`/datasets have the same issue.)

### Confirm whether THIS repo is affected

```bash
tracked=$(git ls-files | wc -l); echo "tracked: $tracked"
# Watch devenv's "Evaluating shell N files" on `direnv reload` / `devenv shell`.
# If N >> tracked, a big gitignored tree is being scanned. Find it:
for d in ./*/ ./.*/; do [ -d "$d" ] && printf '%8d  %s\n' \
  "$(find "$d" -type f 2>/dev/null | wc -l)" "$d"; done | sort -rn | head
git worktree list   # are any checkouts under $(git rev-parse --show-toplevel)?
```

If N ≈ tracked and no worktrees live under the flake root, this repo is fine —
stop.

### End state (properties your fix must satisfy)

1. **Location (prescribed): a labeled temp root outside the flake root.** Put
   worktree checkouts under `${TMPDIR:-/tmp}/<project>-worktrees/<name>/` — one
   binned, project-labeled root, deliberately outside the dir Nix walks.
   `${TMPDIR:-/tmp}` gives macOS its per-user temp and `/tmp` on Linux/WSL2;
   allow an env override (e.g. to `/var/tmp`) for tmpfs RAM pressure. **In CI,
   pin the root to the per-job temp** (`$RUNNER_TEMP/<project>-worktrees`, or
   your runner's equivalent) so concurrent runs can't collide on a shared
   `/tmp`.
2. **Ephemeral + self-cleaning.** Create per run, tear down on exit, and
   `git worktree prune` at init. Nothing persists between runs. (A worktree's
   _registration_ lives in `.git/worktrees/<name>/`, separate from the checkout
   — a temp wipe/crash strands it and the next `add` trips over it; `prune`
   reconciles.) This is _why_ `/tmp` is safe: you never rely on it surviving.
3. **No loss on teardown.** Commit work to the worktree's **branch** — refs are
   independent of the checkout, so removing the worktree never loses it. Write
   logs/forensics to an **absolute path outside the worktree** (captured before
   any `cd`), or they die with the teardown.
4. **Concurrency-safe.** Serialize **both** `git worktree add` **and** `remove`
   under one lock — the metadata ops are documented not-concurrency-safe, and a
   teardown racing another target's add corrupts the shared `.git/worktrees/`
   admin dir.

### Reference implementation (adapt to this repo's pipeline; don't transplant)

```bash
# 1) Labeled temp root OUTSIDE the flake root. macOS gets its per-user temp
#    via $TMPDIR; override to /var/tmp for tmpfs pressure. In CI, set the
#    override to the per-job temp (e.g. $RUNNER_TEMP/<project>-worktrees).
WT_ROOT="${MYPROJ_WORKTREES_DIR:-${TMPDIR:-/tmp}/<project>-worktrees}"
#   checkout path per worktree: "$WT_ROOT/<name>"

# 2) Absolute log/artifact dir, captured BEFORE any `cd "$wt"`.
LOGS_DIR="$PWD/.your-logs"

# 3) One lock for ALL worktree metadata ops.
WT_LOCK="${WT_LOCK:-${TMPDIR:-/tmp}/<project>-worktree.lock}"

# 4) Teardown — safe under `set -e` and subshells.
teardown_worktree() {
  # EXIT traps can fire inside (...)/$(...) on some bash versions; only the
  # MAIN shell should tear down, or you kill the worktree mid-run. In a
  # subshell $BASHPID differs from $$; in the main shell they're equal.
  [ "$BASHPID" = "$$" ] || return 0
  local wt="${1:-}"; [ -n "$wt" ] || return 0
  flock "$WT_LOCK" git worktree remove --force "$wt" 2>/dev/null \
    || rm -rf "$wt" 2>/dev/null || true
  return 0
}

# 5) Per worktree:
#   flock "$WT_LOCK" git worktree add -B "<branch>" "$WT_ROOT/<name>" "<base>"
#   trap 'teardown_worktree "$WT_ROOT/<name>"' EXIT
#   ... do work, commit to <branch> ...

# 6) Once at pipeline init, before any add:
#   git worktree prune
```

If this repo's pipeline isn't bash (or isn't a batch pipeline), the
**properties** above still hold — implement them in whatever form fits, keeping
the `${TMPDIR:-/tmp}/<project>-worktrees/<name>` layout.

### Verify

- Re-enter the shell: "Evaluating shell N files" drops to ≈
  `git ls-files | wc -l`.
- `git worktree list` — checkout paths now under the temp root, outside
  `$(git rev-parse --show-toplevel)`.
- Teardown guard: `( echo "sub $$ vs $BASHPID" )` — `$$` constant, `$BASHPID`
  differs.
- After a run (or simulated crash): a stale registration is reaped by
  `git worktree prune` and the next `add` succeeds; the branch ref still
  resolves after `worktree remove`.

### Persist it (so this repo doesn't regress)

Record a short note in this repo's agent instructions (`AGENTS.md` /
`.kiro/steering/`): _"Worktrees live under
`${TMPDIR:-/tmp}/<project>-worktrees/` (`$RUNNER_TEMP/…` in CI), deliberately
outside the flake root — devenv/Nix scans all gitignored files under the root
(cachix/devenv#257, #2042). Do not move them back in-tree or 'fix' the scan with
gitignore."_

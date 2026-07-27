#!/usr/bin/env bash
# dev/scripts/update-common.sh — shared functions for update pipeline.
# Sourced by update-input.sh, update-pkg.sh, update-combo.sh.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# Deterministic overlay-file resolution (resolve_overlay_file).
# shellcheck source=dev/scripts/resolve-overlay-file.sh
source "$(dirname "${BASH_SOURCE[0]}")/resolve-overlay-file.sh"

# Ephemeral worktree root, binned under one dir OUTSIDE the flake root.
# devenv/Nix enumerates ALL untracked + gitignored files under the flake
# root on every shell entry (`git ls-files --others`; cachix/devenv#257,
# #2042 — maintainer-confirmed, no in-place exclude exists), so worktrees
# kept in-tree (the old `$PWD/.worktrees`) were re-scanned on every
# `direnv reload`. `${TMPDIR:-/tmp}` gives macOS its per-user temp and
# `/tmp` on Linux/WSL2; override with `NAT_UPDATE_WORKTREES_DIR` (e.g.
# `/var/tmp`) if tmpfs RAM pressure bites. Worktrees are created per run
# and torn down (`teardown_worktree` on EXIT + `git worktree prune` in
# update-init.sh), so nothing persists between runs.
WORKTREES_DIR="${NAT_UPDATE_WORKTREES_DIR:-${TMPDIR:-/tmp}/nat-update-worktrees}"
# `git worktree add` is not concurrency-safe: parallel invocations
# race on `.git/worktrees/<name>/commondir` creation. Serialize.
WORKTREE_LOCK="${WORKTREE_LOCK:-/run/user/$(id -u)/nix-update-worktree}"
REPORT_FILE="$PWD/.update-report.txt"
# Absolute (captured at source time, before any `cd "$wt"`) so forensic
# artifacts survive an ephemeral worktree teardown and land in the
# workspace .update-logs the CI Diagnostic dump globs.
UPDATE_LOGS_DIR="$PWD/.update-logs"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Force color output from subcommands (ninja buffers output, tools lose TTY detection)
export CLICOLOR_FORCE=1

# ── ANSI colors (forced on — ninja passes through when stdout is a terminal) ──
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# GitHub token for nix-update rate limits
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh &>/dev/null; then
  GITHUB_TOKEN=$(gh auth token 2>/dev/null) || true
  [ -n "${GITHUB_TOKEN:-}" ] && export GITHUB_TOKEN
fi

# ── Output helpers ────────────────────────────────────────────────────────────

log_header() {
  echo "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
  echo "${BOLD}${CYAN}  $1${RESET}"
  echo "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
}

log_success() {
  echo "${GREEN}  ✓ $1${RESET}"
}

log_failure() {
  echo "${RED}  ✗ $1${RESET}" >&2
}

log_info() {
  echo "${YELLOW}  … $1${RESET}"
}

# ── Git status helpers ───────────────────────────────────────────────────────

# Run one quiet `git diff` and discriminate its status by VALUE.
#
# `git diff --quiet` is a THREE-valued signal, not a boolean: 0 = no
# difference, 1 = difference, >1 (commonly 128) = git ITSELF failed — a bad
# revision, an unreadable path, a corrupt index. Every construct that tests
# that status for mere truthiness folds the error into one of the two normal
# answers, and WHICH one it folds into depends on whether the test is negated.
# The same defect therefore presents in OPPOSITE directions at different call
# sites, and neither presentation looks wrong when read locally:
#
#   `if git diff --staged --quiet; then skip; fi`   error => "there ARE changes"
#   `if ! git diff --quiet; then commit; fi`        error => "the tree is dirty"
#
# The second shape is the failure-becomes-a-commit path that
# config/generate-update-ninja.nix's `full-format` rule body had to close
# with the same idiom.
#
# Usage mirrors `git` itself, minus the trailing `--quiet` this appends:
#
#   git_diff_quiet diff --staged            # -> `git diff --staged --quiet`
#   git_diff_quiet -C "$wt" diff            # -> `git -C "$wt" diff --quiet`
#
# Returns 0 (no difference) or 1 (difference), so a call site reads exactly
# like the bare command it replaces. On git's own failure it does NOT return:
# it names the real cause and exits the calling shell with git's status, so no
# caller can absorb an error into either answer, and callers stay free to
# chain with `||` — a short-circuit can only skip a diff that is already
# answered, never one that errored.
#
# `|| rc=$?` is the single place errexit is suppressed, so the ordinary
# exit-1 path still cannot kill the caller.
#
# CALL IT FROM INSIDE A TARGET'S REPORTING SUBSHELL — the `( … )` whose
# failure the caller turns into `report_held_back`. That is what converts the
# error exit into the one report line every target owes; called from a
# target's MAIN shell it would exit with no report entry at all.
git_diff_quiet() {
  local rc=0
  git "$@" --quiet || rc=$?
  case "$rc" in
  0 | 1) return "$rc" ;;
  *)
    log_failure "git $* --quiet failed (exit $rc) — refusing to read a git error as a diff answer"
    exit "$rc"
    ;;
  esac
}

# ── Worktree management ──────────────────────────────────────────────────────

# Create or reset a worktree on a named branch (update/<name>).
# After the script completes, the CI workflow pushes the branch
# and opens a PR (one PR per dependency, Renovate-style).
setup_worktree() {
  local name="$1"
  local wt="$WORKTREES_DIR/update-$name"
  local wt_branch="update/$name"

  if [ -d "$wt" ]; then
    # Clean any stuck git state from prior crashed runs
    git -C "$wt" cherry-pick --abort 2>/dev/null || true
    git -C "$wt" rebase --abort 2>/dev/null || true
    git -C "$wt" merge --abort 2>/dev/null || true
    # Discard modified tracked files (e.g. devenv.lock/flake.lock left
    # dirty from a prior crashed run) before the checkout — otherwise
    # `checkout -B` fails with "local changes would be overwritten".
    git -C "$wt" reset --hard HEAD >&2
    git -C "$wt" checkout -B "$wt_branch" "$BRANCH" >&2
    git -C "$wt" clean -fd >&2
  else
    mkdir -p "$WORKTREES_DIR"
    flock "$WORKTREE_LOCK" git worktree add -B "$wt_branch" "$wt" "$BRANCH" >&2
  fi

  # Symlink pre-commit config (devenv-generated, gitignored — worktrees don't have it).
  # Tools are nix store paths baked into the config, so no devenv activation needed.
  ln -sf "$PWD/.pre-commit-config.yaml" "$wt/.pre-commit-config.yaml"

  echo "$wt"
}

# Tear down an ephemeral worktree. Idempotent, and guarded to run only in
# the main shell: an EXIT trap can fire inside `(...)`/`$(...)` subshells
# (version-dependent), and premature teardown would cut off the
# post-update reporting that still reads the worktree. The `update/<name>`
# branch commit persists in refs independent of the checkout, so removing
# the worktree never loses the update. Any registration stranded by a
# crash or wiped temp is reaped by `git worktree prune` at the next init.
# The `remove` is serialized on WORKTREE_LOCK just like setup_worktree's
# `add`: under `ninja -j4` a finishing target's teardown would otherwise
# mutate the shared `.git/worktrees/` admin dir concurrently with another
# target's add (git worktree metadata ops are not concurrency-safe).
teardown_worktree() {
  [ "$BASHPID" = "$$" ] || return 0
  local wt="${1:-}"
  [ -n "$wt" ] || return 0
  flock "$WORKTREE_LOCK" git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt" 2>/dev/null || true
  return 0
}

# Build verification. Runs the actual build to catch Mode C/D failures
# before PRs open — see docs/update-pipeline-transitive-hash-gap.md § Gap 5.
run_build() {
  "$@"
}

# Core count, resolved once. Both bounds below are expressed against it.
NAT_UPDATE_CORES=$(nproc 2>/dev/null) || NAT_UPDATE_CORES=0

# Target fan-out for the whole pipeline. ONE knob, because it bounds two
# things that MULTIPLY (see nfb_eval_flags): ninja's `-j` and, through
# it, the per-target evaluator budget. CI sets it explicitly; this
# default is for running the pipeline by hand.
#
# CLAMPED TO THE CORE COUNT, and that clamp is load-bearing rather than
# tidiness. `nfb_eval_flags` cannot give an invocation fewer than ONE
# evaluator, so once there are more concurrent targets than cores the
# evaluator total is pinned at the target count and no per-invocation
# budget can bring it back under the cores. Fewer targets is the only
# lever. Measured, cores=2 with jobs=4: workers/invocation clamps to 1
# and the total lands at 4 evaluators on 2 cores.
#
# EXPORTED because ninja's `-j` has to come from the SAME number — the
# workflow sources this file rather than reading its own env var, so the
# two can never disagree. Clamping here while ninja still ran `-j4`
# would fix nothing.
NAT_UPDATE_JOBS="${NAT_UPDATE_JOBS:-4}"
[ "$NAT_UPDATE_JOBS" -ge 1 ] 2>/dev/null || NAT_UPDATE_JOBS=1
if [ "$NAT_UPDATE_CORES" -gt 0 ] && [ "$NAT_UPDATE_JOBS" -gt "$NAT_UPDATE_CORES" ]; then
  NAT_UPDATE_JOBS="$NAT_UPDATE_CORES"
fi
export NAT_UPDATE_JOBS

# Resource budget for a single nix-fast-build invocation.
#
# WHY THIS EXISTS. ninja runs $NAT_UPDATE_JOBS targets concurrently and
# every target that actually changed runs its OWN nix-fast-build, whose
# defaults are sized for it running ALONE on the box (verified in
# nix_fast_build/options.py @ 1.6.0):
#
#     --eval-workers          multiprocessing.cpu_count()
#     --eval-max-memory-size  4096      # MiB, PER WORKER
#
# Under ninja they multiply. On the 4-vCPU / 16 GiB `ubuntu-latest`
# runner that is 4 targets x 4 workers x 4 GiB = 64 GiB of evaluator heap
# budget against 16 GiB of RAM — a 4x overcommit, and 16 evaluator
# processes fighting over 4 cores and one eval-cache SQLite file.
#
# It stays INVISIBLE while targets are unchanged: an unchanged target
# exits before build verification and never spawns an evaluator at all.
# It bites when several inputs move at once against a COLD eval cache —
# exactly what a `nixpkgs` bump guarantees, since that invalidates the
# eval cache for the whole package set. Run 30181958460 died that way
# twice in a row: nixpkgs, nixpkgs-test and devenv all updated, the
# pipeline went silent with four nix-eval-jobs processes live, and the
# runner was torn down ("The runner has received a shutdown signal",
# exit 143/SIGTERM) 6m59s into attempt 1 and 19m27s into attempt 2.
# Neither the 60-minute workflow timeout nor the concurrency cancel
# fired — a cancel reports `cancelled`, and both attempts reported
# `failure`.
#
# So bound the PRODUCT. Both knobs are derived from the machine, never
# hardcoded, so a larger runner automatically uses its headroom:
#
#   * never more than ONE evaluator per core, across all concurrent
#     invocations — `jobs * floor(cores/jobs) <= cores`, which holds only
#     because NAT_UPDATE_JOBS is itself clamped to the core count above
#   * total evaluator heap ceiling <= 60% RAM, and this one holds for ANY
#     jobs value: per-worker is `(RAM*0.6)/(jobs*workers)`, so the
#     product telescopes back to `RAM*0.6` exactly
#
# The remaining 40% is the nix daemon, git, and the runner agent itself —
# the agent being the process whose death produces the shutdown signal.
#
# Do NOT "make this consistent" by substituting `min(jobs, cores)` into
# the memory divisor as well. The divisor has to be the number of
# invocations that will ACTUALLY run concurrently; shrinking it while
# ninja still spawns `jobs` of them inflates the per-worker ceiling and
# breaks the heap bound. Measured, cores=2 / jobs=4 / 16 GiB: that
# variant yields 119% of RAM — the exact failure class this exists to
# prevent.
nfb_eval_flags() {
  local workers mem_mib mem_per_worker cores="$NAT_UPDATE_CORES"

  [ "$cores" -gt 0 ] || cores="$NAT_UPDATE_JOBS"
  workers=$((cores / NAT_UPDATE_JOBS))
  [ "$workers" -ge 1 ] || workers=1

  printf -- '--eval-workers %s' "$workers"

  # /proc/meminfo is Linux-only. The update job runs on ubuntu-latest,
  # but these scripts are runnable by hand on darwin, so degrade to
  # nix-fast-build's own default rather than emit a bogus ceiling.
  mem_mib=$(awk '/^MemTotal:/ {printf "%d", $2 / 1024; exit}' /proc/meminfo 2>/dev/null) || mem_mib=0
  if [ "${mem_mib:-0}" -gt 0 ]; then
    mem_per_worker=$(((mem_mib * 60 / 100) / (NAT_UPDATE_JOBS * workers)))
    # Floor: below ~1 GiB a worker thrashes on restart instead of
    # evaluating, trading an OOM for a livelock.
    [ "$mem_per_worker" -ge 1024 ] || mem_per_worker=1024
    printf -- ' --eval-max-memory-size %s' "$mem_per_worker"
  fi
}

# nix-fast-build wrapper that gates on four independent signals.
#
# Upstream bug: nix-fast-build's async_main `finally: stack.aclose()` can
# swallow non-zero exit on the build-failure path, so per-build failures
# sometimes silently exit 0. Effect: a broken peer package lets nixpkgs
# (or any input/package update) report as UPDATED instead of HELD BACK.
#
# Defense in depth — fail if ANY of these tripwires fire:
#   1. nix-fast-build's own exit code is non-zero
#   2. The JSON result file shows any `success: false` (or is empty/missing)
#   3. nix-fast-build's stderr contains
#      `ERROR:nix_fast_build:BUILD: N successes, M failures` with M > 0 —
#      the consistent signal observed in CI run 26473689694 when (1) and
#      (2) both missed.
#   4. nix-fast-build's stderr contains
#      `ERROR:nix_fast_build:EVAL: N successes, M failures` with M > 0 —
#      eval-time throws are invisible to gates 1-3.
#
# On failure, forensic data (result file + stderr capture) is preserved
# under the workspace `.update-logs/` (UPDATE_LOGS_DIR — an absolute path,
# so it survives a per-input build's ephemeral worktree teardown) and
# surfaced by the Diagnostic dump workflow step.
#
# The JSON shape emitted by nix-fast-build (nix_fast_build/__init__.py
# `dump_json`) is:
#   {"results": [{"attr": "...", "success": bool, "error": "..." | null, ...}]}
#
# Usage: run_nfb_build nix run --inputs-from . nix-fast-build -- ...
run_nfb_build() {
  local rf stderr_log exit_code=0 failed=0
  mkdir -p "$UPDATE_LOGS_DIR"
  rf=$(mktemp -p "$UPDATE_LOGS_DIR" --suffix=.json nfb-result-XXXXXX) || return 1
  stderr_log=$(mktemp -p "$UPDATE_LOGS_DIR" --suffix=.log nfb-stderr-XXXXXX) || {
    rm -f "$rf"
    return 1
  }

  # Buffered stderr capture (not `2> >(tee ...)`): bash process
  # substitution offers no synchronization with the parent shell, so the
  # tee writer may still be flushing when gate 3 greps the file. The
  # buffered form `2> file` then `cat file >&2` is deterministic — we
  # only lose real-time stderr streaming, which the caller already
  # tees through `2>&1 | tee .update-logs/final-build.log` anyway.
  #
  # `|| exit_code=$?` localizes errexit suppression to this single call
  # (NOT a blanket `set +e`) — we want to inspect the exit code AND
  # continue to the JSON/stderr gates regardless.
  # nfb_eval_flags bounds the evaluator fan-out, which ninja's -j would
  # otherwise multiply into a memory overcommit that kills the runner.
  # Word-splitting is intended and safe: the function emits only flag
  # names and integers it computed itself.
  local -a eval_flags
  read -r -a eval_flags <<<"$(nfb_eval_flags)"

  "$@" "${eval_flags[@]}" --result-file "$rf" --result-format json \
    2>"$stderr_log" || exit_code=$?
  cat "$stderr_log" >&2

  # Gate 1: nix-fast-build's own exit code.
  if [ "$exit_code" -ne 0 ]; then
    log_failure "nix-fast-build exited non-zero ($exit_code)"
    failed=1
  fi

  # Gate 2: JSON result file. Empty/missing file is also a failure (we
  # asked for one; not getting one means the build verification was
  # incomplete and we should not trust it).
  if [ ! -s "$rf" ]; then
    log_failure "nix-fast-build wrote no result file (expected $rf)"
    failed=1
  elif ! jq -e '.results | all(.success)' "$rf" >/dev/null 2>&1; then
    log_failure "nix-fast-build result file shows per-build failures:"
    jq -r '.results[] | select(.success | not) | "    \(.attr): \(.error // "<no error message>")"' \
      "$rf" >&2 || true
    failed=1
  fi

  # Gate 3: stderr fallback. Observed in CI run 26473689694 — the JSON
  # gate missed a copilot-cli build failure but this stderr line was
  # present. nix-fast-build emits it consistently when builds fail, even
  # when its own exit code and JSON output are misleading.
  if grep -qE "ERROR:nix_fast_build:BUILD: [0-9]+ successes, [1-9][0-9]* failures" "$stderr_log"; then
    log_failure "nix-fast-build stderr reports build failures:"
    grep -E "BUILD: [0-9]+ successes|Failed attributes:" "$stderr_log" >&2 || true
    failed=1
  fi

  # Gate 4: evaluation failures. nix-fast-build reports eval-time errors on a
  # separate line from build failures. An attribute that throws during
  # evaluation (e.g. an input bump that breaks a package's eval) never becomes
  # a build, so it produces no `success: false` result entry (gate 2) and does
  # not increment the BUILD failure count (gate 3): it is invisible to gates
  # 1-3. nix-fast-build emits a distinct line for it:
  #   ERROR:nix_fast_build:EVAL: N successes, M failures
  # Observed when a nixpkgs bump broke effect-mcp's fetchPnpmDeps eval, yet the
  # nixpkgs update still shipped as UPDATED instead of HELD BACK.
  if grep -qE "ERROR:nix_fast_build:EVAL: [0-9]+ successes, [1-9][0-9]* failures" "$stderr_log"; then
    log_failure "nix-fast-build stderr reports evaluation failures:"
    grep -E "EVAL: [0-9]+ successes|Failed attributes:" "$stderr_log" >&2 || true
    failed=1
  fi

  if [ "$failed" -eq 1 ]; then
    log_failure "(forensic data preserved: $rf, $stderr_log)"
    return 1
  fi

  rm -f "$rf" "$stderr_log"
  return 0
}

# The pipeline's whole-package-set build verification. Defined once
# because the invocation has to be IDENTICAL across its callers —
# update-input.sh's Phase 2, its repair retry, and the ninja
# `final-build` rule in config/generate-update-ninja.nix. When these
# drifted apart they silently verified different things.
verify_all_packages() {
  run_nfb_build nix run --inputs-from . nix-fast-build -- \
    --skip-cached --no-nom --no-link \
    --flake ".#packages.$(nix eval --impure --raw --expr 'builtins.currentSystem')"
}

# Re-derive every sidecar-recorded fixed-output hash whose package
# exposes a standalone fixer, then leave the corrected sidecar in the
# working tree for the caller to commit.
#
# WHY. `mkUpdateScript`'s `buildCandidate` rebuilds the sidecar FROM
# SCRATCH (`jq -n --arg v "$latest" '{version: $v}'`), so any key the
# writer does not itself produce is destroyed on every write —
# `vendorHash` is exactly such a key. Go overlays therefore read
# `sources.vendorHash or lib.fakeHash` and re-derive it through
# `extraExtract` in the same run. That covers the VERSION-BUMP path.
#
# It does NOT cover a nixpkgs or Go-toolchain bump, which can invalidate
# a `vendorHash` with no version change at all. `extraExtract` only runs
# on a version bump, so nothing re-derives the hash; the stale hash then
# fails the input bump's build verification and the whole input is HELD
# BACK, parking every later nixpkgs update behind a hash a human has to
# fix by hand.
#
# `passthru.fixVendorHash` / `passthru.fixNpmDepsHash` were exposed
# standalone for precisely this, and until now had no caller at all.
#
# The roster is DISCOVERED from the flake, never listed here: a hardcoded
# list would silently stop covering the next absorbed Go package, and a
# fixer that has quietly stopped firing is worse than no fixer. The
# fixers are idempotent — on a correct hash each one is a cache-hit
# build that prints "<pname>: <key> ok" and writes nothing.
fix_sidecar_hashes() {
  local expr paths p rc=0

  # `builtins.getAttr` keeps the expression free of brace-substitution
  # sequences, so bash never tries to expand any part of it.
  expr='let
      flake = builtins.getFlake (toString ./.);
      ps = builtins.getAttr builtins.currentSystem flake.packages;
      fixersOf = n:
        let p = builtins.getAttr n ps;
        in builtins.filter (x: x != null) [
          (p.fixVendorHash or null)
          (p.fixNpmDepsHash or null)
        ];
    in builtins.concatMap fixersOf (builtins.attrNames ps)'

  # stderr is deliberately NOT merged into this capture. `nix build`
  # writes diagnostics there even when it SUCCEEDS — measured on a dirty
  # worktree: `warning: Nix search path entry ... ignoring`, and on a cold
  # store also `these N derivations will be built:`, the indented `.drv`
  # lines under it, and `building '...'`. Merged, every one of those is
  # read back below as if it were a store path and EXECUTED, so a repair
  # in which every fixer succeeded still reports failure. Letting stderr
  # flow to the inherited stream keeps it visible in real time: the ninja
  # rule already tees the whole target through
  # `2>&1 | tee .update-logs/input-<name>.log`.
  if ! paths=$(nix build --impure --no-link --print-out-paths --expr "$expr"); then
    log_failure "could not resolve sidecar hash fixers (nix error above)"
    return 1
  fi

  while IFS= read -r p; do
    # Belt and braces on top of the stream split: only ever execute
    # something that is actually an executable store path, so a stray
    # diagnostic line can never be run as a command.
    case "$p" in
    /nix/store/*) ;;
    *) continue ;;
    esac
    [ -x "$p" ] || continue
    # Collect rather than abort: one package genuinely broken by the
    # bump must not stop the others self-healing. The retry build is the
    # authority on whether the tree is good.
    "$p" || rc=1
  done <<<"$paths"

  return "$rc"
}

# ── Version parsing ───────────────────────────────────────────────────────────

# Parse nix-update output for "Update X -> Y" lines
parse_pkg_version() {
  local version_file="$1"
  if [ -f "$version_file" ]; then
    grep -oP 'Update \K\S+ -> \S+' "$version_file" | paste -sd', ' || true
  fi
}

# Parse nix flake update output for "Updated input 'name'" lines
# Extracts the date portion: (YYYY-MM-DD) → (YYYY-MM-DD)
parse_input_version() {
  local version_file="$1"
  local name="$2"
  if [ -f "$version_file" ]; then
    grep "Updated input '$name'" "$version_file" |
      grep -oP '\(\K[0-9-]+(?=\))' |
      paste -sd' → ' || true
  fi
}

# ── Report helpers ────────────────────────────────────────────────────────────
# Every target must write exactly one report entry before exiting.
# Format: STATUS: name [| version_detail] [(reason)]

report_updated() {
  local name="$1"
  local detail="${2:-}"
  local line="UPDATED: $name"
  [ -n "$detail" ] && line="$line | $detail"
  echo "$line" >>"$REPORT_FILE"
  log_success "$line"
}

report_unchanged() {
  local name="$1"
  echo "NO UPDATES: $name" >>"$REPORT_FILE"
  log_info "NO UPDATES: $name"
}

report_held_back() {
  local name="$1"
  local reason="$2"
  local detail="${3:-}"
  local line="HELD BACK: $name ($reason)"
  [ -n "$detail" ] && line="HELD BACK: $name | $detail ($reason)"
  echo "$line" >>"$REPORT_FILE"
  log_failure "$line"
}

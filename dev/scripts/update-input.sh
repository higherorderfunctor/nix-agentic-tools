#!/usr/bin/env bash
# dev/scripts/update-input.sh <input-name>
# Update a single flake input in a worktree, verify build, merge back.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/update-common.sh"

name="$1"
log_header "Input: $name"

wt=$(setup_worktree "$name")
# Ephemeral worktree: tear down on ANY exit path (success, held-back,
# error). EXIT fires after all reporting below. See teardown_worktree in
# update-common.sh.
trap 'teardown_worktree "$wt"' EXIT
version_file="$wt/.update-version"

# Phase 1: Update the input in the worktree
log_info "Updating flake input..."
# STANDALONE subshell, NOT an `if !` condition — bash disables errexit for
# anything whose status it tests, and that reaches inside the subshell and
# overrides its own `set -e`. See "Target subshell shape" in
# update-common.sh; checks/shell/target-subshell-shape.nix fails the build if this
# regresses.
target_rc=0
set +e
(
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  cd "$wt"

  # Capture pre-update formatter store path. Used by Phase 2.5 to
  # decide whether this input bump actually moved the formatter and
  # a reformat is worth running. `nix eval` of a single attribute is
  # a cheap resolve (~2s warm, no build, no IFD beyond what
  # flake.lock already drives). The `|| echo ""` keeps the
  # assignment safe under `set -euETo pipefail + inherit_errexit`
  # if the eval errors for any reason — the gate just falls back to
  # "different from after" and the existing unconditional behavior.
  fmt_before=$(nix eval --raw .#formatter.x86_64-linux.outPath 2>/dev/null || echo "")

  # Capture nix flake update output for version reporting. `if !` rather
  # than a bare pipeline plus a PIPESTATUS test: under `pipefail` the
  # pipeline's own status already IS nix's, and with errexit now armed a
  # bare pipeline would abort before reaching any status check, losing this
  # message. The `if` reads the same status and keeps the diagnosis.
  if ! nix flake update "$name" 2>&1 | tee "$version_file"; then
    # PIPESTATUS survives into this block — measured, including the real
    # exit code and which side failed:
    #   $ if ! bash -c 'exit 42' | tee /dev/null; then echo "${PIPESTATUS[*]}"; fi
    #   42 0
    # so the `if !` form costs nothing in diagnosis. Report both: under
    # `pipefail` a `tee` failure (full disk, bad path) fails the pipeline
    # just as loudly as the real command, and attributing it to the wrong
    # one sends the next reader looking in the wrong place.
    pipe=("${PIPESTATUS[@]}")
    log_failure "nix flake update failed (nix=${pipe[0]} tee=${pipe[1]})"
    exit 1
  fi

  # Regenerate devenv.yaml from updated flake.lock.
  #
  # Write to a temp and move, NEVER `>devenv.yaml` directly: the shell
  # truncates the redirect target BEFORE running the command, so an eval
  # failure left a zero-byte devenv.yaml — which then got staged, committed
  # and opened as a PR. Nothing downstream catches that: devenv.yaml has no
  # drift check under `nix flake check`, and prettier accepts an empty YAML
  # file, so the six required checks stay green and the bot's auto-merge
  # lands it. Explicit `exit` for the errexit reason above.
  if ! nix eval --raw --impure --expr 'import ./config/generate-devenv-yaml.nix {}' \
    >devenv.yaml.tmp; then
    rm -f devenv.yaml.tmp
    log_failure "devenv.yaml regeneration failed"
    exit 1
  fi
  # The `mv` needs the same guard as the eval above. Bare, a failed rename
  # left devenv.yaml at its OLD content, which then got staged and committed
  # beside a bumped flake.lock — a stale-but-well-formed file that no
  # required check compares against the lock, so it would auto-merge exactly
  # like the zero-byte case this temp-and-move exists to prevent.
  if ! mv devenv.yaml.tmp devenv.yaml; then
    rm -f devenv.yaml.tmp
    log_failure "could not install regenerated devenv.yaml"
    exit 1
  fi

  # Sync devenv.lock. Producing content the PR carries, so a failure is a
  # hold-back: shipping a stale devenv.lock beside a bumped flake.lock is a
  # PR we could not write correctly, and no required check compares them.
  if ! devenv update; then
    log_failure "devenv update failed"
    exit 1
  fi

  # Semble comes from the llm-agents flake input rather than a package update
  # target, so mkUpdateScript's extraExtract hook can never run for it. Refresh
  # the generated upstream snapshot here instead. The separate human-reviewed
  # hashes deliberately stay untouched: CI must fail until a reviewer accepts
  # or adapts each local derivative after upstream content changes.
  if [ "$name" = "llm-agents" ]; then
    log_info "Regenerating pinned Semble agent templates..."
    # Each step produces content the PR carries, so each failure is a
    # hold-back. Without the guards a failed `nix build` left
    # `semble_templates_path` empty, `cp ""` failed, and the PR shipped
    # with an unrefreshed snapshot — all silently, per the errexit note
    # above.
    update_system=$(nix eval --raw --impure --expr builtins.currentSystem)
    if ! semble_templates_path=$(nix build --no-link --print-out-paths \
      ".#checks.$update_system.semble-templates-extracted.passthru.extracted"); then
      log_failure "semble template extraction failed"
      exit 1
    fi
    if ! cp "$semble_templates_path" packages/semble/upstream-templates.json ||
      ! chmod 644 packages/semble/upstream-templates.json ||
      ! nix fmt -- packages/semble/upstream-templates.json; then
      log_failure "could not refresh packages/semble/upstream-templates.json"
      exit 1
    fi
  fi

  # Check if anything changed. `git diff --staged --quiet` signals through its
  # exit code, and that code is THREE-valued (0 / 1 / >1), so it goes through
  # git_diff_quiet rather than being tested for truthiness — see the rationale
  # there. Read as a boolean, an erroring git took the "there ARE changes"
  # branch: measured on this script with `git diff` forced to exit 128 and
  # nothing actually moved, the target ran the FULL nix-fast-build
  # verification of every package before failing on an empty commit, and
  # reported the cause as "update or build failed".
  # `git add` is atomic: a bad pathspec aborts it and stages NOTHING. Left
  # bare, that failure fell through to the clean-index check below, which
  # exited the subshell 0 — so the sweep printed `NO UPDATES` and the real
  # lock change was discarded with the worktree. Neither hold back nor
  # ship; the update simply vanished.
  if ! git add flake.lock devenv.yaml devenv.lock packages/semble/upstream-templates.json; then
    log_failure "git add failed"
    exit 1
  fi
  if git_diff_quiet diff --staged; then
    exit 0
  fi

  # Phase 2: Build verification.
  #
  # On failure, re-derive the sidecar fixed-output hashes and retry ONCE.
  # A nixpkgs or Go-toolchain bump can invalidate a sidecar `vendorHash`
  # (or bruno's `srcHash`/`npmDepsHash`) with no version change, and
  # `extraExtract` — which only runs on a version bump — never gets a
  # chance to correct it. Without this the input bump is HELD BACK and
  # every later nixpkgs update parks behind a hash a human must fix by
  # hand. See fix_sidecar_hashes in update-common.sh.
  #
  # Repair-on-failure, not a prophylactic sweep: a healthy bump pays
  # NOTHING, which matters because this runs once per changed input and
  # the fixers each drive their own `nix build`.
  verify_rc=0
  verify_all_packages || verify_rc=$?
  if [ "$verify_rc" -ne 0 ]; then
    # Return 2 means verification could not start. It is not evidence of an
    # ordinary red build and must never enter the publication path below.
    if [ "$verify_rc" -eq 2 ]; then
      log_failure "Package verification could not start"
      exit 1
    fi
    log_info "Build failed — re-deriving sidecar hashes and retrying once..."
    # A hash we cannot DERIVE is the one failure here that stops the PR
    # from being writable, so it is the only one that holds the input
    # back. Everything downstream of it ships.
    #
    # `exit`, not a bare call. This whole body is the CONDITION of the
    # `if ! (` above, and bash disables errexit for a condition — so a
    # bare failing command does NOT abort, it falls through to the
    # `git commit` below, whose success then becomes the subshell's
    # status. That is how a verified-broken bump shipped as UPDATED.
    # A non-zero return here does NOT by itself mean "a hash cannot be
    # derived", and treating it that way re-parks the input behind one
    # broken peer — the exact failure this rule exists to remove. Two
    # paths return non-zero for other reasons: the roster expression
    # forces every attr in `packages.<system>`, so ONE package throwing
    # at eval fails the whole resolve; and a fixer whose FOD build breaks
    # with no hash mismatch to scrape exits 1 too (lib/packaging.nix,
    # `fix_fod_hash`) — that is "the recorded hash was already right and
    # something else broke".
    #
    # So capture it and let the retry adjudicate.
    fixer_rc=0
    fix_sidecar_hashes || fixer_rc=$?

    verify_rc=0
    verify_all_packages || verify_rc=$?
    if [ "$verify_rc" -ne 0 ]; then
      if [ "$verify_rc" -eq 2 ] || [ "$verify_rc" -eq 4 ]; then
        log_failure "Package verification retry was incomplete"
        exit 1
      fi
      if [ "$verify_rc" -eq 3 ]; then
        log_failure "Package verification still reports an unresolved fixed-output hash"
        exit 1
      fi
      if [ "$fixer_rc" -ne 0 ]; then
        # The repair could not run to completion AND the tree still does
        # not build, so we cannot show the hashes are right: the PR may
        # need a value we never produced. That is the hold-back case.
        log_failure "sidecar hash repair failed and the build still fails"
        exit 1
      fi
      # The repair ran clean and the build still fails, so every hash we
      # can derive HAS been derived and the tree is complete and
      # committable. Well-formed but does not build is a red PR for
      # branch CI to report, not a reason to withhold it.
      log_info "Build still failing after a clean sidecar repair — opening the PR; branch CI is the gate"
      echo "::warning::${name}: build verification failed, PR opens red"
    fi
  fi

  # Phase 2.5: Formatter pass — only when this input bump actually
  # moved `formatter.<system>`'s store path. Most inputs (devenv,
  # git-branchless, rust-overlay, etc.) don't carry new
  # prettier/alejandra/biome versions; only nixpkgs (and inputs that
  # follow it for treefmt-nix) move the formatter derivation.
  # Conditioning on a real change saves ~15-20 minutes per pipeline
  # run vs. unconditionally rebuilding + reformatting for every
  # input. When the formatter does move, an input bump (especially
  # nixpkgs) can bring new versions of prettier/alejandra/biome/etc.
  # that want different output than the existing repo files; without
  # this pass the `update/<name>` PR ships only the lock change and
  # PR CI's `treefmt-check` fails because the docs/other files no
  # longer round-trip through the bumped formatter. No base-checkout final pass
  # can see the isolated update branch, so this per-input pass is authoritative.
  # `nix fmt` exits 0 on successful in-place formatting regardless
  # of whether files changed (no --fail-on-change). A non-zero exit
  # here means the formatter itself errored, leaving the tree
  # non-canonical — a PR that cannot be written correctly, so it holds
  # the input back. `git add -A` runs unconditionally: when fmt was
  # skipped it's a no-op over the lock files already staged; when fmt
  # ran it captures reformatting.
  #
  # Both need an explicit `exit` for the errexit reason spelled out at
  # the sidecar-hash repair above.
  fmt_after=$(nix eval --raw .#formatter.x86_64-linux.outPath 2>/dev/null || echo "")
  if [ "$fmt_before" != "$fmt_after" ]; then
    if ! run_build nix fmt; then
      log_failure "formatter errored"
      exit 1
    fi
  fi
  if ! git add -A; then
    log_failure "git add failed"
    exit 1
  fi

  # Phase 3: Commit. NOT gated on a passing build — see the sidecar-hash
  # repair above for why a failing build ships as a red PR instead.
  if ! git commit -m "chore: update input $name"; then
    log_failure "git commit failed"
    exit 1
  fi
)
target_rc=$?
set -e

if [ "$target_rc" -ne 0 ]; then
  version_detail=$(parse_input_version "$version_file" "$name")
  report_held_back "$name" "update or hash derivation failed" "$version_detail"
  exit 0
fi

# Extract version info
version_detail=$(parse_input_version "$version_file" "$name")

# Check if the worktree actually made commits
wt_head=$(git -C "$wt" rev-parse HEAD)
base_head=$(git rev-parse "$BRANCH")
if [ "$wt_head" = "$base_head" ]; then
  report_unchanged "$name"
  exit 0
fi

log_success "$name: branch update/$name ready for PR"
report_updated "$name" "$version_detail"

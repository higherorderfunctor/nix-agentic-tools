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
if ! (
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

  # Capture nix flake update output for version reporting
  nix flake update "$name" 2>&1 | tee "$version_file"
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log_failure "nix flake update failed"
    exit 1
  fi

  # Regenerate devenv.yaml from updated flake.lock
  nix eval --raw --impure --expr 'import ./config/generate-devenv-yaml.nix {}' >devenv.yaml

  # Sync devenv.lock
  devenv update

  # Check if anything changed. `git diff --staged --quiet` signals through its
  # exit code, and that code is THREE-valued (0 / 1 / >1), so it goes through
  # git_diff_quiet rather than being tested for truthiness — see the rationale
  # there. Read as a boolean, an erroring git took the "there ARE changes"
  # branch: measured on this script with `git diff` forced to exit 128 and
  # nothing actually moved, the target ran the FULL nix-fast-build
  # verification of every package before failing on an empty commit, and
  # reported the cause as "update or build failed".
  git add flake.lock devenv.yaml devenv.lock
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
  if ! verify_all_packages; then
    log_info "Build failed — re-deriving sidecar hashes and retrying once..."
    # Non-fatal: the retry below is the authority on whether the tree is
    # good, and it reports the real failure if the hashes were not the
    # problem.
    fix_sidecar_hashes || :
    verify_all_packages
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
  # longer round-trip through the bumped formatter. The base-branch
  # `full-format` run happens after merge — too late to gate PRs.
  # `nix fmt` exits 0 on successful in-place formatting regardless
  # of whether files changed (no --fail-on-change). A non-zero exit
  # here means the formatter itself errored, which correctly aborts
  # the subshell and reports HELD BACK. `git add -A` runs
  # unconditionally: when fmt was skipped it's a no-op over the lock
  # files already staged; when fmt ran it captures reformatting.
  fmt_after=$(nix eval --raw .#formatter.x86_64-linux.outPath 2>/dev/null || echo "")
  if [ "$fmt_before" != "$fmt_after" ]; then
    run_build nix fmt
  fi
  git add -A

  # Phase 3: Commit only after build passes
  git commit -m "chore: update input $name"
); then
  version_detail=$(parse_input_version "$version_file" "$name")
  report_held_back "$name" "update or build failed" "$version_detail"
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

#!/usr/bin/env bash
# dev/scripts/update-pkg.sh <package-name> <nix-update-flags> [git-url]
# Update a single package in a worktree, verify build, merge back.
# If git-url is provided, bumps rev to latest default branch commit first.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/update-common.sh"

name="$1"
shift

# Parse args: flags are everything except a trailing .git URL
git_url=""
args=("$@")
if [ ${#args[@]} -gt 0 ] && [[ ${args[-1]} == *.git ]]; then
  git_url="${args[-1]}"
  unset 'args[-1]'
fi
extra_flags="${args[*]:-}"
system=$(nix eval --impure --raw --expr 'builtins.currentSystem')

log_header "Package: $name"

wt=$(setup_worktree "$name")
# Ephemeral worktree: tear down on ANY exit path. See teardown_worktree in
# update-common.sh. The update/<name> branch commit persists in refs.
trap 'teardown_worktree "$wt"' EXIT
version_file="$wt/.update-version"
base_head=$(git rev-parse "$BRANCH")

# Phase 0: Bump rev to latest default branch commit (main-tracking packages)
if [ -n "$git_url" ]; then
  log_info "Fetching latest rev from $git_url..."
  new_rev=$(git ls-remote "$git_url" HEAD | cut -f1)
  if [ -n "$new_rev" ]; then
    # Deterministic recipe resolution + exactly-one-match guard.
    # Replaces the old `grep -rl "$repo_name" | head -1`, which matched any
    # file merely naming the repo basename (e.g. effect-mcp.nix's "Mirrors
    # context7-mcp.nix." comment) and raced on head -1's early pipe close,
    # silently rewriting the wrong overlay — context7's HEAD rev landed in
    # effect-mcp's fetch block → nonexistent commit → source 404 → red CI.
    # See dev/scripts/resolve-recipe-file.sh.
    # config.update.targets is the single source of truth (config/update-matrix
    # .nix was dissolved): read the declared recipe file for this package via
    # `nix eval --raw .#updateTargets.<name>.file` (owner registry.nix
    # contributions plus workspace policy). Every
    # main-tracking package declares one, so resolve_recipe_file below is a
    # retained safety-net fallback. Only `file` is consumed here; `flags`/`git`
    # flow positionally from the same registry via the ninja DAG.
    # checks.update-targets-parity asserts the declared `file` is byte-identical
    # to resolve_recipe_file's output, so the two paths agree.
    # cwd is still the main tree here (before the Phase 1 subshell `cd`), so
    # `.#updateTargets` resolves against the checked-out flake.
    declared_file=$(nix eval --raw ".#updateTargets.${name}.file" 2>/dev/null || true)
    if [ -n "$declared_file" ]; then
      target_file="$wt/$declared_file"
      log_info "Target from config.update.targets: $declared_file"
    elif ! target_file=$(resolve_recipe_file "$git_url" "$wt/packages"); then
      report_held_back "$name" "could not uniquely resolve recipe file"
      exit 0
    fi
    if [ -n "$target_file" ]; then
      old_rev=$(grep -oP 'rev = "\K[a-f0-9]{40}' "$target_file" | head -1 || true)
      if [ -n "$old_rev" ] && [ "$old_rev" != "$new_rev" ]; then
        sed -i "s|$old_rev|$new_rev|g" "$target_file"
        # Prefetch new source hash + storePath (used below for upstream
        # version re-derivation; one prefetch, two uses)
        old_hash=$(grep -oP 'hash = "\Ksha256-[^"]+' "$target_file" | head -1 || true)
        storePath=""
        if [ -n "$old_hash" ]; then
          flake_ref="github:$(echo "$git_url" | sed 's|\.git$||' | grep -oP 'github\.com/\K.*')/$new_rev"
          prefetch_rc=0
          prefetch_json=$(nix flake prefetch --json "$flake_ref" 2>/dev/null) || prefetch_rc=$?
          if [ "$prefetch_rc" -ne 0 ] ||
            ! jq -e 'type == "object" and (.hash | type == "string" and test("^sha256-[A-Za-z0-9+/]{43}=$"))' \
              <<<"$prefetch_json" >/dev/null 2>&1; then
            git -C "$wt" reset --hard "$base_head"
            report_held_back "$name" "source prefetch did not produce a valid hash"
            exit 0
          fi
          new_hash=$(jq -r .hash <<<"$prefetch_json")
          storePath=$(jq -r '.storePath // empty' <<<"$prefetch_json")
          if grep -qE '^[[:space:]]*# upstream: ' "$target_file" &&
            { [ -z "$storePath" ] || [ ! -d "$storePath" ]; }; then
            git -C "$wt" reset --hard "$base_head"
            report_held_back "$name" "source prefetch did not produce the marker source tree"
            exit 0
          fi
          sed -i "s|$old_hash|$new_hash|" "$target_file"
          log_info "Hash updated in $(basename "$target_file")"
        fi
        log_info "Rev: ${old_rev:0:7} -> ${new_rev:0:7} in $(basename "$target_file")"

        # Re-derive upstream version literals from the fresh src.
        # The overlay carries a magic comment on the line preceding
        # each `upstream = "..."` literal, naming which vu.read* helper
        # to invoke and the manifest path relative to src:
        #
        #   # upstream: readPackageJsonVersion @ packages/foo/package.json
        #   upstream = "1.2.3";
        #
        # This eliminates eval-time IFD — overlays no longer call
        # vu.read* at eval time (which forced realization of the
        # platform-tagged src drv and broke cross-platform eval on
        # PR CI). See .claude/rules/overlays.md § IFD Patterns.
        #
        # One file can carry multiple markers (e.g.,
        # modelcontextprotocol/default.nix has 7 sub-packages, and
        # two of them happen to share the same manifest path). The
        # Python filter indexes by LINE NUMBER so each marker drives
        # its own replacement.
        if [ -n "$storePath" ] && grep -qE '^[[:space:]]*# upstream: ' "$target_file"; then
          # One pass classifies every line that ATTEMPTS a marker.
          #
          # "Attempts" is anchored to the start of the comment, so prose
          # that merely mentions the convention mid-sentence (e.g.
          # modelcontextprotocol/default.nix:25, "see # upstream:
          # comments") is not mistaken for a marker — an unanchored
          # match there would hold back a package over a doc comment.
          #
          # A line that attempts a marker but does not parse is
          # MALFORMED: a missing `@`, a non-alphabetic helper name, a
          # mangled path. Classifying per line rather than all-or-
          # nothing matters because a file can carry several markers
          # (this one has 7) and one broken marker among six good ones
          # would otherwise pass unnoticed — silently freezing exactly
          # one sub-package's version.
          classified=$(awk '
            /^[[:space:]]*# upstream: / {
              if (match($0, /# upstream: ([A-Za-z]+) @ (.+)$/, arr) && arr[1] != "" && arr[2] != "")
                print "OK|" NR "|" arr[1] "|" arr[2];
              else
                print "BAD|" NR;
            }
          ' "$target_file")
          # Prefix each line number with L and join with ", " (e.g.
          # "L12, L15") so a multi-marker list does not read as the
          # ambiguous "L12,15".
          malformed=$(printf '%s\n' "$classified" | awk -F'|' '
            $1 == "BAD" { out = out (out == "" ? "" : ", ") "L" $2 }
            END { print out }
          ')
          if [ -n "$malformed" ]; then
            # Falling through here would bump rev + src.hash while
            # leaving `upstream = "..."` at the previous value, so the
            # package would ship claiming one version and building
            # another. That is the failure mode this guard exists for.
            git -C "$wt" reset --hard "$base_head"
            report_held_back "$name" "malformed upstream marker" \
              "$(basename "$target_file") $malformed: expected '# upstream: <helper> @ <path>'"
            exit 0
          fi
          markers=$(printf '%s\n' "$classified" | awk -F'|' '$1 == "OK" { print $2 "|" $3 "|" $4 }')
          if [ -n "$markers" ]; then
            # For each marker, resolve the new upstream value via nix
            # eval of the corresponding vu.read* helper against the
            # fresh src, then feed a JSON array of
            # {lineno, new_value} pairs to Python to rewrite the file.
            resolved="[]"
            while IFS='|' read -r lineno kind manifest_rel; do
              [ -z "$lineno" ] && continue
              new_upstream=$(nix eval --impure --raw --expr "
                let vu = import (toString $PWD/lib/packaging.nix);
                in vu.$kind ($storePath + \"/$manifest_rel\")
              " 2>/dev/null || true)
              # A marker names a manifest the maintainer asserts exists.
              # Failing to read it means the path moved upstream, the
              # helper name is wrong, or the manifest changed shape. In
              # every case the literal below stays at the OLD version
              # while rev + src.hash have already been bumped, so the
              # package would ship claiming one version and building
              # another. Hold it back rather than continue.
              if [ -z "$new_upstream" ]; then
                git -C "$wt" reset --hard "$base_head"
                report_held_back "$name" "upstream version not derivable" \
                  "$(basename "$target_file") L$lineno: $kind @ $manifest_rel"
                exit 0
              fi
              resolved=$(echo "$resolved" | jq --arg n "$lineno" --arg v "$new_upstream" \
                '. + [{lineno: ($n | tonumber), value: $v}]')
              log_info "Upstream (L$lineno): $kind @ $manifest_rel -> $new_upstream"
            done <<<"$markers"
            if [ "$resolved" != "[]" ]; then
              # Exits non-zero, WITHOUT writing, if any marker had no
              # literal to rewrite — see the rationale in the script.
              if ! python3 - "$target_file" "$resolved" <<'PY'
import json, re, sys
path, spec = sys.argv[1], sys.argv[2]
entries = json.loads(spec)
with open(path) as f:
    lines = f.read().split("\n")
pat = re.compile(r'^(\s*(?:upstream|upstreamVersion|version)\s*=\s*(?:mkPyVersion\s+)?)"[^"]*"(.*)$')
unmatched = []
for e in entries:
    marker_idx = e["lineno"] - 1  # awk is 1-based, python 0-based
    # Replace the FIRST upstream literal that follows this marker
    # (usually the very next line; 5-line window absorbs rare
    # intervening comments/whitespace).
    for j in range(marker_idx + 1, min(marker_idx + 6, len(lines))):
        m = pat.match(lines[j])
        if m:
            lines[j] = f'{m.group(1)}"{e["value"]}"{m.group(2)}'
            break
    else:
        # A marker resolved to a new value but no literal followed it
        # within the window. Writing here would persist the other
        # replacements and silently leave this one stale, so write
        # NOTHING and let the caller hold the package back.
        unmatched.append(e["lineno"])
if unmatched:
    print(
        "no upstream literal within 5 lines of marker(s) at L"
        + ", L".join(str(n) for n in unmatched),
        file=sys.stderr,
    )
    sys.exit(1)
with open(path, "w") as f:
    f.write("\n".join(lines))
PY
              then
                git -C "$wt" reset --hard "$base_head"
                report_held_back "$name" "upstream literal not rewritten" \
                  "$(basename "$target_file"): marker resolved but no literal followed it"
                exit 0
              fi
            fi
          fi
        fi

        # Commit rev + src hash + upstream version so nix-update has a
        # clean tree to evaluate
        git -C "$wt" add -A
        git -C "$wt" commit -m "chore(packages): update $name"
      fi
    fi
  fi
fi

# Phase 1: Update dep hashes via nix-update (needs clean committed state)
log_info "Running nix-update..."
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

  # Prime the src derivation file in the store. `nix flake prefetch`
  # (Phase 0) populates the source output but does NOT create a .drv
  # for the fetchFromGitHub derivation — .drv files are machine-local
  # and not produced by the flake-prefetch builtin. nix-update's
  # internal nix-instantiate then fails at `readFile "${src}/..."`
  # with "path '...source.drv' is not valid" because readFile's
  # context-realization needs the drv registered. A single
  # `nix eval` on drvPath instantiates the derivation file without
  # building the output, which is enough to unblock nix-update.
  nix eval --raw ".#$name.src.drvPath" >/dev/null 2>&1 || true

  # `if !` rather than a bare pipeline plus a PIPESTATUS test: `pipefail`
  # already makes the pipeline's status nix-update's, and with errexit armed
  # a bare pipeline would abort before any status check ran, losing this
  # message.
  # shellcheck disable=SC2086
  if ! nix run --inputs-from . nix-update -- --flake "$name" --system "$system" $extra_flags 2>&1 | tee "$version_file"; then
    # PIPESTATUS survives into this block — measured, including the real
    # exit code and which side failed:
    #   $ if ! bash -c 'exit 42' | tee /dev/null; then echo "${PIPESTATUS[*]}"; fi
    #   42 0
    # so the `if !` form costs nothing in diagnosis. Report both: under
    # `pipefail` a `tee` failure (full disk, bad path) fails the pipeline
    # just as loudly as the real command, and attributing it to the wrong
    # one sends the next reader looking in the wrong place.
    pipe=("${PIPESTATUS[@]}")
    log_failure "nix-update failed (nix-update=${pipe[0]} tee=${pipe[1]})"
    exit 1
  fi

  # Formatter pass — normalize anything the updateScript regenerated
  # (e.g. claude-code's extraExtract cp's jq output, whose multi-line
  # arrays biome collapses onto one line). Mirrors update-input.sh
  # Phase 2.5, but the trigger here is "the updateScript wrote files"
  # (dirty tree) rather than "the formatter store path moved" — a
  # package bump can emit non-canonical files even when the formatter
  # itself is unchanged. Without it the per-package PR ships an
  # unformatted sidecar and PR CI's checks.formatting fails. No base-checkout
  # final pass can see the isolated update branch, so this pass is authoritative.
  # Gated on a dirty tree so a no-op update doesn't trigger a spurious reformat
  # commit. `nix fmt` exits 0 on successful in-place
  # format (no --fail-on-change); a non-zero exit is a real formatter
  # error, which leaves the tree non-canonical and therefore holds the
  # package back.
  #
  # Both dirtiness gates below go through git_diff_quiet, which discriminates
  # the THREE-valued diff status by value instead of by truthiness. Under the
  # bare `! git … diff --quiet` form an ERRORING git read as "the tree is
  # dirty" at both gates at once: the `||` short-circuits, so a failure of the
  # FIRST invocation skipped the second entirely and flipped both gates from
  # one fault. Reasoning about either gate in isolation understated it. The
  # gate below is the harmless half (a redundant reformat); the gate after it
  # is the one that stages everything and commits or amends.
  if ! git_diff_quiet -C "$wt" diff || ! git_diff_quiet -C "$wt" diff --staged; then
    # Explicit `exit`, because this body is the CONDITION of the `if ! (`
    # above and bash disables errexit for a condition — a bare failing
    # call falls through to the build below instead of aborting.
    if ! run_build nix fmt; then
      log_failure "formatter errored"
      exit 1
    fi
  fi

  # Commit dep hash changes (amend if update commit exists, new commit
  # otherwise). This is the failure-becomes-a-commit shape git_diff_quiet
  # closes: with the tree genuinely clean and `git diff` merely erroring, the
  # bare form reached `commit --amend`, which succeeds on an unchanged tree and
  # rewrote the update commit for no reason.
  if ! git_diff_quiet -C "$wt" diff || ! git_diff_quiet -C "$wt" diff --staged; then
    # Same explicit-exit rule as the formatter gate above: a failure to
    # stage or commit means the PR cannot be written, which is a
    # hold-back, and errexit will not deliver it for us.
    if ! git -C "$wt" add -A; then
      log_failure "git add failed"
      exit 1
    fi
    if [ "$(git -C "$wt" rev-parse HEAD)" != "$base_head" ]; then
      git -C "$wt" commit --amend --no-edit || {
        log_failure "git commit --amend failed"
        exit 1
      }
    else
      git -C "$wt" commit -m "chore(packages): update $name" || {
        log_failure "git commit failed"
        exit 1
      }
    fi
  fi

  # Nothing changed from base
  if [ "$(git -C "$wt" rev-parse HEAD)" = "$base_head" ]; then
    exit 0
  fi

  # Phase 2: Build verification — INFORMATIONAL, not a gate.
  #
  # nix-update already derived every dependency hash the PR needs, and its
  # own failure exits above. So reaching here means the tree is complete
  # and committable: rev, src and hashes are all written. A build that
  # still fails means the update is well-formed but does not build —
  # a dependency floor the pinned nixpkgs cannot satisfy, say — and that
  # is a red PR for branch CI to report, not a reason to withhold it.
  #
  # This USED to be the last command in the subshell, which is the only
  # reason a failing build held the package back: errexit is disabled for
  # an `if` condition, so position was doing the work, not intent.
  # CI publishes after preparation; native PR shards perform this validation.
  # Local Ninja retains its informational build and all resource safeguards.
  if [ "${NAT_UPDATE_VERIFY_PACKAGES:-1}" = "0" ]; then
    log_info "Prepared update — native PR CI will verify the build"
  elif ! run_build nix build ".#$name" --no-link --log-format bar-with-logs; then
    log_info "Build failed — opening the PR; branch CI is the gate"
    echo "::warning::${name}: build verification failed, PR opens red"
  fi
  # Belt and braces: keep the subshell's exit status independent of the
  # build above even if a later edit adds a statement here.
  true
)
target_rc=$?
set -e

if [ "$target_rc" -ne 0 ]; then
  version_detail=$(parse_pkg_version "$version_file")
  # Roll back the Phase 0 rev+src commit so a held-back package does
  # NOT leave a branch ahead of base. The PR-creation step in
  # .github/workflows/update.yml filters on `wt_head == base_head`, so
  # resetting here is what makes held-back packages skip their PR.
  # Successful targets keep their commit and open their PR as before.
  git -C "$wt" reset --hard "$base_head"
  report_held_back "$name" "nix-update, formatter or commit failed" "$version_detail"
  exit 0
fi

# Extract version info
version_detail=$(parse_pkg_version "$version_file")

# Check if the worktree actually made commits
wt_head=$(git -C "$wt" rev-parse HEAD)
if [ "$wt_head" = "$base_head" ]; then
  report_unchanged "$name"
  exit 0
fi

log_success "$name: branch update/$name ready for PR"
report_updated "$name" "$version_detail"

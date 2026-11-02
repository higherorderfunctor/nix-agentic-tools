# cspell:ignore objectname objecttype symref urandom
{
  lib,
  pkgs,
}: let
  git = lib.getExe pkgs.git;
in {
  cleanup = ''
    if [[ -n ''${repo_token:-} ]]; then
      # Keep the session lock held until all its retention refs are removed.
      repo_git --git-dir="$repo_common" for-each-ref --format='delete %(refname)' "refs/sandbox/$repo_token/" \
        | repo_git --git-dir="$repo_common" update-ref --stdin \
        || echo 'sandbox: could not remove retention refs; the next launch will reap them' >&2
    fi
    repo_release_gc
  '';
  prepare = ''
    # Ignore inherited Git environment and user init choices in generated repos.
    repo_git() {
      env -i PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        GIT_NO_REPLACE_OBJECTS=1 ${git} -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
    }
    repo_release_gc() {
      if [[ ''${repo_gc_published:-0} == 1 ]]; then
        if [[ -f $repo_common/gc.pid && $(< "$repo_common/gc.pid") == "$$ $repo_gc_host" ]]; then
          rm -f -- "$repo_common/gc.pid"
        fi
        repo_gc_published=0
      fi
      if [[ ''${repo_gc_locked:-0} == 1 ]]; then
        rm -f -- "$repo_common/gc.pid.lock"
        repo_gc_locked=0
      fi
      if [[ ''${repo_maintenance_locked:-0} == 1 ]]; then
        rm -f -- "$repo_common/objects/maintenance.lock"
        repo_maintenance_locked=0
      fi
    }
    if ! repo_common=$(repo_git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
      echo 'sandbox: repo mode requires a Git repository' >&2
      exit 2
    fi
    repo_head=$(repo_git rev-parse --verify --quiet 'HEAD^{commit}') || repo_head=
    repo_branch=$(repo_git symbolic-ref --quiet --short HEAD) || repo_branch=
    if [[ -z $repo_head && -z $repo_branch ]]; then
      echo 'sandbox: HEAD is neither a commit nor an unborn branch' >&2
      exit 2
    fi
    repo_format=$(repo_git rev-parse --show-object-format)
    case "$repo_format" in
      sha1|sha256) ;;
      *) echo "sandbox: unsupported object format: $repo_format" >&2; exit 2 ;;
    esac
    if [[ $(repo_git rev-parse --is-shallow-repository) == true ]]; then
      echo 'sandbox: shallow repositories are unsupported' >&2
      exit 2
    fi
    repo_promisors=("$repo_common"/objects/pack/*.promisor)
    if repo_git config --get extensions.partialClone >/dev/null \
      || repo_git config --get-regexp '^remote\..*\.promisor$' >/dev/null \
      || [[ -e ''${repo_promisors[0]} ]]; then
      echo 'sandbox: partial repositories are unsupported' >&2
      exit 2
    fi
    if [[ -s $repo_common/objects/info/alternates || -s $repo_common/objects/info/http-alternates ]]; then
      echo 'sandbox: repositories using object alternates are unsupported' >&2
      exit 2
    fi
    repo_remote=
    if [[ -n $repo_branch ]]; then
      repo_remote=$(${git} config --get "branch.$repo_branch.pushRemote") || repo_remote=
    fi
    if [[ -z $repo_remote ]]; then
      repo_remote=$(${git} config --get remote.pushDefault) || repo_remote=
    fi
    if [[ -z $repo_remote && -n $repo_branch ]]; then
      repo_remote=$(${git} config --get "branch.$repo_branch.remote") || repo_remote=
    fi
    repo_remote=''${repo_remote:-origin}
    if ! repo_git check-ref-format "refs/remotes/$repo_remote/probe"; then
      echo 'sandbox: push remote cannot name a remote-tracking ref namespace' >&2
      exit 2
    fi
    repo_refs=
    if [[ -n $repo_head ]]; then
      repo_refs=$(repo_git for-each-ref --format='%(objectname) %(refname) %(symref)' "refs/remotes/$repo_remote/")
    fi
  '';
  recover = ''
    recovery_failed=0
    recovery_status=$(< bundle-status)
    if [[ $recovery_status == empty && ! -s bundle ]]; then
      :
    else
      bundle_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/ai-sandbox/bundles"
      mkdir -p -- "$bundle_dir"
      bundle_path="$bundle_dir/$repo_token.bundle"
      failed_path="$bundle_dir/$repo_token.failed.bundle"
      # Preserve the original export even if validation or repacking fails.
      if [[ -s bundle ]]; then
        mv -- bundle "$failed_path"
      fi
      complete_recovery() {
        repo_git init --quiet --bare --template= --object-format="$repo_format" --initial-branch=recovery recovery || return
        printf '%s\n' "$repo_common/objects" > recovery/objects/info/alternates || return
        repo_git -C recovery bundle unbundle "$failed_path" > recovery-refs || return
        while read -r oid ref; do
          repo_git -C recovery update-ref --no-deref "$ref" "$oid" || return
        done < recovery-refs
        recovery_head=()
        if repo_git -C recovery rev-parse --verify --quiet HEAD >/dev/null; then
          recovery_head=(HEAD)
        fi
        # A complete bundle survives removal of session pins and later host GC.
        repo_git -C recovery bundle create "$bundle_path.tmp" --all "''${recovery_head[@]}" || return
        mv -- "$bundle_path.tmp" "$bundle_path"
      }
      if [[ $recovery_status == ok && -s $failed_path ]] \
        && repo_git --git-dir="$repo_common" bundle verify "$failed_path" \
        && complete_recovery; then
        rm -- "$failed_path"
        printf 'sandbox: verified committed-work recovery: git fetch %q' "$bundle_path" >&2
        if (( ''${#recovery_head[@]} )); then
          printf ' %q' "HEAD:refs/recovered/$repo_token/HEAD" >&2
        fi
        printf ' %q\n' "refs/*:refs/recovered/$repo_token/*" >&2
      else
        recovery_failed=1
        if [[ -s $failed_path ]]; then
          echo "sandbox: recovery failed; unverified data saved to $failed_path" >&2
        else
          echo 'sandbox: recovery failed; guest did not finish a graceful committed-work export' >&2
        fi
      fi
    fi
  '';
  start = ''
    # Coordinate with both Git GC and maintenance until every borrowed object
    # is pinned and checked, including descendants of roots captured earlier.
    if ! (set -C; : > "$repo_common/objects/maintenance.lock"); then
      echo 'sandbox: could not acquire repository maintenance lock; another sandbox launch or Git maintenance may be active; retry after it finishes' >&2
      exit 2
    fi
    repo_maintenance_locked=1
    if ! (set -C; : > "$repo_common/gc.pid.lock"); then
      echo 'sandbox: could not acquire repository GC lock; another sandbox launch or Git GC may be active; retry after it finishes' >&2
      exit 2
    fi
    repo_gc_locked=1
    repo_gc_host=$(uname -n)
    if [[ -e $repo_common/gc.pid ]]; then
      repo_gc_record=$(< "$repo_common/gc.pid")
      read -r repo_gc_pid repo_gc_owner repo_gc_extra <<< "$repo_gc_record"
      if [[ ! $repo_gc_pid =~ ^[1-9][0-9]*$ || -z $repo_gc_owner || -n $repo_gc_extra \
        || $repo_gc_owner != "$repo_gc_host" ]] \
        || kill -0 "$repo_gc_pid" 2>/dev/null || [[ -d /proc/$repo_gc_pid ]]; then
        echo 'sandbox: repository GC is active or its owner is unknown; retry after it finishes' >&2
        exit 2
      fi
    fi
    printf '%s %s' "$$" "$repo_gc_host" > "$repo_common/gc.pid.lock"
    repo_gc_published=1
    mv -- "$repo_common/gc.pid.lock" "$repo_common/gc.pid"
    repo_gc_locked=0
    repo_git init --quiet --bare --template= --object-format="$repo_format" --initial-branch=sandbox seed
    ln -s -- "$repo_common/objects" objects
    printf '%s\n' /mnt/objects > seed/objects/info/alternates
    printf '%s' "$repo_head" > repo-head
    printf '%s' "$repo_branch" > repo-branch
    : > seed-roots
    : > bundle
    : > bundle-status
    mkdir -p -- "$repo_common/sandbox-locks"
    repo_token=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
    # Lock before publishing any pins. Lock files stay to avoid inode races.
    exec {repo_lock}>"$repo_common/sandbox-locks/$repo_token"
    flock -x "$repo_lock"
    while read -r stale_ref; do
      stale_token=''${stale_ref#refs/sandbox/}
      stale_token=''${stale_token%%/*}
      [[ $stale_token =~ ^[0-9a-f]{32}$ ]] || continue
      [[ $stale_token != "$repo_token" ]] || continue
      (
        flock -n 9 || exit 0
        repo_git --git-dir="$repo_common" update-ref -d "$stale_ref"
      ) 9>"$repo_common/sandbox-locks/$stale_token"
    done < <(repo_git --git-dir="$repo_common" for-each-ref --format='%(refname)' refs/sandbox/)
    if [[ -n $repo_head ]]; then
      mkdir -p seed/refs/sandbox
      printf '%s\n' "$repo_head" > seed/refs/sandbox/head
      printf '%s\n' "$repo_head" >> seed-roots
    fi
    while read -r oid ref symbolic; do
      [[ -n $oid && -z $symbolic ]] || continue
      if [[ $(repo_git --git-dir="$repo_common" cat-file -t "$oid") != commit ]]; then
        echo "sandbox: remote-tracking ref is not a commit: $ref" >&2
        exit 2
      fi
      seed_ref="refs/heads/''${ref#refs/remotes/"$repo_remote"/}"
      repo_git check-ref-format "$seed_ref"
      mkdir -p -- "seed/''${seed_ref%/*}"
      printf '%s\n' "$oid" > "seed/$seed_ref"
      printf '%s\n' "$oid" >> seed-roots
    done <<< "$repo_refs"
    sort -u -o seed-roots seed-roots
    pin=0
    while read -r oid; do
      printf 'create refs/sandbox/%s/%s %s\n' "$repo_token" "$pin" "$oid"
      pin=$((pin + 1))
    done < seed-roots > pins
    repo_git --git-dir="$repo_common" update-ref --stdin < pins
    if ! repo_git --git-dir="$repo_common" rev-list --objects --no-object-names --stdin < seed-roots \
      | repo_git --git-dir="$repo_common" cat-file --batch-check='%(objecttype)' \
      | while read -r object_type; do
          case "$object_type" in
            blob|commit|tag|tree) ;;
            *) exit 1 ;;
          esac
        done; then
      echo 'sandbox: a borrowed object was removed before retention; retry after repository repair' >&2
      exit 2
    fi
    repo_release_gc
    if [[ -n $repo_branch ]]; then
      printf 'ref: refs/heads/%s\n' "$repo_branch" > seed/HEAD
    fi
  '';
}

# cspell:ignore objectname symref urandom
{
  lib,
  pkgs,
}: let
  # Larger guest exports are discarded rather than saved for recovery.
  bundleLimitMiB = 1024;
  git = lib.getExe pkgs.git;
in {
  prepare = ''
    # Ignore inherited Git environment and user init choices in generated repos.
    repo_git() {
      env -i PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        GIT_NO_REPLACE_OBJECTS=1 ${git} -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
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
    # Remote selection keeps the user's global config but, like repo_git,
    # ignores an inherited GIT_DIR or `git -c` (GIT_CONFIG_PARAMETERS).
    repo_config() {
      env -i PATH="$PATH" ''${HOME:+HOME="$HOME"} ''${XDG_CONFIG_HOME:+XDG_CONFIG_HOME="$XDG_CONFIG_HOME"} \
        ''${GIT_CONFIG_GLOBAL:+GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL"} ${git} config --get "$@"
    }
    repo_remote=
    if [[ -n $repo_branch ]]; then
      repo_remote=$(repo_config "branch.$repo_branch.pushRemote") || repo_remote=
    fi
    if [[ -z $repo_remote ]]; then
      repo_remote=$(repo_config remote.pushDefault) || repo_remote=
    fi
    if [[ -z $repo_remote && -n $repo_branch ]]; then
      repo_remote=$(repo_config "branch.$repo_branch.remote") || repo_remote=
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
    # The guest sizes this file; refuse to keep more than the limit on host disk.
    if (( $(${pkgs.coreutils}/bin/stat -c %s bundle) > ${toString bundleLimitMiB} * 1024 * 1024 )); then
      echo 'sandbox: guest export exceeds the ${toString bundleLimitMiB} MiB recovery limit; discarded it' >&2
      ${pkgs.coreutils}/bin/rm -f -- bundle
      recovery_status=oversized
    fi
    if [[ $recovery_status == empty && ! -s bundle ]]; then
      :
    else
      bundle_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/ai-sandbox/bundles"
      ${pkgs.coreutils}/bin/mkdir -p -- "$bundle_dir"
      bundle_path="$bundle_dir/$repo_token.bundle"
      failed_path="$bundle_dir/$repo_token.failed.bundle"
      # Preserve the original export even if validation or repacking fails.
      if [[ -s bundle ]]; then
        ${pkgs.coreutils}/bin/mv -- bundle "$failed_path"
      fi
      complete_recovery() {
        repo_git init --quiet --bare --template= --object-format="$repo_format" --initial-branch=recovery recovery || return
        printf '%s\n' "$runtime_dir/seed/objects" > recovery/objects/info/alternates || return
        repo_git -C recovery bundle unbundle "$failed_path" > recovery-refs || return
        while read -r oid ref; do
          repo_git -C recovery update-ref --no-deref "$ref" "$oid" || return
        done < recovery-refs
        recovery_head=()
        if repo_git -C recovery rev-parse --verify --quiet HEAD >/dev/null; then
          recovery_head=(HEAD)
        fi
        # A complete bundle outlives the seed and later host GC.
        repo_git -C recovery bundle create "$bundle_path.tmp" --all "''${recovery_head[@]}" || return
        ${pkgs.coreutils}/bin/mv -- "$bundle_path.tmp" "$bundle_path"
      }
      if [[ $recovery_status == ok && -s $failed_path ]] \
        && repo_git --git-dir=seed bundle verify "$failed_path" \
        && complete_recovery; then
        ${pkgs.coreutils}/bin/rm -- "$failed_path"
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
    repo_git init --quiet --bare --template= --object-format="$repo_format" --initial-branch=sandbox seed
    printf '%s' "$repo_head" > repo-head
    printf '%s' "$repo_branch" > repo-branch
    : > seed-roots
    : > bundle
    : > bundle-status
    repo_token=$(${pkgs.coreutils}/bin/od -An -tx1 -N16 /dev/urandom | ${pkgs.coreutils}/bin/tr -d ' \n')
    if [[ -n $repo_head ]]; then
      ${pkgs.coreutils}/bin/mkdir -p seed/refs/sandbox
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
      ${pkgs.coreutils}/bin/mkdir -p -- "seed/''${seed_ref%/*}"
      printf '%s\n' "$oid" > "seed/$seed_ref"
      printf '%s\n' "$oid" >> seed-roots
    done <<< "$repo_refs"
    sort -u -o seed-roots seed-roots
    # Copy only the seeded history into the seed's own pack, so stashes, other
    # branches and amended-away commits never reach the guest. --stdout keeps
    # pack-objects' temporary files out of the host repository.
    if [[ -s seed-roots ]] && ! repo_git --git-dir="$repo_common" pack-objects --revs --stdout --quiet < seed-roots \
      | repo_git --git-dir=seed index-pack --stdin > /dev/null; then
      echo 'sandbox: could not copy the seeded history from the host repository; retry after repository repair' >&2
      exit 2
    fi
    if [[ -n $repo_branch ]]; then
      printf 'ref: refs/heads/%s\n' "$repo_branch" > seed/HEAD
    fi
  '';
}

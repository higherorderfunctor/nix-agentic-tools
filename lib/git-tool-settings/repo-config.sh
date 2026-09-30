#!/usr/bin/env bash
# Repository-local git configuration for the devenv `git.*` modules. The ONE
# script behind the devenv tasks `git:config` (packages/git) and
# `git:branchless-init` (packages/git-branchless), and the one the runtime
# checks run (checks/git-config/runtime.nix), packaged by repo-config.nix.
#
#   include ROOT [RENDERED]
#       Publish RENDERED (a git config file) read-only as
#       <common>/nix-agentic-tools.gitconfig and make its include.path the
#       LAST entry of the common repository config, so every key it sets beats
#       every other repository-local layer: git-branchless's branchless/config
#       and hand edits alike. Keys it does not set fall through. It repairs the
#       position on every call: a later `git config` that appended a section
#       after it is moved above it again. Without RENDERED it removes the
#       include and the file; outside a repository that is a no-op.
#   init ROOT GIT_BRANCHLESS [MAIN_BRANCH]
#       Run `git branchless init` for the repository at ROOT, with
#       `--main-branch MAIN_BRANCH` when given. Without it, the main branch
#       branchless/config already records is passed back, so a re-run never
#       replaces a repository's choice with auto-detection. For an unborn HEAD
#       or bare primary, the primary HEAD supplies the explicit branch that
#       init needs. A failure names the command to retry by hand.
#
# Both hold one lock in the common git directory, so tasks entered from
# different linked worktrees serialize on the shared config and branchless
# state.
shopt -s inherit_errexit 2>/dev/null || :

name=nix-agentic-tools.gitconfig

notice() {
  printf 'nix-agentic-tools git: %s\n' "$*" >&2
}

usage() {
  notice "usage: nix-agentic-tools-git include ROOT [RENDERED] | init ROOT GIT_BRANCHLESS [MAIN_BRANCH]"
  exit 2
}

lock_common_dir() {
  exec {lock_fd}>"$common/.nix-agentic-tools-git.lock"
  flock "$lock_fd"
}

# Remove this module's include.path entries from a config file. `git config`
# exits 5 when there is nothing to remove, which is not an error here.
unset_include() {
  local status=0
  git config --file "$1" --fixed-value --unset-all include.path "$name" || status=$?
  case "$status" in
  0 | 5) ;;
  *) exit "$status" ;;
  esac
}

# The config's last entry, as `key<newline>value`. Entries are NUL-separated
# with --null, so a value holding a newline cannot fake a boundary.
last_entry() {
  git config --file "$config" --null --list | tail -z -n 1 | tr -d '\0'
}

# Rewrite the common config with the include as a trailing [include] section.
# Follows git's own lockfile protocol: create config.lock exclusively (so a
# concurrent `git config` fails instead of losing an update, and this fails
# when one is in flight), build the new content beside it, rename it over the
# lock, then rename the lock over the config.
move_include_last() {
  local lockfile="$config.lock" tmp
  if ! (set -o noclobber && : >"$lockfile") 2>/dev/null; then
    notice "cannot update $config: $lockfile exists (another git process is writing it)"
    exit 1
  fi
  tmp="$(mktemp "$common/.config.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: the paths are fixed
  trap "rm -f '$tmp' '$lockfile'" EXIT
  cp "$config" "$tmp"
  unset_include "$tmp"
  if [ -s "$tmp" ] && [ -n "$(tail -c 1 "$tmp")" ]; then
    printf '\n' >>"$tmp"
  fi
  printf '[include]\n\tpath = %s\n' "$name" >>"$tmp"
  chmod --reference="$config" "$tmp"
  mv -f "$tmp" "$lockfile"
  mv -f "$lockfile" "$config"
  trap - EXIT
}

include() {
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
  local root="$1" rendered="${2:-}" tmp
  if [ -z "$rendered" ] && ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
  config="$common/config"
  lock_common_dir

  if [ -z "$rendered" ]; then
    unset_include "$config"
    rm -f "$common/$name"
    return 0
  fi

  tmp="$(mktemp "$common/.$name.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: the path is fixed
  trap "rm -f '$tmp'" EXIT
  install -m 0444 "$rendered" "$tmp"
  mv -f "$tmp" "$common/$name"
  trap - EXIT

  if [ "$(last_entry)" != "include.path"$'\n'"$name" ]; then
    move_include_last
  fi
}

init() {
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
  local root="$1" branchless="$2" main="${3:-}" status=0
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"

  lock_common_dir
  if [ -z "$main" ] && [ -f "$common/branchless/config" ]; then
    main="$(git config --file "$common/branchless/config" branchless.core.mainBranch || :)"
  fi
  if [ -z "$main" ] && {
    [ "$(git --git-dir="$common" rev-parse --is-bare-repository)" = true ] ||
      ! git -C "$root" rev-parse --verify --quiet HEAD >/dev/null
  }; then
    main="$(git --git-dir="$common" symbolic-ref --quiet --short HEAD || :)"
  fi
  local args=(branchless init)
  if [ -n "$main" ]; then
    args+=(--main-branch "$main")
  fi
  PATH="$(dirname "$branchless"):$PATH" git -C "$root" "${args[@]}" </dev/null || status=$?
  if [ "$status" -ne 0 ]; then
    notice "git branchless init failed for $root (exit $status)"
    printf 'nix-agentic-tools git: run by hand: git -C %q' "$root" >&2
    printf ' %q' "${args[@]}" >&2
    printf '\n' >&2
  fi
  return "$status"
}

[ "$#" -ge 1 ] || usage
command="$1"
shift
case "$command" in
include) include "$@" ;;
init) init "$@" ;;
*) usage ;;
esac

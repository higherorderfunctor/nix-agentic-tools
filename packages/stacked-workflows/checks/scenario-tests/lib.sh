#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
git_in() { (cd "$1" && shift && git "$@"); }
c() {
  echo "${3:-$2 content}" >"$1/$2"
  git_in "$1" add "$2"
  git_in "$1" commit -qm "$2"
}
# primary P on main (stale), upstream pusher up; worktrees via origin/main
topo() {
  git init -q --bare origin.git
  git clone -q origin.git up 2>/dev/null
  c up base
  git_in up push -q origin main
  git clone -q origin.git P 2>/dev/null
  (cd P && git branchless init >/dev/null 2>&1)
  c up upstream1
  git_in up push -q origin main
  git_in P fetch -q origin
}
wt() { git_in "$E/P" worktree add -q -b "$1" "$E/wt-$1" "${2:-origin/main}" 2>&1 | grep -v '^branch' || :; }

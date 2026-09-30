#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
fresh() {
  E="$CASE_ROOT"
  mkdir -p "$E/home/.config/git" "$E/tmp"
  unset GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE || :
  export HOME="$E/home" XDG_CONFIG_HOME="$E/home/.config" GIT_CONFIG_NOSYSTEM=1
  export TMPDIR="$E/tmp"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export GIT_EDITOR=true NO_COLOR=1 CLICOLOR=0
  cd "$E"
  git config --global init.defaultBranch main
  git config --global branchless.hint.moveImplicitHeadArgument false
  git config --global branchless.hint.restackWarnAbandoned false
  cd "$E"
}
own() {
  wt a
  c wt-a a1 'a1 old'
  git_in wt-a branch a-1 HEAD
  c wt-a a2 'a2 old'
}
advance() {
  c up upstream2
  git_in up push -q origin main
  git_in P fetch -q origin
}
T1() {
  topo
  own
  wt b
  c wt-b b1
  advance
}
T2() {
  T1
  wt d a-1
  c wt-d d1
}
T3() {
  topo
  wt a
  wt b
  c wt-b b1
  advance
}
T4() {
  topo
  git_in P merge -q --ff-only origin/main
  own
}
T5() {
  topo
  own
  git init -q --bare empty.git
  git_in P remote set-url origin "$E/empty.git"
  git_in P update-ref -d refs/remotes/origin/main
  git_in P symbolic-ref -d refs/remotes/origin/HEAD || :
}
T6() {
  T1
  git_in P worktree add -q --detach "$E/wt-e" a-1
  c wt-e e1
}
T7() {
  T1
  git_in wt-a merge -q --no-edit origin/main
  c wt-a a4
  c up upstream3
  git_in up push -q origin main
  git_in P fetch -q origin
}
T8() {
  topo
  wt a
  c wt-a f 1
  git_in wt-a branch a-1 HEAD
  if [ "${SQUASH_COUNT:-multi}" = multi ]; then
    if [ "${SQUASH_OVERLAP:-yes}" = yes ]; then c wt-a f 2; else c wt-a g 2; fi
  fi
  git_in wt-a branch a-2 HEAD
  c wt-a a3
  git_in up fetch -q "$E/P" a-2
  git_in up merge -q --squash "$(git_in wt-a rev-parse a-2)"
  git_in up commit -qm squash
  git_in up push -q origin main
  git_in P fetch -q origin
}
T9() { T2; }
T10() {
  topo
  git_in P merge -q --ff-only origin/main
  c P localmain
  wt a main
  c wt-a a1
  c wt-a a2
}
T11() {
  T1
  git_in P worktree add -q -b fork "$E/fork" a-1
  c fork fork1
  git_in P worktree remove "$E/fork"
}
T12() {
  T1
  git_in P branch trunk origin/main
  git_in P config branch.main.remote .
  git_in P config branch.main.merge refs/heads/trunk
}
fresh
"$TOPOLOGY"

# shellcheck shell=bash
# Transcription of home-manager's `run` helper (modules/lib-bash/activation-init.sh),
# which every activation script gets in its preamble. `lib/ai/own.nix` routes
# each HM entry's one mutating command through `run` so DRY_RUN echoes it
# instead of executing it — that is the only thing that keeps
# `home-manager switch --dry-run` from writing runtime settings and ledgers
# for real. Runtime checks execute an entry's `.text` under a plain bash with
# no such preamble, so they must source this definition first, or the entry
# fails with "run: command not found". Never "fix" that by dropping `run`
# from the entry text instead — that would reopen the dry-run write bug.
run() {
  local quiet='' silence=''
  if [[ $1 == --quiet ]]; then
    quiet=1
    shift
  elif [[ $1 == --silence ]]; then
    silence=1
    shift
  fi
  if [[ -v DRY_RUN ]]; then
    echo "$@"
  elif [[ -n $silence ]]; then
    "$@" >/dev/null 2>&1
  elif [[ -n $quiet ]]; then
    "$@" >/dev/null
  else "$@"; fi
}

#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# Shared helpers for the delegate replay probes; source, do not execute.
# probe_pkg <attr>   store path of .#ciPackages.<system>.<attr> (built on demand)
# probe_workdir <n>  $PROBE_OUT/<n> when PROBE_OUT is set, else a fresh temp dir

probe_repo_root() {
  git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel
}

probe_pkg() {
  local root system
  root="$(probe_repo_root)"
  system="$(nix eval --impure --raw --expr builtins.currentSystem)"
  nix build --no-link --print-out-paths "$root#ciPackages.$system.$1" | head -n1
}

probe_workdir() {
  if [[ -n ${PROBE_OUT:-} ]]; then
    mkdir -p "$PROBE_OUT/$1"
    printf '%s\n' "$PROBE_OUT/$1"
  else
    mktemp -d -t "delegate-probe-$1.XXXXXX"
  fi
}

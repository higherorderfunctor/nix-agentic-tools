# Tier-1b hook contract-test derivation — PROTOTYPE. NOT wired into checks/ or flake.nix.
#
# This is the hermetic wrapper that would graduate into `checks/hook-contract-tests.nix` and union
# into `checks.<system>` (flake.nix:216), mirroring `checks/validate-at-stop.nix`. It shellchecks every
# script (`-x`, the repo pre-commit standard) then runs the fixture suite under a sandboxed,
# network-free `runCommandLocal` — exactly what `nix flake check` allows.
#
# It stays OUT of the flake for now because (a) the hooks-under-test are hand-written PROTOTYPES, not
# the typed factory's real `mkHookScript` output, and (b) the fixtures are documented-from-docs, not
# Tier-2 real captures. Promote only after Phase-1 emits real scripts and the Tier-2 probe seeds real
# stdin. NOTE (nix-standards): flake `src` sees only git-tracked files — `git add` this tree before a
# flake build, or a check that imports it will see an empty src.
#
# Standalone build:  nix-build --max-jobs 1 contract-test.nix
# As a check:        import ./contract-test.nix { inherit pkgs; }   # from a checks/ aggregator
{pkgs ? import <nixpkgs> {}}:
pkgs.runCommandLocal "hook-contract-tests" {
  nativeBuildInputs = [
    pkgs.bash
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.jq
    pkgs.shellcheck
  ];
  src = ./.;
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  cp -r "$src"/. .
  chmod -R u+w .

  # Lint gate — matches the -x pre-commit standard (see feedback: shellcheck -x).
  shellcheck -x run-contract-tests.sh hooks-under-test/*.sh

  # Hermetic contract suite: documented stdin payload -> generated hook -> assert stdout/exit.
  bash run-contract-tests.sh

  mkdir -p "$out"
  touch "$out/ok"
''

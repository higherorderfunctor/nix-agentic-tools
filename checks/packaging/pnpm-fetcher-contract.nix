# pnpm-fetcher-contract check — every pnpm this repo exposes must satisfy the
# argument contract `fetchPnpmDeps` imposes on its `pnpm` parameter.
#
# The contract is one attribute, and it is not obvious from either side.
# `fetch-pnpm-deps/default.nix` builds its state-db fixup helper as
# `pnpm-fixup-state-db.override {inherit (pnpm) nodejs-slim;}`, so a pnpm handed
# to that fetcher without a `nodejs-slim` passthru dies at EVALUATION with:
#
#     error: attribute 'nodejs-slim' missing
#
# which names neither pnpm nor the fetcher, and points at a nixpkgs file the
# reader did not write.
#
# WHY THIS CHECK EXISTS RATHER THAN A COMMENT. `pnpm_12` shipped without that
# passthru and the gap stayed latent from the day it was written. It is built
# from the per-platform `@pnpm/exe.*` native binaries instead of nixpkgs'
# `generic.nix`, so it never inherited the argument of the same name — and
# nothing in the repo passed it to `fetchPnpmDeps`, so nothing evaluated the
# combination. `checks/packaging/pnpm-fetcher-parity.nix` could not catch it either: that
# check enumerates packages which already ship a `pnpmDeps`, and none of them
# used pnpm 12. The gap surfaced only when oxlint became the first such
# consumer, roughly a year later.
#
# Packaging a pnpm major is therefore NOT the same as proving it usable as a
# fetcher argument, and the difference is invisible until someone tries.
#
# Counter-intuitive for pnpm 12 specifically: it is a self-contained native
# binary that needs no Node to RUN. The Node is not for pnpm — it is for the
# fetcherVersion-4 SQLite state-db fixup helper, which is a JS program. Do not
# "clean up" the passthru as an unused input.
#
# INTENSIONAL, unlike its sibling. `pnpm-fetcher-parity.nix` is deliberately
# enumerated and documents the measured cost that decided it; this one is not,
# because the discovery is a NAME match over `self.ciPackages.${system}` rather
# than a property probe that must instantiate unrelated derivations. Only the
# matched attributes are evaluated, so a future `pnpm_13` is covered the day it
# is added, with no list to forget.
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;

    packageSet = self.ciPackages.${system};

    # Name-level discovery: cheap, and it cannot miss a new major.
    pnpmNames =
      builtins.filter
      (n: builtins.match "pnpm_[0-9]+" n != null)
      (builtins.attrNames packageSet);

    # The attribute `fetchPnpmDeps` actually reads. Checked by presence rather
    # than by calling the fetcher: the failure being guarded against is an
    # evaluation error, so evaluating the attribute IS the test, and doing it
    # this way costs no build.
    missing = builtins.filter (n: !(packageSet.${n} ? nodejs-slim)) pnpmNames;

    # A check that silently matches nothing would pass forever while proving
    # nothing — the same "tripwire that can only pass" failure this repo guards
    # against elsewhere. The repo carries pnpm 10, 11 and 12 today.
    tooFew = builtins.length pnpmNames < 3;
  in {
    pnpm-fetcher-contract = pkgs.runCommand "pnpm-fetcher-contract" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${lib.optionalString tooFew ''
        echo "FAIL: matched ${toString (builtins.length pnpmNames)} pnpm package(s) (${lib.concatStringsSep ", " pnpmNames}); expected at least 3." >&2
        echo "" >&2
        echo "Either the pnpm_<major> naming changed, or majors were retired. If they were" >&2
        echo "retired deliberately, lower the floor in checks/packaging/pnpm-fetcher-contract.nix in" >&2
        echo "the same commit. A discovery filter that matches nothing passes vacuously." >&2
        exit 1
      ''}
      ${lib.optionalString (missing != []) ''
        echo "FAIL: ${toString (builtins.length missing)} pnpm package(s) cannot be passed to fetchPnpmDeps:" >&2
        ${lib.concatMapStringsSep "\n" (n: ''echo "  - ${n}: no 'nodejs-slim' passthru" >&2'') missing}
        echo "" >&2
        echo "fetchPnpmDeps evaluates 'pnpm-fixup-state-db.override {inherit (pnpm) nodejs-slim;}'," >&2
        echo "so passing one of these dies with a bare \"attribute 'nodejs-slim' missing\" that" >&2
        echo "names neither pnpm nor the fetcher." >&2
        echo "" >&2
        echo "Fix: expose it on the derivation, e.g." >&2
        echo "  passthru.nodejs-slim = pkgs.nodejs-slim;" >&2
        echo "It is not a derivation input, so the outPath does not move and existing" >&2
        echo "consumers are unaffected." >&2
        exit 1
      ''}
      echo "pnpm fetcher contract OK for ${toString (builtins.length pnpmNames)} package(s): ${lib.concatStringsSep ", " pnpmNames}"
      touch $out
    '';
  };
}

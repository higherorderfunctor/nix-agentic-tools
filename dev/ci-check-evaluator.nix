# The matrix discovery evaluator: the locked nixpkgs nix-eval-jobs with the
# worker garbage collector re-enabled.
#
# Upstream disables Boehm GC in main() ("GC_DONT_GC=1", added in 2022 to dodge
# a "Collecting from unknown thread" crash in forked workers) and reclaims
# memory only by restarting workers. Constructing this flake's check set
# allocates ~12 GB of which ~5.5 GB stays live, so a GC-less worker sits at
# ~12 GB before it emits its first row, crosses 14 GiB within ~35 rows, and
# every restart repeats the whole initialization. With the collector on, one
# worker evaluates the full set in ~9 GB. Workers are fork+exec'd since 2.35,
# so the original fork hazard no longer applies. The greps fail the build
# loudly if upstream moves or renames the line, so a bump can never silently
# re-disable the collector.
{pkgs}:
pkgs.nix-eval-jobs.overrideAttrs (old: {
  postPatch =
    (old.postPatch or "")
    + ''
      (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      grep -q 'setenv("GC_DONT_GC", "1", 1)' src/nix-eval-jobs.cc
      sed -i 's|setenv("GC_DONT_GC", "1", 1);|/* worker GC enabled: see dev/ci-check-evaluator.nix */|' src/nix-eval-jobs.cc
      if grep -q GC_DONT_GC src/nix-eval-jobs.cc; then
        echo "GC_DONT_GC still present" >&2
        false
      fi
      )
    '';
})

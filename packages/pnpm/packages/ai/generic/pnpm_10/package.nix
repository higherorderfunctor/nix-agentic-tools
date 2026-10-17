# pnpm 10 — `pkgs.ai.generic.pnpm_10`, re-pinned onto this repo's update
# cadence. All of the machinery lives in ../../../../lib/mkMajor.nix; this file
# exists to give the major its own path (the owner registry.nix names
# it via `--override-filename`) and its own sidecar
# (../../../../sources-10.json).
#
# EXPECTED AT LANDING: a content NO-OP. Our pin (10.34.5) and the pinned
# nixpkgs' `pnpm_10` (10.34.5) agree, and both fetch the same registry
# tarball with the same fetcher, so `pkgs.ai.generic.pnpm_10` resolves to
# the SAME store path as plain `pkgs.pnpm_10` — a fixed-output
# derivation's path follows its hash, and `passthru` is not a derivation
# input. That is not a bug and NOT a reason to delete this package.
#
# Its value is CADENCE, not content: this repo sweeps npm's `latest-10`
# dist-tag 4x/day, where nixpkgs' `pnpm_10` moves on a channel bump. The
# paths diverge the moment upstream cuts a 10.x release, and converge
# again whenever nixpkgs catches up. Do not "clean up" pnpm_10 on parity
# grounds — see dev/fragments/overlays/overlay-pattern.md, which records
# the same rule for btop.
{
  packageLib,
  pkgs,
  repoPath,
  ...
}:
import ../../../../lib/mkMajor.nix {
  inherit packageLib pkgs repoPath;
  major = "10";
}

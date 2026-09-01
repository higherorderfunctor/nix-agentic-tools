# pnpm 11 — `pkgs.ai.generic.pnpm_11`, re-pinned onto this repo's update
# cadence. All of the machinery lives in ./pnpm-major.nix; this file
# exists to give the major its own path (config/update-targets.nix names
# it via `--override-filename`) and its own sidecar
# (./pnpm_11-sources.json).
#
# A REAL DELTA at landing, unlike its pnpm_10 sibling: the pinned nixpkgs
# ships `pnpm_11` = 11.15.0 while npm's `latest-11` dist-tag is 11.17.0,
# so `pkgs.ai.generic.pnpm_11` and plain `pkgs.pnpm_11` are different store
# paths from day one. That gap is the ordinary steady state for a package
# on this pattern — a repo sweeping 4x/day sits ahead of a nixpkgs
# channel — and it is why pnpm_10 and pnpm_11 are carried the same way
# even though one of them happens to be at parity right now.
#
# pnpm_12 is NOT carried this way, and the difference is upstream's, not
# a style choice: pnpm 12 moved its implementation out of the npm package
# into per-platform native binaries, so there is no `pkgs.pnpm_12` to
# override at all. See ./pnpm_12.nix.
#
# Bare `pnpm` in the pinned nixpkgs aliases `pnpm_11` (identical
# drvPath). We deliberately do NOT shadow it: this overlay is additive
# and writes only into the `generic` namespace.
args:
import ./pnpm-major.nix (args // {major = "11";})

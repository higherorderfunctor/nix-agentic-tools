# pnpm 11 — `pkgs.ai.generic.pnpm_11`, re-pinned onto this repo's update
# cadence. All of the machinery lives in ../../../../lib/mkMajor.nix; this file
# exists to give the major its own path (the owner registry.nix names
# it via `--override-filename`) and its own sidecar
# (../../../../sources-11.json).
#
# A REAL DELTA at landing, unlike its pnpm_10 sibling: the pinned nixpkgs
# ships `pnpm_11` = 11.15.0 while npm's `latest-11` dist-tag is 11.17.0,
# so `pkgs.ai.generic.pnpm_11` and plain `pkgs.pnpm_11` are different store
# paths from day one. That gap is the ordinary steady state for a package
# on this pattern — a repo sweeping 4x/day sits ahead of a nixpkgs
# channel — and it is why pnpm_10 and pnpm_11 are carried the same way
# even though one of them happens to be at parity right now.
#
# pnpm_12 instead overrides nixpkgs' source-built Rust package, with our
# source/cargo hashes and locked toolchain. This JavaScript-bundle builder
# remains appropriate for 10 and 11. See ../pnpm_12/package.nix.
#
# Bare `pnpm` in the pinned nixpkgs aliased `pnpm_11` when this landed and
# aliases nixpkgs' `pnpm_12` as of 2026-10-03. We deliberately do NOT shadow
# it: this overlay is additive and writes only into the `generic` namespace.
{
  packageLib,
  pkgs,
  repoPath,
  ...
}:
import ../../../../lib/mkMajor.nix {
  inherit packageLib pkgs repoPath;
  major = "11";
}

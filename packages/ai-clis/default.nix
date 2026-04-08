# Legacy AI CLI package overlay — SHRINKING.
#
# This file used to aggregate all five AI CLI packages
# (claude-code, copilot-cli, kiro-cli, kiro-gateway, any-buddy).
# As of Milestone 2 of the factory rollout, claude-code has been
# ported to the new `overlays/` flat tree + `packages/claude-code/`
# Bazel directory. The remaining four entries (any-buddy,
# github-copilot-cli, kiro-cli, kiro-gateway) stay here until
# Milestone 4 ports them; this whole file is deleted at the end
# of Milestone 4.
#
# Packages still exposed at top-level by this overlay:
# `pkgs.any-buddy`, `pkgs.github-copilot-cli`, `pkgs.kiro-cli`,
# `pkgs.kiro-gateway`. After Milestone 4 they move to `pkgs.ai.*`.
#
# 3-argument overlay shape (`{inputs, ...}: final: prev: ...`) per
# `dev/fragments/overlays/overlay-pattern.md`. The inputs blob is
# threaded into per-package files so each can instantiate its own
# `ourPkgs = import inputs.nixpkgs { ... }` for cache-hit parity
# (every build input routes through THIS repo's nixpkgs pin
# instead of the consumer's, so the published store paths stay
# byte-identical regardless of which nixpkgs the consumer brings).
#
# Per-package files take a custom destructuring arg set
# (`{ inputs, final, prev?, nv, ... }`) — they're not uniform
# `{nv-sources, ...}` callers because each AI CLI has its own
# extras (kiro-cli needs both `nv` and `nv-darwin`, etc.). This
# file reads raw nvfetcher data from `final.nv-sources` (set by
# the `nvSourcesOverlay` in `flake.nix` per the nix-standards
# rule), merges in this group's `hashes.json` sidecar values,
# and threads the right `nv` entry into each per-package file.
{inputs, ...}: final: prev: let
  hashes = builtins.fromJSON (builtins.readFile ./hashes.json);
  merge = name: (final.nv-sources.${name} or {}) // (hashes.${name} or {});

  nv = {
    any-buddy = merge "any-buddy";
    copilot-cli = merge "github-copilot-cli";
    kiro-cli = merge "kiro-cli";
    kiro-cli-darwin = merge "kiro-cli-darwin";
    kiro-gateway = merge "kiro-gateway";
  };
in {
  any-buddy = import ./any-buddy.nix {
    inherit inputs final;
    nv = nv.any-buddy;
  };
  github-copilot-cli = import ./copilot-cli.nix {
    inherit inputs final prev;
    nv = nv.copilot-cli;
  };
  kiro-cli = import ./kiro-cli.nix {
    inherit inputs final prev;
    nv = nv.kiro-cli;
    nv-darwin = nv.kiro-cli-darwin;
  };
  kiro-gateway = import ./kiro-gateway.nix {
    inherit inputs final;
    nv = nv.kiro-gateway;
  };
}

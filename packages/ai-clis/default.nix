# AI CLI package overlay: claude-code, copilot-cli, kiro-cli,
# kiro-gateway, any-buddy.
#
# Packages exposed at top-level (`pkgs.claude-code`,
# `pkgs.github-copilot-cli`, `pkgs.kiro-cli`, etc.).
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
# extras (claude-code needs `lockFile`, kiro-cli needs both
# `nv` and `nv-darwin`, etc.). The `default.nix` reads raw
# nvfetcher data from `final.nv-sources` (set by the
# `nvSourcesOverlay` in `flake.nix` per the nix-standards rule),
# merges in this group's `hashes.json` sidecar values for
# `npmDepsHash`/`srcHash`/per-platform sha256 etc., and threads
# the right `nv` entry into each per-package file.
#
# Note: buddy customization for claude-code lives in the HM module
# (`modules/claude-code-buddy/`), not as package passthru. The
# any-buddy worker source tree is exposed as `any-buddy` for the
# activation script to use.
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

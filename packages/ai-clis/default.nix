# AI CLI package overlay: claude-code, copilot-cli, kiro-cli, kiro-gateway.
# Packages are top-level (pkgs.claude-code, pkgs.github-copilot-cli, etc.).
#
# Note: buddy customization for claude-code lives in the HM module
# (modules/claude-code-buddy/), not as package passthru. The any-buddy
# worker source tree is exposed as `any-buddy` (matching upstream
# package name) for the activation script to use.
#
# `inputs` is threaded into each per-package import so Phase 3.7
# of the architecture-foundation plan can switch compiled packages
# to `ourPkgs = import inputs.nixpkgs { ... }` for cache-hit parity
# (see dev/notes/overlay-cache-hit-parity-fix.md and the
# `overlays/cache-hit-parity.md` fragment). Per-package files that
# don't yet consume `inputs` accept it as an optional field in
# their arg set; behavior is unchanged in this commit.
{inputs, ...}: final: prev: let
  sources = import ./sources.nix {inherit final;};
in {
  any-buddy = import ./any-buddy.nix {
    inherit inputs final;
    nv = sources.any-buddy;
  };
  claude-code = import ./claude-code.nix {
    inherit inputs final prev;
    nv = sources.claude-code;
    lockFile = ./locks/claude-code-package-lock.json;
  };
  github-copilot-cli = import ./copilot-cli.nix {
    inherit inputs final prev;
    nv = sources.copilot-cli;
  };
  kiro-cli = import ./kiro-cli.nix {
    inherit inputs final prev;
    nv = sources.kiro-cli;
    nv-darwin = sources.kiro-cli-darwin;
  };
  kiro-gateway = import ./kiro-gateway.nix {
    inherit inputs final;
    nv = sources.kiro-gateway;
  };
}

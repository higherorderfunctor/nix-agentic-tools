# AI CLI package overlay: claude-code, copilot-cli, kiro-cli, kiro-gateway.
# Packages are top-level (pkgs.claude-code, pkgs.github-copilot-cli, etc.).
#
# Note: buddy customization for claude-code lives in the HM module
# (modules/claude-code-buddy/), not as package passthru. The any-buddy
# worker source tree is exposed as `any-buddy` (matching upstream
# package name) for the activation script to use.
_: final: prev: let
  sources = import ./sources.nix {inherit final;};
in {
  any-buddy = import ./any-buddy.nix {
    inherit final;
    nv = sources.any-buddy;
  };
  claude-code = import ./claude-code.nix {
    inherit final prev;
    nv = sources.claude-code;
    lockFile = ./locks/claude-code-package-lock.json;
  };
  github-copilot-cli = import ./copilot-cli.nix {
    inherit final prev;
    nv = sources.copilot-cli;
  };
  kiro-cli = import ./kiro-cli.nix {
    inherit final prev;
    nv = sources.kiro-cli;
    nv-darwin = sources.kiro-cli-darwin;
  };
  kiro-gateway = import ./kiro-gateway.nix {
    inherit final;
    nv = sources.kiro-gateway;
  };
}

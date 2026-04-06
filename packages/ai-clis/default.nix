# AI CLI package overlay: copilot-cli, kiro-cli, kiro-gateway.
# Packages are top-level (pkgs.github-copilot-cli, pkgs.kiro-cli, pkgs.kiro-gateway).
_: final: prev: let
  sources = import ./sources.nix {inherit final;};

  any-buddy-source = import ./any-buddy.nix {
    inherit final;
    nv = sources.any-buddy;
  };

  mkBuddySalt = import ./buddy-salt.nix {
    inherit (final) bun jq runCommand;
    inherit any-buddy-source;
  };

  withBuddyFn = import ./with-buddy.nix {
    inherit (final) lib python3 runCommand stdenv;
    inherit mkBuddySalt;
    sigtool = final.sigtool or null;
  };
in {
  inherit any-buddy-source;
  claude-code = import ./claude-code.nix {
    inherit final prev withBuddyFn;
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

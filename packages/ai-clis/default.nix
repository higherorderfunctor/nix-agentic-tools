# AI CLI package overlay: copilot-cli, kiro-cli, kiro-gateway.
# Packages are top-level (pkgs.github-copilot-cli, pkgs.kiro-cli, pkgs.kiro-gateway).
_: final: prev: let
  sources = import ./sources.nix {inherit final;};
in {
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
  };
  kiro-gateway = import ./kiro-gateway.nix {
    inherit final;
    nv = sources.kiro-gateway;
  };
}

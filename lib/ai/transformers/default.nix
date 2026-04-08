{lib}: {
  agentsmd = import ./agentsmd.nix {inherit lib;};
  claude = import ./claude.nix {inherit lib;};
  copilot = import ./copilot.nix {inherit lib;};
  kiro = import ./kiro.nix {inherit lib;};
}

{pkgs, ...}: {
  # ── Binary Cache ──────────────────────────────────────────────────────
  cachix.pull = ["nix-agentic-tools"];

  # ── Generation tasks ──────────────────────────────────────────────────
  imports = [./dev/tasks/generate.nix];

  # ── Packages ──────────────────────────────────────────────────────────
  packages = with pkgs; [
    cspell
    deadnix
    statix
  ];

  # ── treefmt ────────────────────────────────────────────────────────────
  treefmt = {
    enable = true;
    config = import ./treefmt.nix;
  };

  # ── Git Hooks ─────────────────────────────────────────────────────────
  # treefmt hook is auto-wired by treefmt.enable above
  git-hooks.hooks = {
    # Nix linting
    deadnix.enable = true;
    statix.enable = true;

    # Spelling
    cspell = {
      enable = true;
      excludes = [".*-package-lock\\.json$" ".*\\.lock$"];
    };

    # Commit message convention
    convco.enable = true;

    # Shell linting
    shellcheck.enable = true;
    shfmt.enable = true;

    # Syntax validation
    check-json.enable = true;
    check-toml.enable = true;
  };
}

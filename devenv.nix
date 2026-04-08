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
  # `treefmt.enable = true` above wires the treefmt wrapper as
  # `git-hooks.hooks.treefmt.package` (via mkOverrideDefault) and
  # registers a `devenv:treefmt:run` task that runs *before*
  # `devenv:enterShell` — that's why files get reformatted on every
  # `direnv reload` / `devenv shell` entry and show up as
  # working-tree diffs. But devenv does NOT flip
  # `git-hooks.hooks.treefmt.enable`, so the pre-commit hook stays
  # inert and files can still be committed unformatted. The explicit
  # enable below activates the hook so formatting is enforced at
  # commit time, not just at shell-entry time.
  git-hooks.hooks = {
    treefmt.enable = true;

    # Nix linting
    deadnix = {
      enable = true;
      # nvfetcher generates `.nvfetcher/generated.nix` with a fixed
      # arg list (`fetchgit`/`fetchurl`/`fetchFromGitHub`/`dockerTools`)
      # regardless of which of those a given source actually uses.
      # The unused-args are part of nvfetcher's output contract.
      excludes = [".*\\.nvfetcher/generated\\.nix$"];
    };
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

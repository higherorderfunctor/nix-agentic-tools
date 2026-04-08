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
      # `docs/plan.md` and everything under `docs/superpowers/`
      # are sentinel-tip-only scratch — PR extraction filters
      # them out so they never merge to main. No value gating
      # every commit on their spelling. Excluding lets backlog
      # entries, specs, and plans reference novel tool names,
      # commit SHAs, nix store hashes, tool jargon, etc. without
      # polluting `.cspell/project-terms.txt`. `docs/superpowers/`
      # is recreated by the superpowers plugin's brainstorming /
      # writing-plans skills whenever a new design session starts.
      excludes = [
        ".*-package-lock\\.json$"
        ".*\\.lock$"
        "^docs/plan\\.md$"
        "^docs/superpowers/"
      ];
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

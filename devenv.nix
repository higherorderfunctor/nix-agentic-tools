{
  config,
  pkgs,
  ...
}: {
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
  # `treefmt.enable = true` above turns on treefmt itself but does NOT
  # install a pre-commit hook — that's a separate git-hooks.hooks entry
  # below. Without it, files can get committed unformatted and the next
  # `devenv shell` / `devenv test` / manual treefmt invocation picks
  # them up as a working-tree diff, which shows up as unexplained
  # "style" churn. Wiring the hook here forces formatting at commit
  # time.
  git-hooks.hooks = {
    treefmt = {
      enable = true;
      package = config.treefmt.build.wrapper;
    };
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

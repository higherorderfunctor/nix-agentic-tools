# Shared treefmt config — consumed by devenv.nix treefmt module.
# Each formatter handles specific file types (see inline comments).
{
  # Use flake.nix as the tree-root marker so `nix fmt` works in git
  # worktrees (where .git is a gitfile pointer, not a directory).
  # treefmt-nix's default is `.git/config`, which fails inside any
  # `git worktree add`-created tree. The update pipeline runs
  # `nix fmt` from per-input worktrees (see update-input.sh Phase 2.5),
  # so this default must be overridden.
  projectRootFile = "flake.nix";

  programs = {
    # Nix: *.nix
    alejandra.enable = true;
    # JSON: *.json (via settings.formatter.biome.includes)
    biome = {
      enable = true;
      settings.formatter.indentStyle = "space";
      settings.formatter.indentWidth = 2;
    };
    # Markdown: *.md (via settings.formatter.prettier.includes)
    prettier = {
      enable = true;
      settings.proseWrap = "preserve";
    };
    # Shell: *.sh, *.bash
    shfmt.enable = true;
    # TOML: *.toml
    taplo.enable = true;
  };

  settings.formatter = {
    prettier.includes = ["*.md"];
    biome.includes = ["*.json"];
  };

  settings.global.excludes = [
    "*.lock"
    ".devenv/**"
    ".direnv/**"
    ".pre-commit-config.yaml"
    "overlays/sources/**"
    "node_modules/**"
    "result/**"
    "result-*/**"
    # Sentinel-tip scratch files. Prettier's markdown handler
    # mangles Nix globs like `modules/devenv/*.nix` into
    # `modules/devenv/_.nix` (it reads `*...*` as italic and
    # garbles the replacement), and re-indents deliberately
    # hand-formatted lists. These files are cspell-excluded
    # and never merge to main — leave them as-authored.
    "docs/plan.md"
  ];
}

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
    # PRIMARY formatter (user pref: biome over prettier). biome owns JS/TS/JSX/
    # JSON/CSS via its default treefmt globs; prettier is excluded from those in
    # settings.formatter below so the two never format the same file.
    biome = {
      enable = true;
      settings.formatter.indentStyle = "space";
      settings.formatter.indentWidth = 2;
    };
    # Only the types biome can't format (markdown/yaml/scss/html/vue/json5) —
    # scoped via settings.formatter.prettier.excludes.
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
    # Prefer biome: it owns JS/TS/JSX/JSON/CSS via its default globs. Exclude
    # those from prettier so the two never format the same file — they disagree
    # on constructs like a `new (x) => {…}` ctor type, which makes
    # `treefmt --fail-on-change` loop with an empty git diff. Note: treefmt-nix
    # `includes` APPEND to a formatter's defaults (they do not replace), so the
    # scoping has to be done with `excludes`. prettier keeps only what biome
    # can't format (markdown/yaml/scss/html/vue/json5).
    prettier.excludes = [
      "*.cjs"
      "*.css"
      "*.js"
      "*.json"
      "*.jsx"
      "*.mjs"
      "*.ts"
      "*.tsx"
    ];
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

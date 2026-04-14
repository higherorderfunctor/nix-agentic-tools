# Shared treefmt config — consumed by devenv.nix treefmt module.
{
  programs = {
    alejandra.enable = true;
    biome = {
      enable = true;
      settings.formatter.indentStyle = "space";
      settings.formatter.indentWidth = 2;
    };
    prettier = {
      enable = true;
      settings.proseWrap = "preserve";
    };
    shfmt.enable = true;
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

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
    ".nvfetcher/**"
    "locks/**"
    "node_modules/**"
    "result/**"
    "result-*/**"
  ];
}

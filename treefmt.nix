{pkgs, ...}: {
  projectRootFile = "flake.nix";

  programs = {
    # Nix
    alejandra.enable = true;

    # JSON
    biome = {
      enable = true;
      settings.formatter.indentStyle = "space";
      settings.formatter.indentWidth = 2;
    };

    # Markdown
    prettier = {
      enable = true;
      settings.proseWrap = "preserve";
    };

    # TOML
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

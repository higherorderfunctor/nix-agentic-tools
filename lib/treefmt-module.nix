# The treefmt-nix module this flake exports as `treefmtModules.default`: the
# formatter programs and style every generated file is formatted with, and
# which a consumer can import into its own treefmt config. Repository-only
# settings (root marker, path exclusions) live in the root treefmt.nix.
{
  config,
  lib,
  ...
}: {
  programs = {
    # Nix: *.nix
    alejandra.enable = true;
    # PRIMARY formatter (user pref: biome over prettier). biome owns JS/TS/JSX/
    # JSON/CSS via its default treefmt globs; prettier is excluded from those in
    # settings.formatter below so the two never format the same file.
    biome = {
      enable = true;
      settings.formatter = lib.mapAttrsRecursive (_path: lib.mkDefault) (import ./generated-style.nix).biome;
    };
    # Only the types biome can't format (markdown/yaml/scss/html/vue/json5) —
    # scoped via settings.formatter.prettier.excludes.
    prettier = {
      enable = true;
      # The prose style (`proseWrap = "always"`) and why: one definition,
      # used by the default `ai.formatter` for generated Markdown and YAML.
      settings = lib.mapAttrsRecursive (_path: lib.mkDefault) (import ./generated-style.nix).prettier;
    };
    # Shell: *.sh, *.bash
    shfmt.enable = true;
    # TOML: *.toml
    taplo.enable = true;
  };

  settings.formatter = lib.mkIf config.programs.prettier.enable {
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
}

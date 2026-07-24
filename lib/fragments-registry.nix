# lib/fragments-registry.nix — the option declaration for the fragment-category
# registry.
#
# This module declares `options.fragments.categories`. It is the single source
# of truth for the per-category fragment metadata: the two parallel
# hand-maintained registries that used to live in dev/generate.nix
# (`packagePaths`, the scope globs, and `devFragmentNames`, the fragment
# sources) were dissolved into `config.fragments.categories`, so there is no
# longer a pair of category-keyed attrsets to keep in sync. They were always
# two halves of one per-category record — both were touched whenever a fragment
# moved — so they dissolve together. Every category declares its own row via
# config.fragments.categories.<name>.
#
# `lib.evalModules` merges those contributions and does the collision-checking;
# the result is read directly by dev/generate.nix. Unlike the update and
# cache-hit-parity registries there is no matching flake output, because
# dev/generate.nix is imported as a bare `{lib, pkgs}` function by callers that
# never pass `self` — see the `fragmentCategories` comment there.
#
# NOT to be confused with the pre-existing, unrelated `lib/fragments.nix`: that
# is the fragment COMPOSITION helper library (mkFragment / compose), exported
# through the flake `lib` output for consumers. This file is an internal option
# module describing which fragments exist and what they are scoped to, and is
# NOT exported.
#
# Mirrors the authoring style of lib/update.nix and lib/checks.nix.
{lib, ...}: let
  inherit (lib) mkOption types;
in {
  options.fragments.categories = mkOption {
    default = {};
    description = ''
      Merged fragment-category registry — the single source of truth for which
      fragment sources compose into each category and which paths the resulting
      generated instruction file is scoped to. Each attribute names one
      category; a category declares its own row via
      config.fragments.categories.<name>. The module system merges the
      contributions and the result is read by dev/generate.nix, which uses
      `scopes` for the per-ecosystem frontmatter and `sources` for the
      composition itself.
    '';
    type = types.attrsOf (types.submodule {
      options = {
        scopes = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = ''
            Path globs this category's generated instruction file is scoped to.
            Lists are the canonical form; the transformers in
            lib/ai/transformers/ handle per-ecosystem emission — Claude as a
            YAML list, Copilot as a comma-joined string (native applyTo
            syntax), Kiro as an inline YAML array (native fileMatchPattern
            multi-pattern syntax). Order is load-bearing: the globs are emitted
            verbatim into the generated frontmatter. `null` means
            "always-loaded" (no scoping), which is what the `monorepo`
            orientation category uses.
          '';
        };
        sources = mkOption {
          type = types.listOf (types.either types.str (types.submodule {
            options = {
              location = mkOption {
                type = types.enum ["dev" "devshell" "package"];
                default = "dev";
                description = ''
                  Which tree the fragment markdown lives in:
                  "dev" reads dev/fragments/<dir>/<name>.md,
                  "package" reads packages/<dir>/docs/<name>.md, and
                  "devshell" reads devshell/<dir>/docs/<name>.md.
                '';
              };
              name = mkOption {
                type = types.str;
                description = ''
                  Basename of the fragment markdown file, without the `.md`
                  extension.
                '';
              };
              dir = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Directory the fragment lives under within its location tree.
                  `null` (the default) falls back to the category key, and is
                  set explicitly only when the category name differs from the
                  directory name.
                '';
              };
            };
          }));
          default = [];
          description = ''
            Fragment markdown sources composed into this category, in order.
            Each entry is either a bare string `"name"` (the legacy shorthand,
            equivalent to `{location = "dev"; name = "<name>";}`) or an attrset
            selecting a co-located fragment. Consumed by dev/generate.nix's
            `mkDevFragment`.
          '';
        };
      };
    });
  };
}

# Semble content categories: the option type, validation, and ordering shared
# by `defaultContent`, each `models` entry and `mkSemble`'s `content`.
{lib}: let
  categories = ["all"] ++ (import ./contentCategories.nix).categories;
  normalize = lib.sort (a: b: a < b);
in {
  inherit categories normalize;

  type = lib.types.coercedTo (lib.types.enum categories) lib.singleton (lib.types.listOf (lib.types.enum categories));
  default = ["code"];

  # `optionPath` names the option in the message, e.g. "defaultContent".
  errors = optionPath: content:
    lib.optional (content == [])
    "Semble `${optionPath}` must contain at least one category."
    ++ lib.optional (lib.length content != lib.length (lib.unique content))
    "Semble `${optionPath}` must not contain duplicate categories."
    ++ lib.optional (lib.elem "all" content && lib.length content > 1)
    ''Semble `${optionPath}` must not combine "all" with another category.'';
}

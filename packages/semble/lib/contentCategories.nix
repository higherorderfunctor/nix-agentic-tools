# Semble's content categories and what "all" means, defined once. Lib-free so
# integrations.nix, which is imported without lib, can share it with
# contentScope.nix and customization.nix.
let
  categories = ["code" "config" "docs"];
in {
  inherit categories;

  # The exact set a selection searches: "all" is every category, and any other
  # selection is de-duplicated and sorted (attrNames does both).
  expand = content:
    if builtins.elem "all" content
    then categories
    else
      builtins.attrNames (builtins.listToAttrs (map (name: {
          inherit name;
          value = null;
        })
        content));
}

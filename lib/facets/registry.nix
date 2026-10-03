# Shared by flake assembly and workspace document generation. Metadata does
# not need a package set or flake self, so generation can use the same owners.
{
  lib,
  root,
  modules ? [(root + "/config/fragment-categories.nix") (root + "/config/update-targets.nix")],
}: let
  facets = import ../facets.nix {inherit lib;};
  documentationOptions = (import ../documentation.nix {inherit lib;}).options.documentation;
  index = facets.index {facetsDir = root + "/packages";};
  repoPath = path:
    assert lib.hasPrefix "${toString root}/" (toString path);
      builtins.unsafeDiscardStringContext (lib.removePrefix "${toString root}/" (toString path));
  registry = facets.realizeRegistry {
    inherit index;
    claimPaths =
      [
        ["fragments" "categories"]
        ["update" "targets"]
      ]
      ++ map (name: ["documentation" name]) (builtins.attrNames documentationOptions);
    modules =
      [
        ../documentation.nix
        ../fragments-registry.nix
        ../update.nix
      ]
      ++ modules;
    specialArgs = {inherit repoPath;};
  };
in {
  inherit index repoPath;
  inherit (registry) config;
}

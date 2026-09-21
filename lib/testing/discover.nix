{lib}: root: let
  entries = builtins.readDir root;
  directories = lib.filterAttrs (_: type: type == "directory") entries;
  hasModule = name: let
    children = builtins.readDir (root + "/${name}");
  in
    children."default.nix" or null == "regular";
  missingModules = builtins.filter (name: !hasModule name) (builtins.attrNames directories);
in
  # Every immediate directory is a check concern. Silently skipping one makes
  # a missing entry point indistinguishable from a passing check; fixture trees
  # belong below a concern and remain outside this one-level discovery boundary.
  if missingModules != []
  then throw "check discovery error: directory '${toString root}/${builtins.head missingModules}' must contain a regular default.nix check module"
  else map (name: root + "/${name}/default.nix") (builtins.attrNames directories)

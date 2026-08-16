{lib}: world: let
  failedNames = lib.filter (
    name: world.localChecks.${name}.value != true
  ) (builtins.attrNames world.localChecks);
in
  if failedNames == []
  then world
  else throw "facet local check failed: ${lib.concatStringsSep ", " failedNames}"

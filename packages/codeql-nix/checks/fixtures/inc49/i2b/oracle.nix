{
  mapping,
  name,
  roots,
}: let
  searchPath =
    map (entry: {
      inherit (entry) prefix;
      path = roots.${entry.rootLogicalName} + "/" + entry.relativePath;
    })
    mapping;
  __nixPath = searchPath;
in
  builtins.seq __nixPath [
    (import (builtins.findFile searchPath name))
    (
      if name == "pkg"
      then import <pkg>
      else import <pkg/sub>
    )
  ]

# Independent upstream invocation: no adapter, extractor, serializer or QL imports.
{
  collect ? false,
  nixpkgs,
  roots ? ["root.nix"],
  source,
}: let
  lib = import (nixpkgs + "/lib");
  modules = map (name: source + "/" + name) roots ++ [{_module.args = {};}];
  specialArgs = {modulesPath = source;};
  graph =
    if collect
    then
      (lib.modules.collectModules source modules ({
          inherit lib;
          config = {};
          options = {};
        }
        // specialArgs)).graph
    else (lib.evalModules {inherit modules specialArgs;}).graph;
  walk = path: entry:
    [
      {
        inherit (entry) disabled file key;
        occurrencePathJson = builtins.toJSON path;
      }
    ]
    ++ lib.concatLists (lib.imap0 (i: child: walk (path ++ [i]) child) entry.imports);
in
  lib.concatLists (lib.imap0 (i: root: walk [i] root) graph)

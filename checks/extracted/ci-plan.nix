{
  derivations ? true,
  flake,
  root,
}: let
  lib = flake.inputs.nixpkgs.lib;
  facts = import ../../lib/extracted/facts.nix {inherit lib;};
  owners = import ./owners.nix;
  sourceRoot = ../..;
  system = "aarch64-darwin";
  directory = dir:
    /. + (toString root + lib.removePrefix (toString sourceRoot) (toString dir));
  selected = lib.filterAttrs (_: dir: facts.hostRunOn system (directory dir)) owners;
in
  lib.mapAttrs (name: _: {
    drvPath =
      if derivations
      then flake.ciPackages.${system}.${name}.passthru.extracted.drvPath
      else null;
  })
  selected

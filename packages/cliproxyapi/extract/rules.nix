# Reconcile hand enums and credential reasons against the measured v8 paths.
{
  lib,
  rows ? builtins.fromJSON (builtins.readFile ./annotations.json),
}: let
  inherit (import ../../../lib/extracted/facts.nix {inherit lib;}) get load;
  inherit (import ../../../lib/extracted/reconcile.nix {inherit lib;}) reconcile;
  inherit (load {dir = ../extracted;}) aggregate;
  isPattern = name: _: lib.hasInfix "*" name;
in
  reconcile {
    config = {
      facts = get aggregate "config";
      fields = ["enum" "secret"];
      patterns = lib.filterAttrs isPattern rows.config;
      rows = lib.filterAttrs (name: row: !isPattern name row) rows.config;
      secretNeeds = ["secret"];
    };
  }

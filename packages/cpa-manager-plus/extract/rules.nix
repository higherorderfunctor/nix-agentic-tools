# Reconcile hand credential reasons against the measured config.json and
# environment. config.json names key files, never keys, so it has no rows; a
# credential-shaped key added upstream still fails until it gets one.
{lib}: let
  rows = builtins.fromJSON (builtins.readFile ./annotations.json);
  inherit (import ../../../lib/extracted/facts.nix {inherit lib;}) get load;
  inherit (import ../../../lib/extracted/reconcile.nix {inherit lib;}) reconcile;
  inherit (load {dir = ../extracted;}) aggregate;
  surface = name: rows: {
    facts = get aggregate name;
    fields = ["secret"];
    inherit rows;
    secretNeeds = ["secret"];
  };
in
  reconcile {
    config = surface "config" {};
    environment = surface "environment" rows.environment;
  }

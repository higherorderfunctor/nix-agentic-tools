# Reconcile hand credential reasons against the measured config.json and
# environment. config.json names key files, never keys: its rows mark them
# `secretFile`, as the variables that override them are. A credential-shaped
# key added upstream still fails until it gets a row.
{lib}: let
  rows = builtins.fromJSON (builtins.readFile ./annotations.json);
  inherit (import ../../../lib/extracted/facts.nix {inherit lib;}) get load;
  inherit (import ../../../lib/extracted/reconcile.nix {inherit lib;}) reconcile;
  inherit (load {dir = ../extracted;}) aggregate;
  surface = name: rows: {
    facts = get aggregate name;
    fields = ["secret" "secretFile"];
    inherit rows;
    secretNeeds = ["secret"];
  };
in
  reconcile {
    config = surface "config" rows.config;
    environment = surface "environment" rows.environment;
  }

# The hand layer over packages/cliproxyapi/extracted/, one reconcile surface
# per extracted tree. A row for a path the extraction no longer has fails the
# `cliproxyapi-extracted` check, and so does a credential-shaped path without
# its row.
#
#   config    `enum`: the values a string accepts. `secret`: why the value
#             takes a secret (`plain`, `file` or `helper`) rather than a
#             string; every credential-shaped path needs one. A row whose
#             path holds `*` is a pattern for every path it matches, `*`
#             standing for one key such as a key family
#             (`api-keys.*[].proxy-url`).
#   accounts  `type`: the Go type of a field whose reads assert none or
#             several. `secret`: why the field's strings take a secret. A
#             credential-shaped field must be `ignored`, because Nix never
#             writes a login's tokens. The surface also returns `ignored`,
#             each such field's reason, for the account type to refuse.
{
  lib,
  rows ? builtins.fromJSON (builtins.readFile ./annotations.json),
}: let
  inherit (import ../../../lib/extracted/facts.nix {inherit lib;}) get load;
  inherit (import ../../../lib/extracted/reconcile.nix {inherit lib;}) reconcile;
  inherit (load {dir = ../extracted;}) aggregate;
  isPattern = name: _: lib.hasInfix "*" name;
  results = reconcile {
    accounts = {
      facts = get aggregate "accounts";
      fields = ["secret"];
      needs = ["type"];
      rows = rows.accounts;
      # Never set on an entry: `ignored` rows skip the secret test, so any
      # other row for a credential-shaped field fails it.
      secretNeeds = ["ignored"];
    };
    config = {
      facts = get aggregate "config";
      fields = ["enum" "secret"];
      patterns = lib.filterAttrs isPattern rows.config;
      rows = lib.filterAttrs (name: row: !isPattern name row) rows.config;
      secretNeeds = ["secret"];
    };
  };
in
  results
  // {
    accounts =
      results.accounts
      // {
        ignored = lib.mapAttrs (_: row: row.ignored) (lib.filterAttrs (_: row: row ? ignored) rows.accounts);
      };
  }

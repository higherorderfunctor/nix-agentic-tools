# A string field declares no choices, so nothing about the field constrains
# this value. It is still not a native string.
let
  dsl = import ../../../dsl.nix;
  inherit (dsl) el field model normalize check record fieldIs;
  inherit (field) required str;

  uid = required (str "UID");
  title = str "TITLE";

  note = el "NOTE" {} {
    fields = [uid title];
    constraints = [(check "titled" (record (_node: fieldIs title 42)))];
  };
in
  normalize (model "guard" {elements = [note];})

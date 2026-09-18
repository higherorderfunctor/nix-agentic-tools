# A Boolean-codec field is named by its native spelling "false" or "true". A
# raw Nix Boolean is not that spelling.
let
  dsl = import ../../../dsl.nix;
  inherit (dsl) el field model normalize check record fieldIs;
  inherit (field) required str boolean;

  uid = required (str "UID");
  flag = required (boolean "FLAG");

  note = el "NOTE" {} {
    fields = [uid flag];
    constraints = [(check "flagged" (record (_node: fieldIs flag true)))];
  };
in
  normalize (model "guard" {elements = [note];})

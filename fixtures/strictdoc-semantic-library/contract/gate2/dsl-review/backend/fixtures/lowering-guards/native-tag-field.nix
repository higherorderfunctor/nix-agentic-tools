# A tag field has no semantic type in this profile, and nothing maps one.
let
  dsl = import ../../../dsl.nix;
  inherit (dsl) el field model normalize;
  inherit (field) required str;

  uid = required (str "UID");

  note = el "NOTE" {} {fields = [uid (field.tag "LABELS")];};
in
  normalize (model "guard" {elements = [note];})
